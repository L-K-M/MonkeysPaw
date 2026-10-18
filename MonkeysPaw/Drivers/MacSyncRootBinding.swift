import Foundation
import MonkeysPawCore

enum MacSyncRootIssue: Error {
    case changed, unverified, metadataUnavailable

    var message: String {
        switch self {
        case .changed: return "The library folder was replaced. Choose a different library folder to restore prompts through sync."
        case .unverified: return "The saved library folder cannot be verified. Restore its sync metadata or choose a different library folder."
        case .metadataUnavailable: return "The library identity could not be saved or read. Restore access to app data before syncing."
        }
    }
}

/// Non-secret native evidence supplements Core's lexical account/root binding.
/// Keep earlier roots so a crash midway through a folder switch cannot erase
/// proof for the still-saved choice. No root mismatch authorizes deletion.
final class MacSyncRootBinding {
    enum Preparation { case freshLibrary, recordedLibrary }
    private struct Record: Codable { let root: String; let identity: FileStamp }
    private struct Document: Codable { let version: Int; var roots: [Record] }
    private let data: RootedFileStore
    private let path = "sync/macos-roots.json"

    init(data: RootedFileStore) { self.data = data }

    func prepare(library: RootedFileStore, lexicalRoot: String, mode: Preparation) throws {
        do {
            let identity = try library.rootIdentity()
            var document: Document
            var original: [String: Any] = [:]
            do {
                let bytes = try data.read(at: path)
                guard bytes.count <= Limits.syncRecordMaxBytes else { throw MacSyncRootIssue.metadataUnavailable }
                document = try JSONDecoder().decode(Document.self, from: bytes)
                original = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
                guard document.version == 1,
                      document.roots.allSatisfy({ $0.root.hasPrefix("/") && !$0.root.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
                      Set(document.roots.map { Data($0.root.utf8) }).count == document.roots.count else {
                    throw MacSyncRootIssue.metadataUnavailable
                }
            } catch FileStoreError.notFound { document = Document(version: 1, roots: []) }
            let previous = document.roots.first { $0.root.utf8.elementsEqual(lexicalRoot.utf8) }
            if mode == .recordedLibrary {
                guard let previous else { throw MacSyncRootIssue.unverified }
                guard previous.identity == identity else { throw MacSyncRootIssue.changed }
            }
            if previous?.identity != identity {
                document.roots.removeAll { $0.root.utf8.elementsEqual(lexicalRoot.utf8) }
                document.roots.append(Record(root: lexicalRoot, identity: identity))
                let encoded = try JSONEncoder().encode(document)
                guard let known = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                      let records = known["roots"] as? [[String: Any]] else { throw MacSyncRootIssue.metadataUnavailable }
                let oldRecords = original["roots"] as? [[String: Any]] ?? []
                original["version"] = document.version
                original["roots"] = records.map { record in
                    var retained = oldRecords.first { old in
                        guard let left = old["root"] as? String, let right = record["root"] as? String else { return false }
                        return left.utf8.elementsEqual(right.utf8)
                    } ?? [:]
                    var identity = retained["identity"] as? [String: Any] ?? [:]
                    for (key, value) in record["identity"] as? [String: Any] ?? [:] { identity[key] = value }
                    retained["root"] = record["root"]
                    retained["identity"] = identity
                    return retained
                }
                let bytes = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
                guard bytes.count <= Limits.syncRecordMaxBytes else { throw MacSyncRootIssue.metadataUnavailable }
                try data.writePrivate(bytes, at: path)
            }
            // Reflush even a matching record: a previous process could have
            // published it without confirming the directory's durability.
            try data.flushFile(at: RelativePath(path))
            try data.flushDirectory(at: "sync")
            try data.flushDirectory(at: nil)
        } catch let issue as MacSyncRootIssue { throw issue }
        catch FileStoreError.notFound { throw MacSyncRootIssue.changed }
        catch { throw MacSyncRootIssue.metadataUnavailable }
    }
}
