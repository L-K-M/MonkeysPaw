import Foundation
import XCTest
@testable import MonkeysPawCore

final class AssistantAcceptanceHarness {
    let e: EditorHarness
    let provider = ProviderHarness()
    let transport = ConnectionTransport([.held])
    let service: AssistantService
    var libraryID = UUID()
    var access = AssistantAccessState.privatePrompt
    lazy var model = AssistantModel(service: service, main: e.h.main, context: { [unowned self] in self.context })
    var context: AssistantContext {
        AssistantContext(libraryID: libraryID, profile: service.selectedProfile, editor: e.model.assistantSnapshot, access: access)
    }

    init(source: String? = nil, path: String = "a.md", held: Bool = true, queued: Bool = true,
         key: String = "test-key") throws {
        e = EditorHarness(heldWork: held, queuedMain: queued)
        service = AssistantService(providerSettings: provider.service, anthropic: AnthropicClient(transport: transport),
            openAICompatible: OpenAIClient(transport: transport, providerState: ProviderStateStore(files: provider.files)),
            work: held ? e.h.held : InlineBackgroundWork(e.h.marker), main: e.h.main,
            clock: e.h.clock, entropy: AssistantCountingEntropy())
        try provider.service.save(ProviderDraft(kind: .openaiCompatible, modelID: "manual-model", key: .replace(SecretValue(key))))
        if let source { try e.open(source, at: path) }
        e.model.onChange = { [weak self] in self?.model.contextChanged() }
    }

    func ready(improve: Bool = false, body: String = "  文書 e\u{301} {{topic}}\r\n\n",
               brief: String = "Brief", notes: String = "Notes") async throws {
        e.ui {
            if improve { model.editInstruction(brief); model.improve() }
            else { model.write(brief: brief) }
        }
        for _ in 0..<600 {
            e.settle()
            if await transport.snapshot().count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1, "Assistant must issue exactly one request before its response is released.")
        guard requests.count == 1 else { throw EditingTestError.unexpectedOutcome }
        let artifact = ["title": "Candidate", "description": "", "tags": [], "fields": [], "body": body, "notes": notes] as [String: Any]
        let text = try AssistantOutputFixtures.json(artifact)
        await transport.release(HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": "stop", "message": ["content": text]]],
            "usage": ["prompt_tokens": 11, "completion_tokens": 7]
        ])))
        for _ in 0..<600 {
            e.settle()
            if model.state.phase == .ready { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Assistant did not produce a ready preview.")
    }

    func accept() throws -> AssistantAcceptanceOutcome {
        var result: AssistantAcceptanceOutcome?
        e.ui { model.accept(using: e.model) { XCTAssertTrue(self.e.h.marker.isUI); result = $0 } }
        e.settle()
        return try XCTUnwrap(result)
    }
}

final class AssistantAcceptanceModelTests: XCTestCase {
    func testRetryAndShowDiffAfterCommittedWriteUseFreshIdentityWithoutChangingFirstFile() async throws {
        for queued in [false, true] {
            for provenanceWarning in [false, true] {
                for retry in [true, false] {
                    let h = try AssistantActionHarness([.held, .held], queued: queued)
                    h.ui { h.model.write(brief: "First") }
                    try await h.sent()
                    try await h.artifact(body: "First body")
                    try await h.phase(.ready)
                    let firstCandidate = try XCTUnwrap(h.model.state.candidate)
                    if provenanceWarning {
                        h.editor.h.dataFiles.beforeWrite = { path in
                            if path.hasSuffix("/head.json") { throw FileStoreError.ioFailure }
                        }
                    }
                    var firstOutcome: AssistantAcceptanceOutcome?
                    h.ui { h.model.accept(using: h.editor.model) { firstOutcome = $0 } }
                    try await h.phase(.saved)
                    let first = try XCTUnwrap(firstOutcome?.committed?.entry)
                    if provenanceWarning {
                        guard case .committedWithProvenanceWarning = firstOutcome else {
                            XCTFail("Expected a committed provenance warning.")
                            continue
                        }
                    }
                    h.editor.h.dataFiles.beforeWrite = nil
                    let transcript = h.model.state.transcript
                    if retry {
                        h.ui { h.model.retryWithFeedback("Use a second body") }
                        try await h.sent(2)
                        XCTAssertEqual(Array(h.model.state.transcript.dropLast()), transcript)
                        try await h.artifact(body: "Second body")
                    } else { h.ui { h.model.showDiff() } }
                    try await h.phase(.ready)
                    let secondCandidate = try XCTUnwrap(h.model.state.candidate)
                    XCTAssertNotEqual(secondCandidate.content.document.frontMatter.id, first.document.frontMatter.id)
                    XCTAssertTrue(h.model.canAccept)
                    var secondOutcome: AssistantAcceptanceOutcome?
                    h.ui { h.model.accept(using: h.editor.model) { secondOutcome = $0 } }
                    try await h.phase(.saved)
                    let second = try XCTUnwrap(secondOutcome?.committed?.entry)
                    XCTAssertNotEqual(second.relativePath, first.relativePath)
                    XCTAssertNotEqual(second.identity, first.identity)
                    XCTAssertEqual(try h.editor.h.files.read(at: first.relativePath), firstCandidate.content.canonicalBytes)
                    XCTAssertEqual(try h.editor.h.files.read(at: second.relativePath), secondCandidate.content.canonicalBytes)
                }
            }
        }
    }

