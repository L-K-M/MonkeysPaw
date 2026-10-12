import Foundation

/// Source bytes must not depend on Foundation's platform-specific BOM handling.
enum PromptUTF8 {
    private static let bom: [UInt8] = [0xef, 0xbb, 0xbf]

    static func decode(_ data: Data) -> String? {
        let hasBOM = data.starts(with: bom)
        let content = data.dropFirst(hasBOM ? bom.count : 0)
        let text = String(decoding: Array(content), as: UTF8.self)
        // The repairing decoder is strict only when its bytes round-trip.
        guard text.utf8.elementsEqual(content) else { return nil }
        return hasBOM ? "\u{feff}" + text : text
    }

    static func encode(_ source: String) -> Data {
        let bytes = source.utf8
        guard bytes.starts(with: bom) else { return Data(bytes) }
        var data = Data(bom)
        data.append(contentsOf: bytes.dropFirst(bom.count))
        return data
    }
}
