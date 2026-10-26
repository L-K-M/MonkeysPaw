import Foundation

/// Version-1 settings contain library, first-run and desktop preferences.
/// Platform composition computes the default folder when the path is nil.
public struct SettingsDocument: Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int { Self.currentVersion }
    public let libraryFolderPath: String?
    public let firstRun: FirstRunProgress
    public let delivery: DeliveryPreferences
    public let automaticUpdateChecks: AutomaticUpdateChecks
    public let creepy: CreepyMode
    public let carbonShortcuts: CarbonShortcutChoices

    public init() {
        libraryFolderPath = nil
        firstRun = FirstRunProgress()
        delivery = DeliveryPreferences()
        automaticUpdateChecks = .enabled
        creepy = .enabled
        carbonShortcuts = CarbonShortcutChoices()
    }

    public init(libraryFolderPath: String?, firstRun: FirstRunProgress = FirstRunProgress(),
                delivery: DeliveryPreferences = DeliveryPreferences(),
                automaticUpdateChecks: AutomaticUpdateChecks = .enabled,
                creepy: CreepyMode = .enabled,
                carbonShortcuts: CarbonShortcutChoices = CarbonShortcutChoices()) throws {
        if let path = libraryFolderPath {
            // A combining scalar can join the slash's grapheme; POSIX paths
            // are absolute based on the separator byte, not text prefixes.
            guard path.utf8.first == UInt8(ascii: "/"),
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw SettingsError.invalidLibraryFolder
            }
        }
        self.libraryFolderPath = libraryFolderPath
        self.firstRun = firstRun
        self.delivery = delivery
        self.automaticUpdateChecks = automaticUpdateChecks
        self.creepy = creepy
        self.carbonShortcuts = carbonShortcuts
    }

    // A chosen root can distinguish canonically equivalent filenames (§5.1).
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.libraryFolderPath.map { Data($0.utf8) } == rhs.libraryFolderPath.map { Data($0.utf8) }
            && lhs.firstRun == rhs.firstRun
            && lhs.delivery == rhs.delivery
            && lhs.automaticUpdateChecks == rhs.automaticUpdateChecks
            && lhs.creepy == rhs.creepy
            && lhs.carbonShortcuts == rhs.carbonShortcuts
    }
}

/// General owns update controls; the preference shares settings.json (§17 Q11).
public enum AutomaticUpdateChecks: String, Codable, CaseIterable, Sendable {
    case enabled
    case disabled
}

public enum CreepyMode: String, Codable, CaseIterable, Sendable {
    case enabled
    case disabled
}

public struct FirstRunProgress: Codable, Equatable, Sendable {
    public let setupPresented: Bool
    public let libraryFolderCompleted: Bool
    public let seedsOffered: Bool
    public let tourCompleted: Bool

    private enum CodingKeys: String, CodingKey {
        case setupPresented, libraryFolderCompleted, seedsOffered, tourCompleted
    }

    public init(setupPresented: Bool = false, libraryFolderCompleted: Bool = false,
                seedsOffered: Bool = false, tourCompleted: Bool = false) {
        self.setupPresented = setupPresented
        self.libraryFolderCompleted = libraryFolderCompleted
        self.seedsOffered = seedsOffered
        self.tourCompleted = tourCompleted
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        setupPresented = try values.decode(Bool.self, forKey: .setupPresented)
        libraryFolderCompleted = try values.decode(Bool.self, forKey: .libraryFolderCompleted)
        seedsOffered = try values.decode(Bool.self, forKey: .seedsOffered)
        // Version 1 predates the tour. Only an omitted key uses the upgrade
        // rule; a present non-boolean value must still fail closed.
        tourCompleted = values.contains(.tourCompleted)
            ? try values.decode(Bool.self, forKey: .tourCompleted) : setupPresented
    }
}

/// Composition supplies the M1 fact; Core never reads platform flags itself.
public enum LegacyFirstRun: Sendable {
    case setupNotPresented
    case setupPresented
}

/// Sanitized errors carry neither paths nor underlying error text.
public enum SettingsError: Error, Equatable, Sendable {
    case futureVersion(Int)
    case unsupportedVersion(Int)
    case corruptFile
    case readFailed(FileStoreError)
    case writeFailed(FileStoreError)
    case invalidLibraryFolder
}

public struct SettingsSnapshot: Equatable, Sendable {
    public let document: SettingsDocument
    public let readOnlyError: SettingsError?
    public var isReadOnly: Bool { readOnlyError != nil }
    /// Failed-closed defaults must never be mistaken for update-check consent.
    public var allowsAutomaticUpdateChecks: Bool {
        !isReadOnly && document.automaticUpdateChecks == .enabled
    }
}