    func testWriteOpensExactPreviewWithPreflightedIdentityAndModelOutcomeInEveryQueueMode() async throws {
        for held in [false, true] {
            for queued in [false, true] {
                let h = try AssistantAcceptanceHarness(held: held, queued: queued)
                let marker = h.e.h.marker
                h.model.onChange = { XCTAssertTrue(marker.isUI) }
                try await h.ready()
                let candidate = try XCTUnwrap(h.model.state.candidate)
                let result = try h.accept()
                let commit = try XCTUnwrap(result.committed)
                XCTAssertEqual(try h.e.h.files.read(at: commit.entry.relativePath), candidate.content.canonicalBytes)
                XCTAssertEqual(commit.entry.document.frontMatter.id, candidate.content.document.frontMatter.id)
                XCTAssertEqual(h.e.model.state.source.map { Data($0.utf8) }, candidate.content.canonicalBytes)
                XCTAssertEqual(h.e.model.state.prompt?.relativePath.string, commit.entry.relativePath)
                XCTAssertFalse(h.e.model.state.isDirty)
                XCTAssertEqual(h.e.model.state.stamp, commit.entry.stamp)
                XCTAssertEqual(h.model.state.phase, .saved)
                guard case .saved = h.model.state.acceptanceOutcome else {
                    XCTFail("Missing saved model outcome.")
                    continue
                }
                XCTAssertEqual(try h.e.h.library.provenance(at: commit.entry.relativePath)?.usage,
                               AssistantTokenUsage(inputTokens: 11, outputTokens: 7))
            }
        }
    }

    func testImproveUsesUnsavedValidatedSnapshotAndKeepsAssignedOrPreflightedIdentity() async throws {
        for assigned in [false, true] {
            let prefix = assigned ? "id: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\n" : ""
            let original = "---\n" + prefix + "favorite: true\ncustom: {nested: [value, false]}\n---\nOriginal\r\n"
            let h = try AssistantAcceptanceHarness(source: original)
            h.e.ui { h.e.model.edit(original + "Unsaved") }
            try await h.ready(improve: true)
            let candidate = try XCTUnwrap(h.model.state.candidate)
            let result = try h.accept()
            let entry = try XCTUnwrap(result.committed?.entry)
            XCTAssertEqual(entry.document.frontMatter.id, candidate.content.document.frontMatter.id)
            XCTAssertTrue(entry.document.frontMatter.favorite)
            XCTAssertEqual(try h.e.h.files.read(at: "a.md"), candidate.content.canonicalBytes)
            XCTAssertFalse(h.e.model.state.isDirty)
            XCTAssertNil(h.e.model.state.pendingDecision)
            XCTAssertNil(h.e.model.state.conflict)
            XCTAssertEqual(h.model.state.phase, .saved)
            let history = try h.e.h.library.historyForEditing(entry.identity, filename: "a.md")
            XCTAssertEqual(history.map(\.source), [original])
        }
    }

    func testImproveKeepsLoadedIdentityWhenUnsavedBufferOmitsID() async throws {
        let id = ULID("01K6Z4V9KQWZX7MPQ4T8ZNB2PD")!
        let original = "---\nid: \(id.rawValue)\n---\nOriginal"
        let h = try AssistantAcceptanceHarness(source: original)
        h.e.ui { h.e.model.edit("Unsaved without front matter") }
        try await h.ready(improve: true)
        let candidate = try XCTUnwrap(h.model.state.candidate)
        XCTAssertEqual(candidate.content.document.frontMatter.id, id)
        let entry = try XCTUnwrap(h.accept().committed?.entry)
        XCTAssertEqual(entry.identity, .assigned(id))
        XCTAssertEqual(try h.e.h.files.read(at: "a.md"), candidate.content.canonicalBytes)
        XCTAssertEqual(try h.e.h.library.historyForEditing(entry.identity, filename: "a.md").map(\.source), [original])
    }

