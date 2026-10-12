import Foundation

/// One service per library graph, sharing LibraryService and serial work with
/// other library mutations. Source drivers own bounded, symlink-safe I/O.
public final class ImportService {
    private struct Candidate {
        let sourcePath: String
        let relativePath: String
        let kind: ImportSourceKind
    }

    private let library: LibraryService
    private let sources: ImportSourceReading
    private let work: BackgroundWork
    private let main: MainThread
    private let lock = NSLock()
    private var active = true

    public init(library: LibraryService, sources: ImportSourceReading, work: BackgroundWork, main: MainThread) {
        self.library = library
        self.sources = sources
        self.work = work
        self.main = main
    }

    /// UI-thread intent. All I/O and codec work is queued; every live request
    /// completes once on MainThread, including enumeration/destination failures.
    public func `import`(_ request: ImportRequest, into subfolder: String = "Imported",
                         progress: @escaping (ImportProgress) -> Void = { _ in },
                         completion: @escaping (ImportReport) -> Void) {
        work.run { [weak self] in
            guard let self, self.isActive else { return }
            self.publish(.enumerating, to: progress)
            let report = self.perform(request, into: subfolder, progress: progress)
            self.main.run { [weak self] in
                guard let self, self.isActive else { return }
                completion(report)
            }
        }
    }

    /// Drop queued work and callbacks when replacing the library graph. A
    /// publication already executing may complete; later files never start.
    public func deactivate() {
        lock.lock()
        active = false
        lock.unlock()
    }

    private var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    private func perform(_ request: ImportRequest, into subfolder: String,
                         progress: @escaping (ImportProgress) -> Void) -> ImportReport {
        let candidates: [Candidate]
        do {
            try FileStorePath.validate(subfolder)
            try LibraryPath.validate(subfolder + "/import.md")
            candidates = try enumerate(request).sorted {
                if !$0.sourcePath.utf8.elementsEqual($1.sourcePath.utf8) {
                    return $0.sourcePath.utf8.lexicographicallyPrecedes($1.sourcePath.utf8)
                }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        } catch {
            return ImportReport(files: [], failure: reason(error))
        }

        publish(.importing(completed: 0, total: candidates.count), to: progress)
        var files: [ImportFileReport] = []
        var seen = Set<Data>()
        for candidate in candidates {
            guard isActive else { break }
            let file: ImportFileReport
            if !seen.insert(Data(candidate.sourcePath.utf8)).inserted {
                file = ImportFileReport(sourcePath: candidate.sourcePath, outcome: .skipped(.duplicateSource),
                                        mapping: ImportMappingReport())
            } else { file = importFile(candidate, into: subfolder) }
            files.append(file)
            publish(.importing(completed: files.count, total: candidates.count), to: progress)
        }
        return ImportReport(files: files, failure: nil)
    }

    private func enumerate(_ request: ImportRequest) throws -> [Candidate] {
        switch request {
        case .files(let paths):
            return paths.map { Candidate(sourcePath: $0, relativePath: LibraryPath.filename($0), kind: .regularFile) }
        case .folder(let path):
            let folder = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
            try validateSourcePath(folder)
            return try sources.listFiles(in: folder).map {
                Candidate(sourcePath: folder + (folder == "/" ? "" : "/") + $0.relativePath,
                          relativePath: $0.relativePath, kind: $0.kind)
            }
        }
    }

    private func importFile(_ candidate: Candidate, into subfolder: String) -> ImportFileReport {
        var mapping = ImportMappingReport()
        do {
            try validateSourcePath(candidate.sourcePath)
            try FileStorePath.validate(candidate.relativePath)
            switch candidate.kind {
            case .symbolicLink: throw ImportSkipReason.symbolicLink
            case .other: throw ImportSkipReason.notRegularFile
            case .regularFile: break
            }
            guard let format = ImportFormat.filename(candidate.relativePath) else {
                throw ImportSkipReason.unsupportedExtension
            }
            let destination = subfolder + "/" + String(candidate.relativePath.dropLast(format.sourceExtension.count)) + ".md"
            try LibraryPath.validate(destination)
            let data = try sources.readFile(at: candidate.sourcePath, maximumBytes: Limits.importFileCapBytes)
            let mapped = try ImportMapper.map(data, filename: LibraryPath.filename(candidate.relativePath))
            mapping = mapped.report
            let created = try library.createImported(mapped.document, at: destination)
            if created.reassigned {
                mapping.warnings.append(.identityReassigned)
            }
            if created.presentationLost, !mapping.dropped.contains(.frontMatterPresentation) {
                mapping.dropped.append(.frontMatterPresentation)
            }
            return ImportFileReport(sourcePath: candidate.sourcePath, outcome: .created(path: created.path), mapping: mapping)
        } catch {
            return ImportFileReport(sourcePath: candidate.sourcePath, outcome: .skipped(reason(error)), mapping: mapping)
        }
    }

    private func publish(_ value: ImportProgress, to callback: @escaping (ImportProgress) -> Void) {
        main.run { [weak self] in
            guard let self, self.isActive else { return }
            callback(value)
        }
    }

    private func validateSourcePath(_ path: String) throws {
        guard FileStorePath.isValid(path, mode: .absolute) else {
            throw ImportSkipReason.invalidPath
        }
    }

    private func reason(_ error: Error) -> ImportSkipReason {
        switch error {
        case let error as ImportSkipReason: return error
        case ImportSourceError.fileTooLarge: return .fileTooLarge
        case ImportSourceError.symbolicLink: return .symbolicLink
        case ImportSourceError.notRegularFile: return .notRegularFile
        case let error as ImportSourceError: return .source(error)
        case FileStoreError.invalidPath, LibraryError.invalidPromptPath: return .invalidPath
        case let error as FileStoreError: return .fileStore(error)
        case let error as LibraryError: return .library(error)
        case let error as ULIDGenerationError: return .identityGeneration(error)
        default: return .library(.operationFailed)
        }
    }
}
