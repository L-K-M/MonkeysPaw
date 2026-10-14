import Foundation
import XCTest
@testable import MonkeysPawCore

final class RepeatAccess {
    var allowed = true
    var ownWindow = false
    var chord = PasteChord.standard
}

final class RepeatHarness {
    let flow: PromptFlowHarness
    let marker = EditingThreadMarker()
    let access = RepeatAccess()
    let held: HeldBackgroundWork
    let store: LastDeliveryStore
    let binding: RepeatBinding
    let service: RepeatService
    let picker: PickerModel
    let model: RepeatModel

    init(heldWork: Bool = false, session: DesktopSession = .macOS,
         linuxDefaultPasteChord: @escaping () -> PasteChord = { .standard }) throws {
        flow = PromptFlowHarness(session: session, linuxDefaultPasteChord: linuxDefaultPasteChord)
        held = HeldBackgroundWork(marker)
        store = LastDeliveryStore(files: flow.data)
        binding = try RepeatBinding(root: "/library")
        let access = self.access
        service = RepeatService(binding: binding, store: store, library: flow.service,
            index: flow.index, fill: flow.fill, delivery: flow.delivery.service,
            work: heldWork ? held : InlineBackgroundWork(marker), main: flow.delivery.main,
            canAccess: { _ in access.allowed }, isOwnWindowActive: { access.ownWindow },
            pasteChord: { _ in access.chord })
        picker = PickerModel(index: flow.index, fill: flow.fill, delivery: flow.delivery.service,
            main: flow.delivery.main, repeatService: service)
        model = RepeatModel(service: service, main: flow.delivery.main)
    }

    @discardableResult
    func put(_ source: String, at path: String = "a.md") throws -> LibraryEntry { try flow.put(source, at: path) }

    func open() throws {
        try flow.index.rebuild()
        flow.delivery.main.drain()
        picker.open()
        flow.delivery.main.drain()
    }

    func deliver(mode: DeliveryMode = .paste(.standard), values: [String: String] = [:]) throws {
        try open()
        picker.use(mode: mode)
        if let form = picker.fillModel {
            for (name, value) in values { form.setValue(value, name: name) }
            form.deliver(mode: mode)
        }
        flow.settle()
        held.releaseAll()
        flow.delivery.main.drain()
    }

    func restart(binding: RepeatBinding? = nil) -> RepeatService {
        let access = self.access
        return RepeatService(binding: binding ?? self.binding, store: LastDeliveryStore(files: flow.data),
            library: flow.service, index: flow.index, fill: flow.fill, delivery: flow.delivery.service,
            work: InlineBackgroundWork(marker), main: flow.delivery.main,
            canAccess: { _ in access.allowed }, isOwnWindowActive: { access.ownWindow },
            pasteChord: { _ in access.chord })
    }

    func repeatNow(using service: RepeatService? = nil) -> [RepeatResult] {
        var results: [RepeatResult] = []
        (service ?? self.service).repeatLast { results.append($0) }
        held.releaseAll()
        flow.delivery.main.drain()
        flow.settle()
        held.releaseAll()
        flow.delivery.main.drain()
        return results
    }
}
