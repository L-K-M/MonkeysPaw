import Foundation
import MonkeysPawCore

/// Failed initialization remains an explicit failure without resetting state.
struct UnavailableFileStore: FileStore {
    func listFiles() throws -> [StoredFile] { throw FileStoreError.ioFailure }
    func stamp(at path: String) throws -> FileStamp? { throw FileStoreError.ioFailure }
    func read(at path: String) throws -> Data { throw FileStoreError.ioFailure }
    func write(_ data: Data, at path: String) throws { throw FileStoreError.ioFailure }
    func create(_ data: Data, at path: String) throws { throw FileStoreError.ioFailure }
    func writePrivate(_ data: Data, at path: String) throws { throw FileStoreError.ioFailure }
    func delete(at path: String) throws { throw FileStoreError.ioFailure }
    func move(from source: String, to destination: String) throws { throw FileStoreError.ioFailure }
}
