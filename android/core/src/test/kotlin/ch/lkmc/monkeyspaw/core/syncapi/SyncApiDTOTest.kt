package ch.lkmc.monkeyspaw.core.syncapi

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueLocation
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueSeverity
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathIssue
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathIssueCode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class SyncApiDTOTest {
    private val id = "01K6Z4V9KQWZX7MPQ4T8ZNB2PD"
    private val groupID = "01K6Z4V9KQWZX7MPQ4T8ZNB2PE"
    private val databaseID = "12345678-1234-1234-1234-123456789abc"
    private val timestamp = "2026-10-12T20:10:56.557Z"
    private val prompt = FeedPrompt(id, 1, "Notes/Café.md", "body\r\n")
    private val error = Issue("yaml.invalid", Severity.ERROR)
    private val warning = Issue("field.unused", Severity.WARNING)

    private fun scope(identity: ScopeIdentity, count: Int = 0) =
        SyncScope(identity, Mode.DELTA, 1, "opaque", false, List(count) { FeedItem.Upsert(1, prompt) })

    @Test
    fun `constructed invalid values fail encoding including nested contracts and relations`() {
        val user = scope(ScopeIdentity.User(id))
        val group = scope(ScopeIdentity.Group(groupID, "Group", Role.EDITOR))
        val summary = RevisionSummary(1, id, timestamp, RevisionOrigin.EDIT, PromptScope.User, "a.md")
        val invalid: List<Pair<String, () -> ByteArray>> = listOf(
            "Prompt revision" to { Prompt.codec.encode(Prompt(id, 0, PromptScope.User, "a.md", "")) },
            "Prompt nested group id" to { Prompt.codec.encode(Prompt(id, 1, PromptScope.Group("bad"), "a.md", "")) },
            "Put base revision" to { PutPromptRequest.codec.encode(PutPromptRequest(-1, PromptScope.User, "a.md", "")) },
            "Put multibyte content" to { PutPromptRequest.codec.encode(PutPromptRequest(0, PromptScope.User, "a.md", "é".repeat(131_073))) },
            "Delete revision" to { DeletePromptQuery.codec.encode(DeletePromptQuery(0)) },
            "Move revision" to { MovePromptRequest.codec.encode(MovePromptRequest(0, PromptScope.User, "a.md")) },
            "Move multibyte path" to { MovePromptRequest.codec.encode(MovePromptRequest(1, PromptScope.User, "é".repeat(513))) },
            "Write sequence" to { WriteResponse.codec.encode(WriteResponse(1, 0)) },
            "Write warning severity" to { WriteResponse.codec.encode(WriteResponse(1, 1, listOf(error))) },
            "Write nested warning" to { WriteResponse.codec.encode(WriteResponse(1, 1, listOf(warning.copy(location = IssueLocation.Body(-1))))) },
            "Conflict empty path" to { ConflictHead.codec.encode(ConflictHead(1, PromptScope.User, "", "")) },
            "Existing id" to { ExistingPrompt.codec.encode(ExistingPrompt("bad", 1, "")) },
            "Summary calendar" to { RevisionSummary.codec.encode(summary.copy(createdAt = "1900-02-29T00:00:00.000Z")) },
            "Revision list cap" to { RevisionsResponse.codec.encode(RevisionsResponse(List(Limits.revisionListCap + 1) { summary })) },
            "Revision list nested id" to { RevisionsResponse.codec.encode(RevisionsResponse(listOf(summary.copy(authorID = "bad")))) },
            "Revision nested scope" to { Revision.codec.encode(Revision(id, 1, id, timestamp, RevisionOrigin.MOVE, PromptScope.Group("bad"), "a.md", "")) },
            "FeedPrompt empty path" to { FeedPrompt.codec.encode(prompt.copy(path = "")) },
            "Pull cursor key" to { PullRequest.codec.encode(PullRequest(null, mapOf("user:bad" to "0"))) },
            "Pull empty cursor" to { PullRequest.codec.encode(PullRequest(null, mapOf("user:$id" to ""))) },
            "Feed sequence" to { FeedItem.codec.encode(FeedItem.Delete(0, id)) },
            "Feed nested content" to { FeedItem.codec.encode(FeedItem.Upsert(1, prompt.copy(content = "\uD800"))) },
            "User identity" to { ScopeIdentity.codec.encode(ScopeIdentity.User("bad")) },
            "Group identity name" to { ScopeIdentity.codec.encode(ScopeIdentity.Group(groupID, "", Role.VIEWER)) },
            "Scope head" to { SyncScope.codec.encode(user.copy(head = -1)) },
            "Scope cursor" to { SyncScope.codec.encode(user.copy(cursor = "")) },
            "Scope item cap" to { SyncScope.codec.encode(scope(user.identity, Limits.syncPageItemCap + 1)) },
            "Scope item above head" to { SyncScope.codec.encode(user.copy(items = listOf(FeedItem.Delete(2, id)))) },
            "Snapshot delete" to { SyncScope.codec.encode(user.copy(mode = Mode.SNAPSHOT, items = listOf(FeedItem.Delete(1, id)))) },
            "Snapshot unequal sequence" to { SyncScope.codec.encode(user.copy(mode = Mode.SNAPSHOT, head = 2, items = listOf(FeedItem.Upsert(1, prompt)))) },
            "Pull shared budget" to { PullResponse.codec.encode(PullResponse(databaseID, listOf(scope(user.identity, 100), scope(group.identity, 101)), emptyList())) },
            "Pull duplicate scope" to { PullResponse.codec.encode(PullResponse(databaseID, listOf(user, user), emptyList())) },
            "Pull missing user" to { PullResponse.codec.encode(PullResponse(databaseID, listOf(group), emptyList())) },
            "Pull multiple users" to { PullResponse.codec.encode(PullResponse(databaseID, listOf(user, scope(ScopeIdentity.User(groupID))), emptyList())) },
            "Pull removed overlap" to { PullResponse.codec.encode(PullResponse(databaseID, listOf(user, group), listOf(group.identity.key))) },
            "Pull removed duplicates" to { PullResponse.codec.encode(PullResponse(databaseID, listOf(user), listOf(group.identity.key, group.identity.key))) },
            "Location line" to { IssueLocation.codec.encode(IssueLocation.FrontMatter(0, 1)) },
            "Location offset" to { IssueLocation.codec.encode(IssueLocation.Body(-1)) },
            "Location segment" to { IssueLocation.codec.encode(IssueLocation.Path(-1)) },
            "Issue unknown code" to { Issue.codec.encode(Issue("unknown", Severity.ERROR)) },
            "Issue mismatched severity" to { Issue.codec.encode(error.copy(severity = Severity.WARNING)) },
            "Error nested head" to { ErrorResponse.codec.encode(ErrorResponse.Conflict(ConflictHead(0, PromptScope.User, "a.md", ""))) },
            "Error empty issues" to { ErrorResponse.codec.encode(ErrorResponse.Validation(emptyList())) },
            "Error warning issues" to { ErrorResponse.codec.encode(ErrorResponse.Validation(listOf(warning))) },
            "Error nested issue" to { ErrorResponse.codec.encode(ErrorResponse.Validation(listOf(error.copy(location = IssueLocation.Body(-1))))) },
            "Snapshot empty scopes" to { ErrorResponse.codec.encode(ErrorResponse.SnapshotExpired(emptyList())) },
            "Snapshot duplicate scopes" to { ErrorResponse.codec.encode(ErrorResponse.SnapshotExpired(listOf(user.identity.key, user.identity.key))) },
        )
        for ((name, encode) in invalid) assertFailsWith<WireEncodingException>(name) { encode() }
    }

    @Test
    fun `pull shared budget boundary accepts opaque cursors and snapshots at the head`() {
        val user = scope(ScopeIdentity.User(id), 100)
        val group = scope(ScopeIdentity.Group(groupID, "Group", Role.VIEWER), 100)
            .copy(mode = Mode.SNAPSHOT, cursor = "s:opaque/not-parsed")
        val response = PullResponse(databaseID, listOf(user, group), emptyList())
        assertEquals(response, PullResponse.codec.decode(PullResponse.codec.encode(response)))
        val empty = PullResponse(databaseID, listOf(user.copy(head = 0, items = emptyList())), emptyList())
        assertEquals(empty, PullResponse.codec.decode(PullResponse.codec.encode(empty)))
        val request = PullRequest(null, mapOf(user.identity.key to "arbitrary / cursor"))
        assertEquals(request, PullRequest.codec.decode(PullRequest.codec.encode(request)))
    }

    @Test
    fun `every Core diagnostic maps to its exact code severity and location`() {
        for (code in PromptIssueCode.entries) {
            val source = PromptIssue(code, PromptIssueLocation.FrontMatter(2, 3))
            val issue = Issue(source)
            assertEquals(code.rawValue, issue.code)
            assertEquals(if (source.severity == PromptIssueSeverity.WARNING) Severity.WARNING else Severity.ERROR, issue.severity)
            assertEquals(IssueLocation.FrontMatter(2, 3), issue.location)
            assertEquals(issue, Issue.codec.decode(Issue.codec.encode(issue)))
            val opposite = if (issue.severity == Severity.WARNING) Severity.ERROR else Severity.WARNING
            assertFailsWith<WireEncodingException> { Issue.codec.encode(issue.copy(severity = opposite)) }
        }
        assertEquals(IssueLocation.Body(7), Issue(PromptIssue(PromptIssueCode.INVALID_PLACEHOLDER, PromptIssueLocation.Body(7))).location)
        assertEquals(null, Issue(PromptIssue(PromptIssueCode.INVALID_YAML)).location)
        for (code in SyncPathIssueCode.entries) {
            for (segment in listOf(null, 0, 2)) {
                val issue = Issue(SyncPathIssue(code, segment))
                assertEquals(code.wireCode, issue.code)
                assertEquals(Severity.ERROR, issue.severity)
                assertEquals(IssueLocation.Path(segment?.toLong()), issue.location)
                assertEquals(issue, Issue.codec.decode(Issue.codec.encode(issue)))
            }
        }
        val mismatch = Issue("prompt.id_mismatch", Severity.ERROR)
        assertEquals(mismatch, Issue.codec.decode(Issue.codec.encode(mismatch)))
    }

    @Test
    fun `Retry-After validates seconds and exact unsigned decimal HTTP spelling`() {
        for (seconds in listOf(1L, 30L, 900L)) {
            val value = RetryAfter(seconds)
            assertEquals(value, RetryAfter(value.headerValue))
            assertEquals(value, RetryAfter.codec.decode(RetryAfter.codec.encode(value)))
        }
        for (seconds in listOf(Long.MIN_VALUE, -1, 0, 901, Long.MAX_VALUE)) {
            assertFailsWith<IllegalArgumentException> { RetryAfter(seconds) }
            assertFailsWith<WireDecodingException> { RetryAfter.codec.decode(seconds.toString().toByteArray()) }
        }
        for (header in listOf("", "0", "01", "+1", "-1", " 1", "1 ", "1\n", "1.0", "1e0", "901", "9223372036854775808", "Thu, 01 Jan 1970 00:00:00 GMT")) {
            assertFailsWith<IllegalArgumentException> { RetryAfter(header) }
        }
    }
}