    func testChangedOrDeletedDiskUsesExistingEditorConflictDialog() async throws {
        for deleted in [false, true] {
            let h = try AssistantAcceptanceHarness(source: "Original")
            try await h.ready(improve: true)
            var result: AssistantAcceptanceOutcome?
            h.e.ui { h.model.accept(using: h.e.model) { result = $0 } }
            h.e.h.main.releaseAll()
            if deleted { try h.e.h.files.delete(at: "a.md") }
            else { try h.e.h.files.put("Newer disk", at: "a.md") }
            h.e.settle()
            if deleted {
                guard case .conflict(.deleted) = result else {
                    XCTFail("Expected deleted outcome.")
                    continue
                }
                XCTAssertEqual(h.e.model.state.conflict?.kind, .deleted)
            } else {
                guard case .conflict(.modified(let stamp)) = result else {
                    XCTFail("Expected stale-file outcome.")
                    continue
                }
                XCTAssertEqual(stamp, try h.e.h.files.stamp(at: "a.md"))
                XCTAssertEqual(h.e.model.state.conflict?.theirsSource, "Newer disk")
            }
            XCTAssertEqual(h.e.model.state.source, "Original")
            XCTAssertTrue(try h.e.h.data.listFiles().isEmpty)
            guard case .conflict = h.model.state.acceptanceOutcome else {
                XCTFail("Missing conflict model outcome.")
                continue
            }
            XCTAssertFalse(h.model.canAccept)
        }
    }

    func testReplacementOfCreatedPromptKeepsOriginalEditorAndReportsCreationFailure() async throws {
        for (hasSource, viewerCopy) in [(false, false), (true, false), (true, true)] {
            let original = "---\nid: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\n---\nOriginal"
            let h = try AssistantAcceptanceHarness(source: hasSource ? original : nil)
            if viewerCopy { h.access = .group(.viewer); h.e.ui { h.model.contextChanged() } }
            try await h.ready(improve: viewerCopy)
            let selection = h.e.model.state.prompt
            let stamp = h.e.model.state.stamp
            h.e.h.files.onWrite = { path in
                guard path == "Candidate.md" else { return }
                h.e.h.files.onWrite = nil
                do { try h.e.h.files.put("External copy", at: path) }
                catch { XCTFail("Could not replace the new test prompt.") }
            }
            guard case .failed(.editing(.library(.conflict))) = try h.accept() else {
                XCTFail("A destination replacement cannot open the original's conflict dialog.")
                continue
            }
            XCTAssertEqual(h.e.model.state.prompt, selection)
            XCTAssertEqual(h.e.model.state.stamp, stamp)
            XCTAssertEqual(h.e.model.state.source, hasSource ? original : nil)
            XCTAssertNil(h.e.model.state.conflict)
            XCTAssertEqual(try h.e.h.files.text(at: "Candidate.md"), "External copy")
            if hasSource { XCTAssertEqual(try h.e.h.files.text(at: "a.md"), original) }
            XCTAssertTrue(try h.e.h.data.listFiles().isEmpty)
            XCTAssertEqual(h.model.state.phase, .failed)
        }
    }

    func testBufferEditsAwayAndBackRefuseQueuedAcceptanceWithoutOverwriting() async throws {
        let h = try AssistantAcceptanceHarness(source: "Original")
        try await h.ready(improve: true)
        var result: AssistantAcceptanceOutcome?
        h.e.ui { h.model.accept(using: h.e.model) { result = $0 } }
        h.e.h.main.releaseAll()
        h.e.ui { h.e.model.edit("Newer buffer"); h.e.model.edit("Original") }
        h.e.settle()
        guard case .conflict(.changedBuffer) = result else { return XCTFail("Expected changed-buffer outcome.") }
        XCTAssertEqual(h.e.model.state.source, "Original")
        XCTAssertEqual(try h.e.h.files.text(at: "a.md"), "Original")
        XCTAssertTrue(try h.e.h.data.listFiles().isEmpty)
        XCTAssertFalse(h.model.canAccept)
    }

