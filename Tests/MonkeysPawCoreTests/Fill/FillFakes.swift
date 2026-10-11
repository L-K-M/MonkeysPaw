import Foundation
import XCTest
@testable import MonkeysPawCore

final class PromptFlowHarness {
    let library = MemoryFileStore()
    let data = MemoryFileStore()
    let clock = LibraryClock()
    let delivery: DeliveryHarness
    let usage: UsageStore
    let values: ValuesStore
    let service: LibraryService
    let index: PromptIndex
    let fill: FillService
    let picker: PickerModel

    init(mainMode: FakeCompletionMode = .immediate,
         session: DesktopSession = .macOS, zone: TimeZone = TimeZone(secondsFromGMT: 0)!) {
        clock.date = Date(timeIntervalSince1970: 0)
        delivery = DeliveryHarness(session: session)
        usage = UsageStore(files: data, clock: clock)
        values = ValuesStore(files: data)
        service = LibraryService(library: library, data: data, clock: clock,
                                 entropy: LibraryEntropy(), keyedStores: [usage, values])
        index = PromptIndex(service: service, usage: usage, clock: clock)
        fill = FillService(values: values, clipboard: delivery.clipboard, clock: clock, timeZone: { zone })
        picker = PickerModel(index: index, fill: fill, delivery: delivery.service,
                             main: delivery.main)
        delivery.main.mode = mainMode
    }

    @discardableResult
    func put(_ source: String, at path: String = "a.md") throws -> LibraryEntry {
        try library.put(source, at: path)
        return try service.load(at: path)
    }

    func open() throws {
        try index.rebuild()
        delivery.main.drain()
        picker.open()
        delivery.main.drain()
    }

    func openForm(mode: DeliveryMode = .paste(.standard)) throws -> FillModel {
        picker.use(mode: mode)
        return try XCTUnwrap(picker.fillModel)
    }

    func settle() {
        delivery.main.drain()
        delivery.settle()
        delivery.main.drain()
    }
}

final class BuiltinSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [PromptBuiltinValues] = []

    var received: [PromptBuiltinValues] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }

    func append(_ value: PromptBuiltinValues) {
        lock.lock()
        defer { lock.unlock() }
        snapshots.append(value)
    }
}
