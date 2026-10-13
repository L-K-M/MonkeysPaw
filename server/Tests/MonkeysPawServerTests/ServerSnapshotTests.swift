import Foundation
import MonkeysPawCore
import Testing
@testable import MonkeysPawServer

@Suite(.serialized)
struct ServerSnapshotTests {
    @Test func emptyInitialScopeCompletesAtZero() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let response = try await fixture.feed.pull(request: .init(databaseID: nil, cursors: [:]), session: session.identity)
            #expect(response.scopes == [.init(identity: .user(userID: user.id), mode: .snapshot, head: 0,
                                             cursor: "0", hasMore: false, items: [])])
            #expect(!response.databaseID.isEmpty && response.removed.isEmpty)
            _ = try JSONDecoder().decode(SyncAPI.PullResponse.self, from: JSONEncoder().encode(response))
        }
    }

    @Test func initialSnapshotPagesByIDAndFinishesAtItsCapturedHead() async throws {
        try await withGroupFixture { fixture in
            let user = try await fixture.user("reader")
            let session = try await fixture.account.session(user)
            let identity = PromptOwnership.user(ownerID: user.id)
            let prompts = try await fixture.seedSnapshot(identity: identity, author: user, count: 201)
            let first = try await fixture.feed.pull(request: .init(databaseID: nil, cursors: [:]), session: session.identity)
            let page = try first.scope(identity.key)
            #expect(page.mode == .snapshot && page.head == 201 && page.hasMore && page.cursor.hasPrefix("snap:"))
            #expect(page.items == prompts.prefix(200).map { .upsert(seq: page.head, prompt: $0) })
            let second = try await fixture.feed.pull(request: first.continuation, session: session.identity)
            let final = try second.scope(identity.key)
            #expect(final.mode == .snapshot && final.head == page.head && final.cursor == String(page.head) && !final.hasMore)
            #expect(final.items == [.upsert(seq: page.head, prompt: prompts[200])])
            let delta = try await fixture.feed.pull(request: second.continuation, session: session.identity).scope(identity.key)
            #expect(delta.mode == .delta && delta.cursor == final.cursor && delta.items.isEmpty && !delta.hasMore)
        }
    }
}

extension GroupTestFixture {
    /// Reverse insert order makes snapshot ID order independent of change order.
    func seedSnapshot(identity: PromptOwnership, author: AccountRecord, count: Int, startingID: Int = 1,
                      content: String? = nil) async throws -> [SyncAPI.FeedPrompt] {
        let prompts = (startingID..<(startingID + count)).map {
            SyncAPI.FeedPrompt(id: feedTestID($0), rev: 1, path: "\($0).md", content: content ?? snapshotContent(id: feedTestID($0)))
        }
        try await promptRepository.write { repository, _, _, _ in
            for prompt in prompts.reversed() {
                let head = PromptRecord(id: prompt.id, identity: identity, path: prompt.path, pathKey: prompt.path.lowercased(),
                                        content: prompt.content, title: "Fixture", rev: prompt.rev, createdBy: author.id,
                                        createdAt: author.createdAt, updatedBy: author.id, updatedAt: author.createdAt, deletedAt: nil)
                try await repository.insert(head)
                try await repository.appendRevision(head, origin: .edit)
                _ = try await repository.appendUpsert(head)
            }
        }
        return prompts
    }
}

// All-digit ULIDs must be quoted to remain strings in YAML front matter.
func snapshotContent(id: String, metadata: String = "title: Example\n", body: String = "Original body\n") -> String {
    promptContent(id: "\"\(id)\"", metadata: metadata, body: body)
}
