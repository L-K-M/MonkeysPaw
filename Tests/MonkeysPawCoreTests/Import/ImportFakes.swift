import Foundation
@testable import MonkeysPawCore

final class ImportWorkQueue: BackgroundWork {
    private(set) var jobs: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { jobs.append(work) }
    func drain() {
        while !jobs.isEmpty { jobs.removeFirst()() }
    }
}

final class ImportMainQueue: MainThread {
    private(set) var jobs: [() -> Void] = []
    func run(_ work: @escaping () -> Void) { jobs.append(work) }
    func drain() {
        while !jobs.isEmpty { jobs.removeFirst()() }
    }
}

final class ImportInlineMain: MainThread {
    func run(_ work: @escaping () -> Void) { work() }
}

final class ImportMemorySources: ImportSourceReading {
    var files: [Data: Data] = [:]
    var entries: [ImportSourceEntry] = []
    var listError: ImportSourceError?
    var readErrors: [Data: ImportSourceError] = [:]
    var onRead: ((String) -> Void)?
    private(set) var listed: [String] = []
    private(set) var reads: [(String, Int)] = []

    func put(_ source: String, at path: String) { files[Data(path.utf8)] = Data(source.utf8) }
    func listFiles(in folderPath: String) throws -> [ImportSourceEntry] {
        listed.append(folderPath)
        if let listError { throw listError }
        return entries
    }
    func readFile(at path: String, maximumBytes: Int) throws -> Data {
        reads.append((path, maximumBytes))
        onRead?(path)
        if let error = readErrors[Data(path.utf8)] { throw error }
        guard let data = files[Data(path.utf8)] else { throw ImportSourceError.notFound }
        guard data.count <= maximumBytes else { throw ImportSourceError.fileTooLarge }
        return data
    }
}

final class ImportSequenceEntropy: EntropySource {
    private(set) var count = 0
    func bytes(count: Int) throws -> [UInt8] {
        self.count += 1
        return Array(repeating: UInt8(self.count % 256), count: count)
    }
}

struct ImportTestGraph {
    let files = MemoryFileStore()
    let data = MemoryFileStore()
    let sources = ImportMemorySources()
    let work = ImportWorkQueue()
    let main = ImportMainQueue()
    let clock = LibraryClock()
    let entropy = ImportSequenceEntropy()
    let library: LibraryService
    let service: ImportService

    init() {
        library = LibraryService(library: files, data: data, clock: clock, entropy: entropy)
        service = ImportService(library: library, sources: sources, work: work, main: main)
    }

    func run(_ request: ImportRequest, into folder: String = "Imported") -> ImportReport? {
        var report: ImportReport?
        service.import(request, into: folder) { report = $0 }
        work.drain()
        main.drain()
        return report
    }
}