    func testCancelledClosedRejectedAndChangedContextsCannotPublishQueuedWrites() async throws {
        enum Change: CaseIterable { case cancel, close, reject, library, profile, access, retireEditor, retireService }
        for change in Change.allCases {
            let h = try AssistantAcceptanceHarness(source: "Original")
            try await h.ready(improve: true)
            var result: AssistantAcceptanceOutcome?
            var replies = 0
            h.e.ui { h.model.accept(using: h.e.model) { result = $0; replies += 1; XCTAssertTrue(h.e.h.marker.isUI) } }
            h.e.h.main.releaseAll()
            h.e.ui {
                switch change {
                case .cancel: h.model.cancel()
                case .close: h.model.close()
                case .reject: h.model.reject()
                case .library:
                    let old = h.libraryID
                    h.libraryID = UUID(); h.model.contextChanged()
                    h.libraryID = old; h.model.contextChanged()
                case .profile: h.model.profileChanged()
                case .access:
                    h.access = .group(.viewer); h.model.contextChanged()
                    h.access = .privatePrompt; h.model.contextChanged()
                case .retireEditor: h.e.model.deactivate()
                case .retireService: h.e.h.editor.deactivate()
                }
            }
            h.e.settle()
            guard case .failed(let failure) = result else {
                XCTFail("Expected a retired acceptance outcome.")
                continue
            }
            switch change {
            case .cancel, .close, .reject: XCTAssertEqual(failure, .cancelled)
            case .library, .profile, .access: XCTAssertEqual(failure, .staleContext)
            case .retireEditor, .retireService: XCTAssertEqual(failure, .inactive)
            }
            XCTAssertEqual(replies, 1)
            XCTAssertEqual(try h.e.h.files.text(at: "a.md"), "Original")
            XCTAssertTrue(try h.e.h.data.listFiles().isEmpty)
        }
    }

    func testNewerBufferAndRetiredAssistantTokenAfterPublicationKeepActualCommit() async throws {
        let h = try AssistantAcceptanceHarness(source: "Original")
        try await h.ready(improve: true)
        let bytes = try XCTUnwrap(h.model.state.candidate).content.canonicalBytes
        var result: AssistantAcceptanceOutcome?
        h.e.ui { h.model.accept(using: h.e.model) { result = $0 } }
        h.e.h.main.releaseAll()
        h.e.h.held.releaseNext()
        XCTAssertNil(result)
        XCTAssertEqual(try h.e.h.files.read(at: "a.md"), bytes)
        h.e.ui { h.model.close(); h.e.model.edit("Newer buffer") }
        h.e.settle()
        let entry = try XCTUnwrap(result?.committed?.entry)
        XCTAssertEqual(h.e.model.state.source, "Newer buffer")
        XCTAssertTrue(h.e.model.state.isDirty)
        XCTAssertEqual(h.e.model.state.stamp, entry.stamp)
        XCTAssertEqual(try h.e.h.files.read(at: "a.md"), bytes)
        XCTAssertEqual(h.model.state.phase, .idle)
        XCTAssertNil(h.model.state.acceptanceOutcome)
    }

    func testProvenanceAndHistoryWarningsAdoptCommitAndStayVisibleInBothModels() async throws {
        for (historyFailure, provenanceFailure) in [(false, true), (true, false), (true, true)] {
            let h = try AssistantAcceptanceHarness(source: "Original")
            try await h.ready(improve: true)
            if historyFailure {
                let identity = try XCTUnwrap(h.e.model.state.prompt).identity
                let store = HistoryStore(files: h.e.h.data)
                for _ in 0..<Limits.historyCapPerPrompt {
                    _ = try store.snapshot(Data("Earlier".utf8), for: identity, at: h.e.h.clock.date)
                }
                h.e.h.dataFiles.onDelete = { path in if path.hasSuffix(".md") { throw FileStoreError.ioFailure } }
            }
            if provenanceFailure {
                h.e.h.dataFiles.beforeWrite = { path in if path.hasSuffix("/head.json") { throw FileStoreError.ioFailure } }
            }
            let result = try h.accept()
            let commit = try XCTUnwrap(result.committed)
            XCTAssertEqual(commit.historyMaintenanceFailed, historyFailure)
            XCTAssertEqual(h.e.model.state.historyMaintenanceFailed, historyFailure)
            XCTAssertEqual(h.e.model.state.provenanceMaintenanceFailed, provenanceFailure)
            XCTAssertFalse(h.e.model.state.isDirty)
            XCTAssertEqual(h.e.model.state.stamp, commit.entry.stamp)
            XCTAssertEqual(h.e.h.index.cachedEntry(at: commit.entry.relativePath)?.stamp, commit.entry.stamp)
            XCTAssertEqual(h.model.state.phase, .saved)
            if provenanceFailure {
                guard case .committedWithProvenanceWarning = h.model.state.acceptanceOutcome else {
                    XCTFail("Missing committed warning in AssistantModel.")
                    continue
                }
            } else {
                guard case .saved = h.model.state.acceptanceOutcome else {
                    XCTFail("Missing saved history warning.")
                    continue
                }
            }
        }
    }

