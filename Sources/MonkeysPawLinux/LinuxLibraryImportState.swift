#if os(Linux)
import Foundation
import MonkeysPawCore

/// Retained by the library graph, so closing or destroying a window cannot
/// lose an in-flight import or its report. Core owns all file outcomes.
final class LinuxLibraryImportState {
    typealias SelectionPreparer = ([URL], @escaping ([ImportRequest]) -> Void) -> Void
    typealias Chooser = (LinuxImportSelectionMode, @escaping ([URL]) -> Void) -> (() -> Void)

    struct CompletedRequest {
        let request: ImportRequest
        let report: ImportReport
    }

    private(set) var isChoosing = false
    private(set) var isBusy = false
    private(set) var progress: ImportProgress?
    private(set) var reports: [CompletedRequest] = []
    private(set) var message: String?
    private(set) var destinations = [RelativePath(LinuxImportStrings.defaultDestination)]
    private(set) var destination = RelativePath(LinuxImportStrings.defaultDestination)
    private(set) var requestNumber = 0
    private(set) var requestCount = 0
    private(set) var libraryAvailable: Bool
    var onChange: (() -> Void)?
    var onChoose: Chooser?

    private let model: ImportModel
    private let main: MainThread
    private let prepare: SelectionPreparer
    private let openImported: (String) -> Bool
    private var active = true
    private var revision = UUID()
    private var chooserRequest: UUID?
    private var cancelChooser: (() -> Void)?
    private var pending: [ImportRequest] = []
    private var current: ImportRequest?
    private var batchDestination = LinuxImportStrings.defaultDestination

    init(model: ImportModel, available: Bool, main: MainThread,
         prepare: @escaping SelectionPreparer, openImported: @escaping (String) -> Bool) {
        self.model = model
        libraryAvailable = available
        self.main = main
        self.prepare = prepare
        self.openImported = openImported
        model.onChange = { [weak self] in self?.receive($0) }
    }

    var canImport: Bool { active && libraryAvailable && !isBusy && !isChoosing }
    var hasReport: Bool { !isBusy && !reports.isEmpty }
    var files: [ImportFileReport] {
        reports.flatMap { $0.report.files }.sorted { $0.sourcePath.utf8.lexicographicallyPrecedes($1.sourcePath.utf8) }
    }
    var createdCount: Int { reports.reduce(0) { $0 + $1.report.createdCount } }
    var skippedCount: Int { reports.reduce(0) { $0 + $1.report.skippedCount } }

    func setLibraryAvailable(_ available: Bool) {
        guard active else { return }
        libraryAvailable = available
        if !available { cancelChoosing() }
        onChange?()
    }

    func updateDestinations(_ sections: [LibraryBrowserSection]) {
        guard active else { return }
        destinations = [RelativePath(LinuxImportStrings.defaultDestination)] + sections.compactMap {
            guard case .folder(let path) = $0.id, path != RelativePath(LinuxImportStrings.defaultDestination) else { return nil }
            return path
        }
        if !isBusy, !destinations.contains(destination) { destination = RelativePath(LinuxImportStrings.defaultDestination) }
        onChange?()
    }

    func selectDestination(_ path: RelativePath) {
        guard canImport, destinations.contains(path) else { return }
        destination = path
        onChange?()
    }

    func choose(_ mode: LinuxImportSelectionMode) {
        guard canImport, let onChoose else { return }
        let request = UUID()
        chooserRequest = request
        isChoosing = true
        onChange?()
        let cancel = onChoose(mode) { [weak self] urls in
            self?.main.run { [weak self] in
                guard let self, self.active, self.chooserRequest == request else { return }
                self.chooserRequest = nil
                self.cancelChooser = nil
                self.isChoosing = false
                _ = self.importURLs(urls)
                self.onChange?()
            }
        }
        if chooserRequest == request { cancelChooser = cancel }
    }

    func cancelChoosing() {
        chooserRequest = nil
        let cancel = cancelChooser
        cancelChooser = nil
        isChoosing = false
        cancel?()
        onChange?()
    }

    /// Native chooser and GtkDropTarget both enter this intent.
    @discardableResult
    func importURLs(_ urls: [URL]) -> Bool {
        guard canImport, !urls.isEmpty else { return false }
        let local = urls.filter {
            $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host?.lowercased() == "localhost")
        }
        guard !local.isEmpty else { message = LinuxImportStrings.fileURLsOnly; onChange?(); return false }
        revision = UUID()
        let token = revision
        batchDestination = destination.string
        reports = []
        message = local.count == urls.count ? nil : LinuxImportStrings.fileURLsOnly
        progress = .enumerating
        requestNumber = 0
        requestCount = 0
        isBusy = true
        onChange?()
        prepare(local) { [weak self] requests in
            self?.main.run { [weak self] in
                guard let self, self.active, self.revision == token else { return }
                self.pending = requests
                self.requestCount = requests.count
                self.startNext()
            }
        }
        return true
    }

    func dismissReport() {
        guard active, !isBusy else { return }
        reports = []
        message = nil
        onChange?()
    }

    func open(_ path: String) {
        guard active, libraryAvailable, files.contains(where: {
            if case .created(let created) = $0.outcome { return created.utf8.elementsEqual(path.utf8) }
            return false
        }) else { return }
        message = openImported(path) ? nil : LinuxImportStrings.waitingForRefresh
        onChange?()
    }

    func deactivate() {
        guard active else { return }
        active = false
        revision = UUID()
        cancelChoosing()
        pending = []
        current = nil
        model.deactivate()
        isBusy = false
        progress = nil
        reports = []
        libraryAvailable = false
        onChange = nil
        onChoose = nil
    }

    private func startNext() {
        guard active else { return }
        guard !pending.isEmpty else {
            isBusy = false
            progress = nil
            if !destinations.contains(destination) { destination = RelativePath(LinuxImportStrings.defaultDestination) }
            onChange?()
            return
        }
        let request = pending.removeFirst()
        current = request
        requestNumber += 1
        switch request {
        case .files(let paths): model.importFiles(at: paths, into: batchDestination)
        case .folder(let path): model.importFolder(at: path, into: batchDestination)
        }
    }

    private func receive(_ state: ImportModel.State) {
        guard active, isBusy else { return }
        progress = state.progress
        if !state.isImporting, let report = state.report, let current {
            reports.append(CompletedRequest(request: current, report: report))
            self.current = nil
            startNext()
        }
        onChange?()
    }
}
#endif
