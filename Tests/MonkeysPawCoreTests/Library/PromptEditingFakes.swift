import Foundation
import XCTest
@testable import MonkeysPawCore

final class EditingThreadMarker {
    private(set) var isUI = false

    func ui<T>(_ work: () throws -> T) rethrows -> T {
        let previous = isUI
        isUI = true
        defer { isUI = previous }
        return try work()
    }

    func worker(_ work: () -> Void) {
        let previous = isUI
        isUI = false
        defer { isUI = previous }
        work()
    }
}

final class InlineBackgroundWork: BackgroundWork {
    let marker: EditingThreadMarker
    init(_ marker: EditingThreadMarker) { self.marker = marker }
    func run(_ work: @escaping () -> Void) { marker.worker(work) }
}

final class HeldBackgroundWork: BackgroundWork {
    let marker: EditingThreadMarker
    private(set) var pending: [() -> Void] = []
    init(_ marker: EditingThreadMarker) { self.marker = marker }
    func run(_ work: @escaping () -> Void) { pending.append(work) }
    func releaseNext() { marker.worker(pending.removeFirst()) }
    func releaseAll() { while !pending.isEmpty { releaseNext() } }
}

final class EditingMainThread: MainThread {
    let marker: EditingThreadMarker
    var isHeld = false
    var beforeRun: (() -> Void)?
    private(set) var pending: [() -> Void] = []
    init(_ marker: EditingThreadMarker) { self.marker = marker }

    func run(_ work: @escaping () -> Void) {
        beforeRun?()
        if isHeld { pending.append(work) }
        else { marker.ui(work) }
    }

    func releaseAll() {
        while !pending.isEmpty { marker.ui(pending.removeFirst()) }
    }
}

/// Covers every filesystem entry point, including history enumeration and
/// migration. Test setup and disk assertions use the unwrapped backing store.
final class EditingFileStore: FileStore {
    let memory: MemoryFileStore
    let marker: EditingThreadMarker
    var onList: (() throws -> Void)?
    var onDelete: ((String) throws -> Void)?

    init(_ memory: MemoryFileStore, marker: EditingThreadMarker) {
        self.memory = memory
        self.marker = marker
    }

    private func check() { XCTAssertFalse(marker.isUI, "Editor file I/O ran on the UI thread.") }
    func listFiles() throws -> [StoredFile] { check(); try onList?(); return try memory.listFiles() }
    func stamp(at path: String) throws -> FileStamp? { check(); return try memory.stamp(at: path) }
    func read(at path: String) throws -> Data { check(); return try memory.read(at: path) }
    func write(_ data: Data, at path: String) throws { check(); try memory.write(data, at: path) }
    func create(_ data: Data, at path: String) throws { check(); try memory.create(data, at: path) }
    func writePrivate(_ data: Data, at path: String) throws { check(); try memory.writePrivate(data, at: path) }
    func delete(at path: String) throws { check(); try onDelete?(path); try memory.delete(at: path) }
    func move(from source: String, to destination: String) throws { check(); try memory.move(from: source, to: destination) }
}

final class PromptEditingHarness {
    let marker = EditingThreadMarker()
    let files = MemoryFileStore()
    let data = MemoryFileStore()
    let clock = LibraryClock()
    let entropy = LibraryEntropy()
    let keyed = MemoryKeyedStore()
    let main: EditingMainThread
    let held: HeldBackgroundWork
    let libraryFiles: EditingFileStore
    let dataFiles: EditingFileStore
    let library: LibraryService
    let index: PromptIndex
    let editor: PromptEditingService

    init(heldWork: Bool = false) {
        main = EditingMainThread(marker)
        held = HeldBackgroundWork(marker)
        libraryFiles = EditingFileStore(files, marker: marker)
        dataFiles = EditingFileStore(data, marker: marker)
        library = LibraryService(library: libraryFiles, data: dataFiles, clock: clock,
                                 entropy: entropy, keyedStores: [keyed])
        let usage = UsageStore(files: dataFiles, clock: clock)
        index = PromptIndex(service: library, usage: usage, clock: clock)
        editor = PromptEditingService(library: library, index: index,
                                      work: heldWork ? held : InlineBackgroundWork(marker), main: main)
    }

    func open(_ source: String = "Original", at path: String = "a.md",
              changes: @escaping (PromptExternalChange) -> Void = { _ in }) throws -> (PromptEditingSession, LoadedPrompt) {
        try files.put(source, at: path)
        try index.rebuild()
        let session = marker.ui { editor.beginSession(at: path, onExternalChange: changes) }
        var result: PromptLoadOutcome?
        marker.ui { editor.load(session: session) { result = $0; XCTAssertTrue(self.marker.isUI) } }
        held.releaseAll()
        main.releaseAll()
        guard case .loaded(let loaded) = try XCTUnwrap(result) else { throw EditingTestError.unexpectedOutcome }
        return (session, loaded)
    }

    func save(_ source: String, session: PromptEditingSession, stamp: FileStamp?) throws -> PromptSaveOutcome {
        var result: PromptSaveOutcome?
        marker.ui {
            editor.save(source, session: session, expectedStamp: stamp) { result = $0; XCTAssertTrue(self.marker.isUI) }
        }
        held.releaseAll()
        main.releaseAll()
        return try XCTUnwrap(result)
    }

    func copy(_ source: String, near path: String, session: PromptEditingSession) throws -> PromptSaveOutcome {
        var result: PromptSaveOutcome?
        marker.ui {
            editor.createCopy(source, near: path, session: session) { result = $0; XCTAssertTrue(self.marker.isUI) }
        }
        held.releaseAll()
        main.releaseAll()
        return try XCTUnwrap(result)
    }
}

enum EditingTestError: Error { case unexpectedOutcome, privateDetails }