    func testFileAndHistoryStagingFailuresKeepOriginalDraftAndTypedOutcome() async throws {
        for historyFailure in [false, true] {
            let h = try AssistantAcceptanceHarness(source: "Original")
            try await h.ready(improve: true)
            if historyFailure {
                h.e.h.dataFiles.beforeWrite = { path in if path.hasSuffix(".md") { throw FileStoreError.ioFailure } }
            } else { h.e.h.files.failNextWrite = true }
            guard case .failed(.editing(.fileStore(.ioFailure))) = try h.accept() else {
                XCTFail("Expected typed save failure.")
                continue
            }
            XCTAssertEqual(h.e.model.state.source, "Original")
            XCTAssertEqual(try h.e.h.files.text(at: "a.md"), "Original")
            XCTAssertTrue(try h.e.h.data.listFiles().isEmpty)
            XCTAssertEqual(h.model.state.phase, .failed)
            guard case .failed = h.model.state.acceptanceOutcome else {
                XCTFail("Missing failed outcome.")
                continue
            }
        }
    }

    func testGroupViewerOffersPrivateCopyWhileEditorAndOwnerWriteInGroup() async throws {
        for role in [AssistantGroupRole.viewer, .editor, .owner] {
            for improve in [false, true] {
                let original = "---\nid: 01K6Z4V9KQWZX7MPQ4T8ZNB2PD\n---\nOriginal"
                let h = try AssistantAcceptanceHarness(source: original, path: "Groups/Team/a.md")
                h.access = .group(role)
                h.e.ui { h.model.contextChanged() }
                try await h.ready(improve: improve)
                let candidate = try XCTUnwrap(h.model.state.candidate)
                let entry = try XCTUnwrap(h.accept().committed?.entry)
                XCTAssertEqual(try h.e.h.files.read(at: entry.relativePath), candidate.content.canonicalBytes)
                if role == .viewer {
                    XCTAssertEqual(entry.folder, "")
                    XCTAssertNotEqual(entry.document.frontMatter.id, ULID("01K6Z4V9KQWZX7MPQ4T8ZNB2PD"))
                    XCTAssertEqual(try h.e.h.files.text(at: "Groups/Team/a.md"), original)
                } else {
                    XCTAssertEqual(entry.folder, "Groups/Team")
                    if improve { XCTAssertEqual(entry.document.frontMatter.id, ULID("01K6Z4V9KQWZX7MPQ4T8ZNB2PD")) }
                }
                XCTAssertEqual(h.e.model.state.prompt?.relativePath.string, entry.relativePath)
            }
        }
    }

    func testWriteProtectsUnsavedOriginalWithExistingSaveDiscardCancelGuard() async throws {
        for queued in [false, true] {
            for decision in [EditorDecision.save, .discard, .cancel] {
                let h = try AssistantAcceptanceHarness(source: "Original", queued: queued)
                h.e.ui { h.e.model.edit("Unsaved") }
                try await h.ready()
                let candidate = try XCTUnwrap(h.model.state.candidate)
                var result: AssistantAcceptanceOutcome?
                var replies = 0
                h.e.ui { h.model.accept(using: h.e.model) { result = $0; replies += 1; XCTAssertTrue(h.e.h.marker.isUI) } }
                h.e.h.main.releaseAll()
                XCTAssertNotNil(h.e.model.state.pendingDecision)
                XCTAssertTrue(h.model.state.isAccepting)
                XCTAssertEqual(h.model.state.phase, .ready)
                XCTAssertEqual(h.model.state.candidate?.content.canonicalBytes, candidate.content.canonicalBytes)
                let guarded = try XCTUnwrap(h.e.model.assistantSnapshot)
                XCTAssertEqual(guarded.availability, .busy)
                XCTAssertEqual(guarded.sourceBytes, candidate.context.editor?.sourceBytes)
                XCTAssertEqual(guarded.revision, candidate.context.editor?.revision)
                XCTAssertEqual(guarded.stamp, candidate.context.editor?.stamp)
                XCTAssertNil(result)
                XCTAssertNil(try h.e.h.files.stamp(at: "Candidate.md"))
                try h.e.decide(decision)
                h.e.settle()
                if decision == .cancel {
                    guard case .failed(.cancelled) = result else {
                        XCTFail("Expected cancelled guard.")
                        continue
                    }
                    XCTAssertEqual(h.e.model.state.source, "Unsaved")
                    XCTAssertTrue(try h.e.h.data.listFiles().isEmpty)
                } else {
                    guard case .conflict(.changedBuffer) = result else {
                        XCTFail("Save/discard requires a fresh preview.")
                        continue
                    }
                }
                XCTAssertNil(try h.e.h.files.stamp(at: "Candidate.md"))
                let expected = decision == .save ? try XCTUnwrap(h.e.model.state.source) : "Original"
                XCTAssertEqual(try h.e.h.files.text(at: "a.md"), expected)
                XCTAssertEqual(replies, 1)
            }
        }
    }

