package ch.lkmc.monkeyspaw.core.conformance

import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

internal class DecodedDto(val status: Int?, val headerValue: String?, val encode: () -> ByteArray)

internal data class DtoCoverage(
    val cases: Int,
    val validCases: Int,
    val invalidCases: Int,
    val files: Set<String>,
)

/** Every named contract has a typed reader; no schema-only or pending adapters. */
internal object DtoRegistry {
    private fun <T> reader(codec: WireCodec<T>): Pair<String, (ByteArray) -> DecodedDto> =
        codec.name to { bytes ->
            val value = codec.decode(bytes)
            DecodedDto((value as? ErrorResponse)?.httpStatus, (value as? RetryAfter)?.headerValue) { codec.encode(value) }
        }

    val entries: Map<String, (ByteArray) -> DecodedDto> = mapOf(
        reader(HealthResponse.codec), reader(EmptyResponse.codec),
        reader(IDPath.codec), reader(MemberPath.codec), reader(RevisionPath.codec),
        reader(LoginRequest.codec), reader(RegisterRequest.codec), reader(PasswordChangeRequest.codec),
        reader(User.codec), reader(AuthResponse.codec), reader(Device.codec), reader(MeResponse.codec),
        reader(CreateUserRequest.codec), reader(UpdateUserRequest.codec),
        reader(Group.codec), reader(GroupMembership.codec), reader(CreateGroupRequest.codec), reader(RenameGroupRequest.codec),
        reader(Member.codec), reader(MembersResponse.codec), reader(MembershipRequest.codec),
        reader(GroupInviteRequest.codec), reader(JoinGroupRequest.codec), reader(AdminInviteRequest.codec), reader(InviteResponse.codec),
        reader(AccountKind.codec), reader(Role.codec), reader(InviteRole.codec), reader(WriteOrigin.codec),
        reader(RevisionOrigin.codec), reader(Mode.codec), reader(Severity.codec), reader(PromptScope.codec),
        reader(Prompt.codec), reader(PutPromptRequest.codec), reader(DeletePromptQuery.codec), reader(MovePromptRequest.codec),
        reader(WriteResponse.codec), reader(ConflictHead.codec), reader(ExistingPrompt.codec), reader(RevisionSummary.codec),
        reader(RevisionsResponse.codec), reader(Revision.codec), reader(FeedPrompt.codec),
        reader(PullRequest.codec), reader(FeedItem.codec), reader(ScopeIdentity.codec), reader(SyncScope.codec), reader(PullResponse.codec),
        reader(IssueLocation.codec), reader(Issue.codec), reader(FailureCode.codec), reader(ErrorResponse.codec), reader(RetryAfter.codec),
        reader(ProviderSettingsDocument.codec), reader(PutProviderSettingsRequest.codec), reader(ProviderSettingsResponse.codec),
    )

    fun consumeAll(corpus: Corpus, cases: List<FixtureCase> = corpus.cases(Category.DTO)): DtoCoverage {
        corpusRequire(entries.keys == corpus.schemas.keys, "DTO registration/schema catalog mismatch")
        val validator = SchemaValidator.load(corpus.schemas)
        val files = linkedSetOf<String>()
        val accepted = mutableSetOf<String>()
        val rejected = mutableSetOf<String>()
        var validCases = 0
        var invalidCases = 0
        for (fixture in cases) {
            val name = fixture.envelope["dto"].stringValue()
            checkCase(fixture, validator)
            if (fixture.expected["valid"].booleanValue()) { accepted.add(name); validCases++ }
            else { rejected.add(name); invalidCases++ }
            for (file in fixture.files) corpusRequire(files.add(file.relativePath), "Duplicate DTO file consumption")
        }
        corpusRequire(accepted == entries.keys && rejected == entries.keys, "Missing valid/invalid typed DTO coverage")
        val expectedFiles = corpus.cases(Category.DTO).flatMap { it.files }.map { it.relativePath }.toSet()
        corpusRequire(files == expectedFiles, "DTO consumption gap")
        return DtoCoverage(validCases + invalidCases, validCases, invalidCases, files)
    }

    fun checkCase(fixture: FixtureCase, validator: SchemaValidator) {
        val name = fixture.envelope["dto"].stringValue()
        val read = entries[name] ?: throw CorpusException("Unknown DTO $name")
        val valid = fixture.expected["valid"].booleanValue()
        val bytes = fixture.source().bytes()
        assertEquals(valid, validator.validate(bytes, name), "Schema mismatch: ${fixture.name}")

        // Keep encoding outside the decoding catch: an encode failure cannot make
        // a rejected fixture pass. Only the public decoding failure is accepted.
        val decoded = try { read(bytes) } catch (_: WireDecodingException) { null }
        if (!valid) {
            assertEquals(null, decoded, "Invalid DTO decoded: ${fixture.name}")
            return
        }
        val outcome = assertNotNull(decoded, "Valid DTO rejected: ${fixture.name}")
        if (name == "ErrorResponse") {
            assertEquals(fixture.expected["http_status"].integerValue().intValueExact(), outcome.status, "HTTP status: ${fixture.name}")
        }
        if (name == "RetryAfter") {
            assertEquals(fixture.expected["header_value"].stringValue(), outcome.headerValue, "Retry-After header: ${fixture.name}")
        }
        val encoded = outcome.encode()
        assertBytesEqual(bytes, encoded, "Canonical DTO bytes: ${fixture.name}")
        assertEquals(true, validator.validate(encoded, name), "Encoded DTO schema: ${fixture.name}")
    }
}
