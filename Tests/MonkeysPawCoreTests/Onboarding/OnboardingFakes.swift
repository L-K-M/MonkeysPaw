import Foundation
import XCTest
@testable import MonkeysPawCore

final class FakeLibraryAvailabilityNotifier: LibraryAvailabilityNotifier {
    private let main: FakeMainThread
    private(set) var requests = 0

    init(main: FakeMainThread) { self.main = main }

    func libraryUnavailable() {
        XCTAssertTrue(main.isRunning)
        requests += 1
    }
}

final class OnboardingHarness {
    let settingsFiles: MemoryFileStore
    let main = FakeMainThread()
    let settings: SettingsModel
    let notifier: FakeLibraryAvailabilityNotifier
    let status: LibraryStatusModel
    let location: OnboardingLibraryLocation
    var serverConfigured = false
    var emptinessFailure: Error?
    var copyFailure: Error?
    private(set) var emptinessChecks = 0
    private(set) var copies = 0

    init(settingsFiles: MemoryFileStore = MemoryFileStore(),
         libraryFiles: MemoryFileStore = MemoryFileStore(),
         legacy: LegacyFirstRun = .setupNotPresented,
         health: LibraryStatusModel.State = .available) {
        self.settingsFiles = settingsFiles
        settings = SettingsModel(settings: SettingsService(store:
            SettingsStore(files: settingsFiles, legacyFirstRun: legacy)))
        notifier = FakeLibraryAvailabilityNotifier(main: main)
        status = LibraryStatusModel(initialState: health, mainThread: main,
            notifyStartupUnavailable: notifier.libraryUnavailable)
        location = OnboardingLibraryLocation(settings: settings, settingsFiles: settingsFiles,
            status: status, main: main, graph: OnboardingLibraryGraph(files: libraryFiles))
    }

    func makeModel() -> OnboardingModel {
        OnboardingModel(settings: settings, library: location, status: status, mainThread: main,
            isLibraryEmpty: {
                XCTAssertTrue(self.main.isRunning)
                self.emptinessChecks += 1
                if let failure = self.emptinessFailure { throw failure }
                return try self.location.graph.library.entries().isEmpty
            }, hasConfiguredSyncServer: {
                XCTAssertTrue(self.main.isRunning)
                return self.serverConfigured
            }, seedIfEmpty: {
                XCTAssertTrue(self.main.isRunning)
                self.copies += 1
                if let failure = self.copyFailure { throw failure }
                return try self.location.graph.seeds.seedIfEmpty()
            })
    }

    func completeInitialSteps() {
        settings.markSetupPresented()
        settings.completeLibraryFolderStep()
    }

    func restart() -> OnboardingHarness {
        OnboardingHarness(settingsFiles: settingsFiles, libraryFiles: location.graph.files)
    }
}

final class OnboardingLibraryGraph {
    let files: MemoryFileStore
    let library: LibraryService
    let seeds: SeedService

    init(files: MemoryFileStore = MemoryFileStore()) {
        self.files = files
        library = LibraryService(library: files, data: MemoryFileStore(), clock: LibraryClock(),
            entropy: OnboardingEntropy())
        seeds = SeedService(library: library)
    }
}

final class OnboardingLibraryLocation: LibraryLocationControl {
    var activeLibraryPath: String
    let defaultLibraryPath = "/default"
    var outcome = LibrarySwitchOutcome.switched
    var graph: OnboardingLibraryGraph
    private let settings: SettingsModel
    private let settingsFiles: MemoryFileStore
    private let status: LibraryStatusModel
    private let main: FakeMainThread
    private var graphs: [Data: OnboardingLibraryGraph]
    private(set) var switches: [String?] = []

    init(settings: SettingsModel, settingsFiles: MemoryFileStore, status: LibraryStatusModel,
         main: FakeMainThread, graph: OnboardingLibraryGraph) {
        self.settings = settings
        self.settingsFiles = settingsFiles
        self.status = status
        self.main = main
        self.graph = graph
        activeLibraryPath = settings.libraryFolderPath ?? defaultLibraryPath
        graphs = [Data(activeLibraryPath.utf8): graph]
    }

    func install(_ graph: OnboardingLibraryGraph, at path: String) {
        graphs[Data(path.utf8)] = graph
    }

    func switchLibrary(to path: String?) -> LibrarySwitchOutcome {
        XCTAssertTrue(main.isRunning)
        switches.append(path)
        switch outcome {
        case .invalidTarget, .deliveryInFlight, .repeatInvalidationFailed: return outcome
        case .switched, .settingsNotSaved, .libraryUnavailable:
            activeLibraryPath = path ?? defaultLibraryPath
            graph = graphs[Data(activeLibraryPath.utf8)] ?? OnboardingLibraryGraph()
            graphs[Data(activeLibraryPath.utf8)] = graph
        }
        if case .libraryUnavailable = outcome {
            status.update(.unavailableAtStartup)
            return outcome
        }
        status.update(.available)
        if case .settingsNotSaved = outcome { settingsFiles.failNextWrite = true }
        if let path { settings.setLibraryFolder(path) }
        else { settings.clearLibraryFolder() }
        return settings.error.map(LibrarySwitchOutcome.settingsNotSaved) ?? outcome
    }

    func revealLibrary() { XCTFail("Onboarding does not reveal folders") }
}

private final class OnboardingEntropy: EntropySource {
    private var requests = 0

    func bytes(count: Int) throws -> [UInt8] {
        requests += 1
        return Array(repeating: UInt8(truncatingIfNeeded: requests), count: count)
    }
}
