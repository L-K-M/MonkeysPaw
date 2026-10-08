#if os(Linux)
import Foundation
import Glibc

enum YdotoolSocket {
    static let legacyPath = "/tmp/.ydotool_socket"

    /// §6.3 / Copywraith: respect an explicit override, then runtime, then /tmp.
    static func path(in environment: [String: String]) -> String {
        if let override = environment["YDOTOOL_SOCKET"], !override.isEmpty { return override }
        if let runtime = environment["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: runtime).appendingPathComponent(".ydotool_socket").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return legacyPath
    }

    static func isReachable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_mode & 0o666 != 0, access(path, R_OK | W_OK) == 0 else { return false }

        // A local, nonblocking connect distinguishes a live daemon from a stale
        // socket file without injecting any keys. Older daemons use streams.
        for kind in [SOCK_DGRAM, SOCK_STREAM] {
            let descriptor = socket(AF_UNIX, Int32(kind.rawValue | SOCK_NONBLOCK.rawValue), 0)
            guard descriptor >= 0 else { continue }
            let reachable = withAddress(path) { address, length in
                connect(descriptor, address, length) == 0
            } ?? false
            _ = Glibc.close(descriptor)
            if reachable { return true }
        }
        return false
    }

    static func withAddress<T>(_ path: String,
                               _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
#endif