    func testCancellationWhileWriteDecisionIsPendingCompletesAndReleasesItsGuard() async throws {
        for queued in [false, true] {
            for changedProfile in [false, true] {
                let h = try AssistantAcceptanceHarness(source: "Original", queued: queued)
                h.e.ui { h.e.model.edit("Unsaved") }
                try await h.ready()
                var result: AssistantAcceptanceOutcome?
                var replies = 0
                h.e.ui { h.model.accept(using: h.e.model) { result = $0; replies += 1; XCTAssertTrue(h.e.h.marker.isUI) } }
                h.e.h.main.releaseAll()
                XCTAssertNotNil(h.e.model.state.pendingDecision)
                h.e.ui {
                    if changedProfile { h.model.profileChanged() }
                    else { h.model.close() }
                }
                h.e.settle()
                XCTAssertEqual(replies, 1)
                guard case .failed(let failure) = result else {
                    XCTFail("Pending acceptance must complete on retirement.")
                    continue
                }
                XCTAssertEqual(failure, changedProfile ? .staleContext : .cancelled)
                XCTAssertNil(h.e.model.state.pendingDecision)
                XCTAssertEqual(h.e.model.state.source, "Unsaved")
                XCTAssertEqual(try h.e.h.files.text(at: "a.md"), "Original")
                XCTAssertNil(try h.e.h.files.stamp(at: "Candidate.md"))
                XCTAssertTrue(try h.e.h.data.listFiles().isEmpty)
                h.e.ui { h.e.model.revert() }
                h.e.h.main.releaseAll()
                XCTAssertEqual(h.e.model.state.pendingDecision?.action, .revert)
                try h.e.decide(.cancel)
                h.e.settle()
            }
        }
    }

    func testInlineObserverCanCancelAPublishedAssistantDecision() async throws {
        for queued in [false, true] {
            let h = try AssistantAcceptanceHarness(source: "Original", queued: queued)
            h.e.ui { h.e.model.edit("Unsaved") }
            try await h.ready()
            var cancelled = false
            h.e.model.onChange = { [weak h] in
                guard let h else { return }
                h.model.contextChanged()
                if !cancelled, h.e.model.state.pendingDecision != nil {
                    cancelled = true
                    h.model.close()
                }
            }
            var result: AssistantAcceptanceOutcome?
            var replies = 0
            h.e.ui { h.model.accept(using: h.e.model) { result = $0; replies += 1; XCTAssertTrue(h.e.h.marker.isUI) } }
            h.e.settle()
            guard case .failed(.cancelled) = result else {
                XCTFail("An inline close must cancel the guard.")
                continue
            }
            XCTAssertEqual(replies, 1)
            XCTAssertNil(h.e.model.state.pendingDecision)
            XCTAssertEqual(h.e.model.state.source, "Unsaved")
            XCTAssertTrue(try h.e.h.data.listFiles().isEmpty)
            XCTAssertNil(try h.e.h.files.stamp(at: "Candidate.md"))
        }
    }

    func testCancellingQueuedAcceptancePreservesAnEarlierEditorDecision() async throws {
        for queued in [false, true] {
            let h = try AssistantAcceptanceHarness(source: "Original", queued: queued)
            h.e.ui { h.e.model.edit("Unsaved") }
            try await h.ready()
            h.e.ui { h.e.model.revert() }
            h.e.h.main.releaseAll()
            let earlier = try XCTUnwrap(h.e.model.state.pendingDecision)
            var result: AssistantAcceptanceOutcome?
            var replies = 0
            h.e.ui { h.model.accept(using: h.e.model) { result = $0; replies += 1; XCTAssertTrue(h.e.h.marker.isUI) } }
            h.e.h.main.releaseAll()
            XCTAssertNil(result, "Acceptance must wait behind the earlier decision.")
            XCTAssertTrue(h.model.state.isAccepting)
            XCTAssertEqual(h.e.model.state.pendingDecision, earlier)
            XCTAssertEqual(h.e.model.state.queuedActions.count, 1)
            h.e.ui { h.model.close() }
            h.e.settle()
            switch result {
            case .failed(.cancelled): break
            default: XCTFail("Close must cancel the queued acceptance.")
            }
            XCTAssertEqual(replies, 1)
            XCTAssertEqual(h.e.model.state.pendingDecision, earlier)
            XCTAssertTrue(h.e.model.state.queuedActions.isEmpty)
            XCTAssertEqual(h.e.model.state.source, "Unsaved")
            XCTAssertTrue(try h.e.h.data.listFiles().isEmpty)
            try h.e.decide(.cancel)
            h.e.settle()
            XCTAssertEqual(replies, 1)
        }
    }

