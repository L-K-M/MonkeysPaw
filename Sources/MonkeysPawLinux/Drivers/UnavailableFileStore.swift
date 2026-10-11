#if os(Linux)
import Foundation
import MonkeysPawCore

/// Failed root initialization stays an explicit I/O failure. The app can still
/// show Setup and the unavailable banner without resetting persistent state.
struct UnavailableFileStore: FileStore {
    func listFiles() throws -> [StoredFile] { throw FileStoreError.ioFailure }
    func stamp(at path: String) throws -> FileStamp? { throw FileStoreError.ioFailure }
    func read(at path: String) throws -> Data { throw FileStoreError.ioFailure }
    func write(_ data: Data, at path: String) throws { throw FileStoreError.ioFailure }
    func writePrivate(_ data: Data, at path: String) throws { throw FileStoreError.ioFailure }
    func delete(at path: String) throws { throw FileStoreError.ioFailure }
    func move(from source: String, to destination: String) throws { throw FileStoreError.ioFailure }
}
#endif
