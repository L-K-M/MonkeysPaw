/// Preferences are policy inputs; saving them does not perform a delivery.
public struct DeliveryPreferences: Codable, Equatable, Sendable {
    /// Applies to Linux's preferred intent; explicit paste/copy intents win.
    public let linuxDefaultPasteChord: PasteChord
    public let clipboardRestore: ClipboardRestoreMode

    public init(linuxDefaultPasteChord: PasteChord = .standard,
                clipboardRestore: ClipboardRestoreMode = .off) {
        self.linuxDefaultPasteChord = linuxDefaultPasteChord
        self.clipboardRestore = clipboardRestore
    }

    private enum CodingKeys: String, CodingKey {
        case linuxDefaultPasteChord, clipboardRestore
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Only missing version-1 fields use defaults; null or unknown modes fail.
        linuxDefaultPasteChord = values.contains(.linuxDefaultPasteChord)
            ? try values.decode(PasteChord.self, forKey: .linuxDefaultPasteChord) : .standard
        clipboardRestore = values.contains(.clipboardRestore)
            ? try values.decode(ClipboardRestoreMode.self, forKey: .clipboardRestore) : .off
    }
}

/// Restore is opt-in and limited to previous text, never arbitrary formats.
public enum ClipboardRestoreMode: String, Codable, CaseIterable, Sendable {
    case off
    case previousText
}