    func testQueuedPendingAndResolvingGuardPreserveTheAcceptancePreview() async throws {
        let h = try AssistantAcceptanceHarness(source: "Original")
        h.e.ui { h.e.model.edit("Unsaved") }
        try await h.ready()
        let candidate = try XCTUnwrap(h.model.state.candidate)
        h.e.ui { h.e.model.request(.quit) }
        XCTAssertNil(h.e.model.state.pendingDecision)
        XCTAssertEqual(h.e.model.assistantSnapshot?.availability, .busy)
        XCTAssertTrue(h.model.canAccept)
        h.e.h.main.releaseAll()
        XCTAssertNotNil(h.e.model.state.pendingDecision)
        XCTAssertTrue(h.model.canAccept)
        try h.e.decide(.cancel)
        XCTAssertNil(h.e.model.state.pendingDecision)
        XCTAssertEqual(h.e.model.assistantSnapshot?.availability, .busy)
        XCTAssertTrue(h.model.canAccept)
        h.e.settle()
        XCTAssertEqual(h.e.model.assistantSnapshot?.availability, .available)
        XCTAssertTrue(h.model.canAccept)
        XCTAssertEqual(h.model.state.candidate?.content.canonicalBytes, candidate.content.canonicalBytes)
        XCTAssertFalse(h.model.state.isStale)
        XCTAssertEqual(h.model.state.phase, .ready)
    }

    func testImproveQueuesBehindEarlierDecisionAndStartsBeforeLaterGuard() async throws {
        for queued in [false, true] {
            let h = try AssistantAcceptanceHarness(source: "Original", queued: queued)
            h.e.ui { h.e.model.edit("Unsaved") }
            try await h.ready(improve: true)
            let candidate = try XCTUnwrap(h.model.state.candidate)
            h.e.ui { h.e.model.revert() }
            h.e.h.main.releaseAll()
            let earlier = try XCTUnwrap(h.e.model.state.pendingDecision)
            var outcomes: [AssistantAcceptanceOutcome] = []
            h.e.ui { h.model.accept(using: h.e.model) { outcomes.append($0); XCTAssertTrue(h.e.h.marker.isUI) } }
            h.e.h.main.releaseAll()
            XCTAssertTrue(outcomes.isEmpty)
            XCTAssertEqual(h.e.model.state.pendingDecision, earlier)
            XCTAssertEqual(h.e.model.state.queuedActions, [.open(try XCTUnwrap(h.e.model.state.prompt))])
            var later: [EditorGuardResult] = []
            h.e.ui { h.e.model.request(.quit) { later.append($0); XCTAssertTrue(h.e.h.marker.isUI) } }
            try h.e.decide(.cancel)
            h.e.h.main.releaseAll()
            XCTAssertEqual(h.e.model.state.status, .saving)
            XCTAssertEqual(h.e.model.assistantSnapshot?.availability, .busy)
            XCTAssertEqual(h.e.model.state.queuedActions, [.quit])
            XCTAssertTrue(outcomes.isEmpty)
            XCTAssertTrue(later.isEmpty)
            h.e.settle()
            XCTAssertEqual(outcomes.count, 1)
            XCTAssertNotNil(outcomes.first?.committed)
            XCTAssertEqual(later, [.allowed])
            XCTAssertEqual(try h.e.h.files.read(at: "a.md"), candidate.content.canonicalBytes)
            XCTAssertEqual(h.model.state.phase, .saved)
            XCTAssertNil(h.e.model.state.pendingDecision)
            XCTAssertTrue(h.e.model.state.queuedActions.isEmpty)
            XCTAssertEqual(h.e.model.assistantSnapshot?.availability, .available)
        }
    }

    func testCleanWriteQueuesAfterEarlierRequestAndBeforeLaterGuard() async throws {
        let h = try AssistantAcceptanceHarness(source: "Original")
        try await h.ready()
        let candidate = try XCTUnwrap(h.model.state.candidate)
        var earlier: [EditorGuardResult] = []
        h.e.ui { h.e.model.request(.quit) { earlier.append($0) } }
        var outcomes: [AssistantAcceptanceOutcome] = []
        h.e.ui { h.model.accept(using: h.e.model) { outcomes.append($0); XCTAssertEqual(earlier, [.allowed]) } }
        h.e.ui { h.e.model.request(.revert) }
        XCTAssertEqual(h.e.model.state.queuedActions.count, 3)
        h.e.h.main.releaseAll()
        XCTAssertEqual(h.e.model.state.status, .saving)
        XCTAssertEqual(h.e.model.state.queuedActions, [.revert])
        XCTAssertTrue(outcomes.isEmpty)
        h.e.settle()
        XCTAssertEqual(outcomes.count, 1)
        let entry = try XCTUnwrap(outcomes.first?.committed?.entry)
        XCTAssertNotEqual(entry.relativePath, "a.md", "A clean Write creates a new prompt.")
        XCTAssertEqual(try h.e.h.files.read(at: entry.relativePath), candidate.content.canonicalBytes)
        XCTAssertEqual(try h.e.h.files.text(at: "a.md"), "Original")
        XCTAssertEqual(h.model.state.phase, .saved)
        XCTAssertTrue(h.e.model.state.queuedActions.isEmpty)
    }

