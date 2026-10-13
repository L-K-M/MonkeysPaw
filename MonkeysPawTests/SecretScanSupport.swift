import Foundation

/// Kept in each native test target so scanning needs no production API or dependency.
struct SecretScan {
    enum Failure: Error { case unreadableTree }
    private let patterns: [Data]

    init(_ sentinel: String) throws {
        var variants = Set([sentinel, Data(sentinel.utf8).base64EncodedString()])
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for allowed in [unreserved, .alphanumerics, .urlQueryAllowed] {
            if let encoded = sentinel.addingPercentEncoding(withAllowedCharacters: allowed) {
                variants.insert(encoded)
            }
        }
        // Credentials are JSON inside the secret store's own JSON map.
        var escaped = Set([sentinel])
        for _ in 0..<2 {
            var next = Set<String>()
            for value in escaped {
                let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                let inner = String(json.dropFirst().dropLast())
                next.insert(inner)
                next.insert(inner.replacingOccurrences(of: "\\/", with: "/"))
                next.insert(inner.replacingOccurrences(of: "\\/", with: "/")
                    .replacingOccurrences(of: "/", with: "\\/"))
            }
            variants.formUnion(next)
            escaped = next
        }
        patterns = variants.map { Data($0.utf8) }
    }

    func copyCount(in bytes: Data) -> Int {
        var starts = Set<Int>()
        for pattern in patterns {
            var offset = bytes.startIndex
            while offset < bytes.endIndex,
                  let range = bytes.range(of: pattern, in: offset..<bytes.endIndex) {
                starts.insert(range.lowerBound)
                offset = range.upperBound
            }
        }
        return starts.count
    }

    func matches(in roots: [URL]) throws -> Set<URL> {
        var visited = Set<URL>()
        var matches = Set<URL>()
        for root in roots {
            var failed = false
            guard let files = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [], errorHandler: { _, _ in failed = true; return false }) else {
                throw Failure.unreadableTree
            }
            for case let file as URL in files {
                let canonical = file.standardizedFileURL
                guard visited.insert(canonical).inserted else { continue }
                let kind = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard kind.isRegularFile == true, kind.isSymbolicLink != true else { continue }
                if try containsCopy(in: file) { matches.insert(canonical) }
            }
            if failed { throw Failure.unreadableTree }
        }
        return matches
    }

    private func containsCopy(in file: URL) throws -> Bool {
        let stream = try FileHandle(forReadingFrom: file)
        defer { try? stream.close() }
        let overlap = patterns.map(\.count).max()! - 1
        var tail = Data()
        // Logs/results may change during the scan; avoid mapping a truncated file.
        while let chunk = try stream.read(upToCount: 65_536), !chunk.isEmpty {
            let bytes = tail + chunk
            if patterns.contains(where: { bytes.range(of: $0) != nil }) { return true }
            tail = Data(bytes.suffix(overlap))
        }
        return false
    }
}
