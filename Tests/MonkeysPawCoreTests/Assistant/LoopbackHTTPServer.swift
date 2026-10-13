import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A real HTTP/1.1 peer, rather than URLProtocol (which differs on Linux).
/// One worker owns accepted sockets; the lock coordinates shutdown and reads
/// of recorded requests. All blocking socket operations have a finite timeout.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let target: String
        let headers: [String: String]
        let body: Data
    }

    struct Connection {
        fileprivate let descriptor: Int32

        @discardableResult
        func write(_ text: String) -> Bool { write(Data(text.utf8)) }

        @discardableResult
        func write(_ data: Data) -> Bool {
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return true }
                var offset = 0
                while offset < buffer.count {
                    #if canImport(Darwin)
                    let count = Darwin.send(descriptor, base.advanced(by: offset), buffer.count - offset, 0)
                    #else
                    let count = Glibc.send(descriptor, base.advanced(by: offset), buffer.count - offset, Int32(MSG_NOSIGNAL))
                    #endif
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
        }

        @discardableResult
        func respond(status: Int = 200, headers: String = "", body: Data = Data()) -> Bool {
            write("HTTP/1.1 \(status) Test\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(headers)\r\n") && write(body)
        }

        /// EOF/reset proves the client cancelled while the response was still
        /// incomplete. A timeout is a failure, not evidence of cancellation.
        func waitForPeerClose() -> Bool {
            var byte: UInt8 = 0
            while true {
                let count = recv(descriptor, &byte, 1, 0)
                if count == 0 { return true }
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno == ECONNRESET
                }
            }
        }

        fileprivate func readRequest() -> Request? {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let separator = Data("\r\n\r\n".utf8)
            while data.count < 65_536 {
                let count = recv(descriptor, &buffer, buffer.count, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return nil }
                data.append(contentsOf: buffer.prefix(count))
                guard let range = data.range(of: separator),
                      let text = String(data: data[..<range.lowerBound], encoding: .utf8) else { continue }
                let lines = text.components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                guard first.count == 3 else { return nil }
                var headers = [String: String]()
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { return nil }
                    headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                guard (0...65_536).contains(length) else { return nil }
                guard data.count - range.upperBound >= length else { continue }
                return Request(method: String(first[0]), target: String(first[1]), headers: headers,
                    body: Data(data[range.upperBound..<(range.upperBound + length)]))
            }
            return nil
        }
    }

    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private let worker = DispatchGroup()
    private var stopped = false
    private var active: Int32?
    private var recorded = [Request]()
    private var accepted = 0

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

    func url(_ path: String = "/", host: String = "127.0.0.1") -> URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    init(handler: @escaping (Connection, Request, Int) -> Void) throws {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw ServerError.socketFailure }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            closeSocket(descriptor)
            throw ServerError.socketFailure
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard named == 0 else { closeSocket(descriptor); throw ServerError.socketFailure }
        listener = descriptor
        port = UInt16(bigEndian: address.sin_port)
        worker.enter()
        DispatchQueue(label: "monkeyspaw.tests.loopback-http").async { [self] in
            defer { worker.leave() }
            while true {
                lock.lock()
                let shouldStop = stopped
                lock.unlock()
                if shouldStop { return }
                var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&event, 1, 50) > 0, event.revents & Int16(POLLIN) != 0 else { continue }
                let peer = accept(listener, nil, nil)
                guard peer >= 0 else { continue }
                var timeout = timeval(tv_sec: 3, tv_usec: 0)
                _ = setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                // Flush each scripted write without Nagle's delay. Foundation
                // may still combine writes into a single delegate callback.
                var noDelay: Int32 = 1
                XCTAssertEqual(setsockopt(peer, Int32(IPPROTO_TCP), TCP_NODELAY, &noDelay,
                    socklen_t(MemoryLayout<Int32>.size)), 0)
                #if canImport(Darwin)
                var suppressPipe: Int32 = 1
                _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &suppressPipe, socklen_t(MemoryLayout<Int32>.size))
                #endif
                lock.lock()
                active = peer
                accepted += 1
                let cancelled = stopped
                lock.unlock()
                let connection = Connection(descriptor: peer)
                if !cancelled, let request = connection.readRequest() {
                    lock.lock()
                    recorded.append(request)
                    let index = recorded.count - 1
                    lock.unlock()
                    handler(connection, request, index)
                }
                lock.lock()
                active = nil
                closeSocket(peer)
                lock.unlock()
            }
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        if let active { _ = shutdown(active, Int32(SHUT_RDWR)) }
        lock.unlock()
        XCTAssertEqual(worker.wait(timeout: .now() + 6), .success, "Loopback worker did not stop")
        closeSocket(listener)
    }

    private enum ServerError: Error { case socketFailure }
}

private func closeSocket(_ descriptor: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(descriptor)
    #else
    _ = Glibc.close(descriptor)
    #endif
}

/// Captures actual framework stderr as well as errors the caller logs. Only
/// the redaction test redirects it, and restores it before making assertions.
final class HTTPTransportStderrCapture {
    private let pipe = Pipe()
    private let original: Int32
    private var restored = false

    init() throws {
        original = dup(STDERR_FILENO)
        guard original >= 0, dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) >= 0 else {
            if original >= 0 { closeSocket(original) }
            throw CaptureError.unavailable
        }
    }

    func finish() throws -> String {
        restore()
        try pipe.fileHandleForWriting.close()
        return String(data: try pipe.fileHandleForReading.readToEnd() ?? Data(), encoding: .utf8) ?? ""
    }

    private func restore() {
        guard !restored else { return }
        restored = true
        _ = dup2(original, STDERR_FILENO)
        closeSocket(original)
    }

    deinit { restore() }
    private enum CaptureError: Error { case unavailable }
}