    func testAcceptanceRefusesEditorIOEvenWhenThePreviewContentMatches() async throws {
        for operation in 0..<3 {
            let h = try AssistantAcceptanceHarness(source: "Original")
            try await h.ready(improve: true)
            var outcomes: [AssistantAcceptanceOutcome] = []
            let accept = { h.model.accept(using: h.e.model) { outcomes.append($0); XCTAssertTrue(h.e.h.marker.isUI) } }
            if operation == 2 { h.e.ui(accept) }
            h.e.ui {
                if operation == 0 { h.e.model.revert() }
                else { h.e.model.save() }
            }
            if operation != 2 {
                h.e.h.main.releaseAll()
                h.e.ui(accept)
            }
            h.e.h.main.releaseAll()
            XCTAssertEqual(outcomes.count, 1)
            switch outcomes.first {
            case .failed(.editorBusy): break
            default: XCTFail("Editor I/O must refuse acceptance.")
            }
            h.e.settle()
            XCTAssertEqual(outcomes.count, 1)
            XCTAssertNil(try h.e.h.files.stamp(at: "Candidate.md"))
            XCTAssertNil(try h.e.h.library.provenance(at: "a.md"))
            XCTAssertFalse(try h.e.h.files.text(at: "a.md").contains("文書"))
        }
    }

    func testCloseBeforeQueuedAcceptanceStartWinsOverLaterEditorSave() async throws {
        let h = try AssistantAcceptanceHarness(source: "Original")
        try await h.ready(improve: true)
        var outcomes: [AssistantAcceptanceOutcome] = []
        h.e.ui {
            h.model.accept(using: h.e.model) { outcomes.append($0); XCTAssertTrue(h.e.h.marker.isUI) }
            h.model.close()
            h.e.model.save()
        }
        h.e.h.main.releaseAll()
        XCTAssertEqual(outcomes.count, 1)
        switch outcomes.first {
        case .failed(.cancelled): break
        default: XCTFail("Close must retain its cancellation outcome.")
        }
        h.e.settle()
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNil(try h.e.h.library.provenance(at: "a.md"))
        XCTAssertFalse(try h.e.h.files.text(at: "a.md").contains("文書"))
    }

    func testSentinelScanFindsNoKeyBriefNotesInstructionOrTranscriptAfterAcceptAndReject() async throws {
        for (reject, improve) in [(false, false), (true, false), (false, true), (true, true)] {
            let sentinels = (0..<4).map { _ in "sentinel-" + UUID().uuidString }
            let h = try AssistantAcceptanceHarness(source: improve ? "Original" : nil, key: sentinels[0])
            try await h.ready(improve: improve, brief: sentinels[1] + sentinels[2], notes: sentinels[3])
            XCTAssertTrue(h.model.state.transcript.contains { $0.content.contains(sentinels[1]) })
            XCTAssertTrue(h.model.state.transcript.contains { $0.content.contains(sentinels[2]) })
            XCTAssertTrue(h.model.state.transcript.contains { $0.content.contains(sentinels[3]) })
            XCTAssertEqual(h.model.state.artifact?.notes, sentinels[3])
            let requests = await h.transport.snapshot()
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.headers["Authorization"], "Bearer " + sentinels[0])
            let requestBody = try XCTUnwrap(request.body)
            for sentinel in sentinels[1...2] { XCTAssertNotNil(requestBody.range(of: Data(sentinel.utf8))) }
            if reject { h.e.ui { h.model.reject() }; h.e.settle() }
            else { _ = try h.accept() }
            let stores: [FileStore] = [h.provider.files, h.e.h.data, h.e.h.files]
            for store in stores {
                for file in try store.listFiles() {
                    let bytes = try store.read(at: file.relativePath)
                    for sentinel in sentinels { XCTAssertNil(bytes.range(of: Data(sentinel.utf8))) }
                }
            }
            if reject {
                XCTAssertTrue(try h.e.h.data.listFiles().isEmpty)
                XCTAssertEqual(try h.e.h.files.listFiles().count, improve ? 1 : 0)
            }
        }
    }
}
