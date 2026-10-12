import XCTest
@testable import MonkeysPawCore

final class ImportModelTests: XCTestCase {
    func testFileIntentPublishesProgressAndPartialReportAndCanRunAgain() throws {
        let graph = ImportTestGraph()
        graph.sources.put("body", at: "/source/A.md")
        let model = ImportModel(service: graph.service)
        var states: [ImportModel.State] = []
        model.onChange = { states.append($0) }
        model.importFiles(at: ["/source/A.md", "/source/Missing.md"])
        XCTAssertTrue(model.state.isImporting)
        XCTAssertEqual(model.state.progress, .enumerating)
        XCTAssertNil(model.state.report)
        model.importFolder(at: "/ignored")
        XCTAssertEqual(graph.work.jobs.count, 1)
        graph.work.drain()
        XCTAssertNil(model.state.report)
        graph.main.drain()
        XCTAssertFalse(model.state.isImporting)
        XCTAssertNil(model.state.progress)
        XCTAssertEqual(model.state.report?.createdCount, 1)
        XCTAssertEqual(model.state.report?.skippedCount, 1)
        XCTAssertTrue(states.contains { $0.progress == .importing(completed: 1, total: 2) })
        model.importFiles(at: ["/source/A.md"])
        XCTAssertNil(model.state.report)
        graph.work.drain()
        graph.main.drain()
        XCTAssertEqual(model.state.report?.files[0].outcome, .created(path: "Imported/A 2.md"))
    }

    func testFolderIntentUsesChosenDestinationAndRetirementRejectsQueuedWork() throws {
        let graph = ImportTestGraph()
        graph.sources.entries = [ImportSourceEntry(relativePath: "Nested/A.md")]
        graph.sources.put("body", at: "/source/Nested/A.md")
        let model = ImportModel(service: graph.service)
        model.importFolder(at: "/source", into: "Chosen")
        graph.work.drain()
        graph.main.drain()
        XCTAssertEqual(model.state.report?.files[0].outcome, .created(path: "Chosen/Nested/A.md"))
        model.importFiles(at: ["/source/Nested/A.md"])
        model.deactivate()
        graph.work.drain()
        graph.main.drain()
        XCTAssertNil(try graph.files.stamp(at: "Imported/A.md"))
        XCTAssertNil(model.onChange)
    }

    func testSynchronousCallbacksAndReentrantIntentsRemainCoherent() throws {
        let graph = ImportTestGraph()
        let service = ImportService(library: graph.library, sources: graph.sources, work: graph.work, main: ImportInlineMain())
        let model = ImportModel(service: service)
        var callbacks = 0
        model.onChange = { state in
            callbacks += 1
            if state.isImporting { model.importFiles(at: ["/reentrant.md"]) }
        }
        model.importFiles(at: [])
        XCTAssertEqual(graph.work.jobs.count, 1)
        graph.work.drain()
        XCTAssertFalse(model.state.isImporting)
        XCTAssertEqual(model.state.report?.files.count, 0)
        XCTAssertGreaterThan(callbacks, 1)
    }
}
