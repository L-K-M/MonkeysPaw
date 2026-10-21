import Foundation
import MonkeysPawCore
import SwiftUI
import UniformTypeIdentifiers

/// Native selection plumbing only; Core owns conversion, writes and typed
/// reports. Mixed selections run as one busy batch of Core intents.
final class LibraryImportViewState: ObservableObject {
    typealias SelectionPreparer = ([URL], @escaping ([ImportRequest]) -> Void) -> Void
    typealias Chooser = (@escaping ([URL]) -> Void) -> (() -> Void)

    struct CompletedRequest {
        let request: ImportRequest
        let report: ImportReport
        var source: String {
            switch request {
            case .files: return ImportStrings.selectedFiles
            case .folder(let path): return path
            }
        }
    }

    @Published private(set) var isChoosing = false
    @Published private(set) var isBusy = false
    @Published private(set) var progress: ImportProgress?
    @Published private(set) var reports: [CompletedRequest] = []
    @Published private(set) var selectionMessage: String?
    @Published private(set) var destinations = [RelativePath(ImportStrings.defaultDestination)]
    @Published private(set) var destination = RelativePath(ImportStrings.defaultDestination)
    @Published private(set) var requestNumber = 0
    @Published private(set) var requestCount = 0
    @Published private(set) var libraryAvailable: Bool
    var onChoose: Chooser?
    var onAvailabilityChange: (() -> Void)?

    private let model: ImportModel
    private let main: MainThread
    private let prepare: SelectionPreparer
    private let openImported: (String) -> Bool
    private var active = true
    private var revision = UUID()
    private var chooserRequest: UUID?
    private var cancelChooser: (() -> Void)?
    private var dropLoads: [Progress] = []
    private var pending: [ImportRequest] = []
    private var current: ImportRequest?
    private var batchDestination = ImportStrings.defaultDestination

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
        reports.flatMap { $0.report.files }.sorted {
            $0.sourcePath.utf8.lexicographicallyPrecedes($1.sourcePath.utf8)
        }
    }
    var createdCount: Int { reports.reduce(0) { $0 + $1.report.createdCount } }
    var skippedCount: Int { reports.reduce(0) { $0 + $1.report.skippedCount } }

    func setLibraryAvailable(_ available: Bool) {
        guard active else { return }
        libraryAvailable = available
        if !available {
            if isBusy { selectionMessage = ImportStrings.libraryLost }
            retireWork()
        }
        onAvailabilityChange?()
    }

    func updateDestinations(_ sections: [LibraryBrowserSection]) {
        guard active else { return }
        let folders = sections.compactMap { section -> RelativePath? in
            guard case .folder(let path) = section.id,
                  path != RelativePath(ImportStrings.defaultDestination) else { return nil }
            return path
        }
        let updated = [RelativePath(ImportStrings.defaultDestination)] + folders
        if destinations != updated { destinations = updated }
        if !isBusy, !destinations.contains(destination) { destination = RelativePath(ImportStrings.defaultDestination) }
    }

    func selectDestination(_ path: RelativePath) {
        // The native chooser's accessory selects its batch destination while
        // that chooser owns the sheet; imports cannot already be running.
        guard active, libraryAvailable, !isBusy, destinations.contains(path) else { return }
        destination = path
    }

    func choose() {
        guard canImport, let onChoose else { return }
        let request = UUID()
        chooserRequest = request
        isChoosing = true
        onAvailabilityChange?()
        let cancel = onChoose { [weak self] urls in
            self?.main.run { [weak self] in
                guard let self, self.active, self.chooserRequest == request else { return }
                self.chooserRequest = nil
                self.cancelChooser = nil
                self.isChoosing = false
                self.onAvailabilityChange?()
                _ = self.importURLs(urls)
            }
        }
        // The injected chooser may complete inline.
        if chooserRequest == request { cancelChooser = cancel }
    }

    func cancelChoosing() {
        chooserRequest = nil
        let cancel = cancelChooser
        cancelChooser = nil
        isChoosing = false
        cancel?()
        onAvailabilityChange?()
    }

    /// The same intent handles decoded Finder drops and injected test URLs.
    @discardableResult
    func importURLs(_ urls: [URL]) -> Bool {
        guard canImport, !urls.isEmpty else { return false }
        let local = urls.filter(\.isFileURL)
        guard !local.isEmpty else { selectionMessage = ImportStrings.fileURLsOnly; return false }
        beginBatch()
        if local.count != urls.count { selectionMessage = ImportStrings.fileURLsOnly }
        prepare(local, for: revision)
        return true
    }

    @discardableResult
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canImport else { return false }
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !providers.isEmpty else { return false }
        beginBatch()
        let token = revision
        var received = 0
        var urls: [Int: URL] = [:]
        for (index, provider) in providers.enumerated() {
            let load = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, _ in
                self?.main.run { [weak self] in
                    guard let self, self.active, self.revision == token else { return }
                    if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                        urls[index] = url
                    } else { self.selectionMessage = ImportStrings.dropReadFailed }
                    received += 1
                    guard received == providers.count else { return }
                    self.dropLoads = []
                    let selection = urls.sorted { $0.key < $1.key }.map(\.value)
                    if selection.isEmpty { self.finishBatch() }
                    else { self.prepare(selection, for: token) }
                }
            }
            if active, revision == token, received < providers.count { dropLoads.append(load) }
        }
        return true
    }

    func dismissReport() {
        guard !isBusy else { return }
        reports = []
        selectionMessage = nil
    }

    func open(_ path: String) {
        guard active, libraryAvailable, files.contains(where: {
            if case .created(let created) = $0.outcome { return created.utf8.elementsEqual(path.utf8) }
            return false
        }) else { return }
        selectionMessage = openImported(path) ? nil : ImportStrings.waitingForRefresh
    }

    func deactivate() {
        retireWork()
        reports = []
        libraryAvailable = false
        onChoose = nil
        onAvailabilityChange = nil
    }

    /// Library loss retires the model while retaining completed selections.
    /// Only a replacement graph can import again after this retirement.
    private func retireWork() {
        guard active else { return }
        active = false
        revision = UUID()
        cancelChoosing()
        for load in dropLoads { load.cancel() }
        dropLoads = []
        pending = []
        current = nil
        model.deactivate()
        isBusy = false
        progress = nil
    }

    private func beginBatch() {
        revision = UUID()
        batchDestination = destination.string
        reports = []
        selectionMessage = nil
        progress = .enumerating
        requestNumber = 0
        requestCount = 0
        isBusy = true
        onAvailabilityChange?()
    }

    private func prepare(_ urls: [URL], for token: UUID) {
        prepare(urls) { [weak self] requests in
            self?.main.run { [weak self] in
                guard let self, self.active, self.revision == token else { return }
                self.pending = requests
                self.requestCount = requests.count
                self.startNext()
            }
        }
    }

    private func startNext() {
        guard active else { return }
        guard !pending.isEmpty else { finishBatch(); return }
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
        guard !state.isImporting, let report = state.report, let current else { return }
        reports.append(CompletedRequest(request: current, report: report))
        self.current = nil
        startNext()
    }

    private func finishBatch() {
        isBusy = false
        progress = nil
        if !destinations.contains(destination) { destination = RelativePath(ImportStrings.defaultDestination) }
        onAvailabilityChange?()
    }
}
