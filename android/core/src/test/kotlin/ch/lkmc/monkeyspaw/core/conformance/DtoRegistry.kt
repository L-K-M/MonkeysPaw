package ch.lkmc.monkeyspaw.core.conformance

import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

internal sealed interface DtoRegistration {
    class Completed(val decode: (ByteArray) -> DecodedDto) : DtoRegistration
    data object PendingK10 : DtoRegistration
}

internal class DecodedDto(val encode: () -> ByteArray)

internal data class DtoCoverage(
    val completedCases: Int,
    val validCases: Int,
    val invalidCases: Int,
    val completedFiles: Set<String>,
    val pendingCases: Map<String, List<String>>,
    val pendingFiles: Set<String>,
)

/** Explicitly incomplete until K10. Pending entries never count as typed consumption. */
internal object DtoRegistry {
    private fun <T> completed(codec: WireCodec<T>): Pair<String, DtoRegistration> =
        codec.name to DtoRegistration.Completed { bytes ->
            val value = codec.decode(bytes)
            DecodedDto { codec.encode(value) }
        }

    val entries: Map<String, DtoRegistration> = mapOf(
        completed(HealthResponse.codec), completed(EmptyResponse.codec),
        completed(IDPath.codec), completed(MemberPath.codec), completed(RevisionPath.codec),
        completed(LoginRequest.codec), completed(RegisterRequest.codec), completed(PasswordChangeRequest.codec),
        completed(User.codec), completed(AuthResponse.codec), completed(Device.codec), completed(MeResponse.codec),
        completed(CreateUserRequest.codec), completed(UpdateUserRequest.codec),
        completed(Group.codec), completed(GroupMembership.codec), completed(CreateGroupRequest.codec), completed(RenameGroupRequest.codec),
        completed(Member.codec), completed(MembersResponse.codec), completed(MembershipRequest.codec),
        completed(GroupInviteRequest.codec), completed(JoinGroupRequest.codec), completed(AdminInviteRequest.codec), completed(InviteResponse.codec),
        completed(AccountKind.codec), completed(Role.codec), completed(InviteRole.codec), completed(WriteOrigin.codec),
        completed(RevisionOrigin.codec), completed(Mode.codec), completed(Severity.codec), completed(PromptScope.codec),
        "Prompt" to DtoRegistration.PendingK10,
        "PutPromptRequest" to DtoRegistration.PendingK10,
        "DeletePromptQuery" to DtoRegistration.PendingK10,
        "MovePromptRequest" to DtoRegistration.PendingK10,
        "WriteResponse" to DtoRegistration.PendingK10,
        "ConflictHead" to DtoRegistration.PendingK10,
        "ExistingPrompt" to DtoRegistration.PendingK10,
        "RevisionSummary" to DtoRegistration.PendingK10,
        "RevisionsResponse" to DtoRegistration.PendingK10,
        "Revision" to DtoRegistration.PendingK10,
        "FeedPrompt" to DtoRegistration.PendingK10,
        "PullRequest" to DtoRegistration.PendingK10,
        "FeedItem" to DtoRegistration.PendingK10,
        "ScopeIdentity" to DtoRegistration.PendingK10,
        "SyncScope" to DtoRegistration.PendingK10,
        "PullResponse" to DtoRegistration.PendingK10,
        "IssueLocation" to DtoRegistration.PendingK10,
        "Issue" to DtoRegistration.PendingK10,
        "FailureCode" to DtoRegistration.PendingK10,
        "ErrorResponse" to DtoRegistration.PendingK10,
        "RetryAfter" to DtoRegistration.PendingK10,
    )

    val completedNames: Set<String> get() = entries.filterValues { it is DtoRegistration.Completed }.keys
    val pendingNames: Set<String> get() = entries.filterValues { it == DtoRegistration.PendingK10 }.keys
    val isComplete: Boolean get() = pendingNames.isEmpty()

    fun consumeAll(corpus: Corpus): DtoCoverage {
        corpusRequire(isComplete, "DTO registry incomplete; pending K10: ${pendingNames.sorted()}")
        return consumeCompleted(corpus)
    }

    fun consumeCompleted(corpus: Corpus, cases: List<FixtureCase> = corpus.cases(Category.DTO)): DtoCoverage {
        corpusRequire(entries.keys == corpus.schemas.keys, "DTO registration/schema catalog mismatch")
        val validator = SchemaValidator.load(corpus.schemas)
        val completedFiles = linkedSetOf<String>()
        val pendingFiles = linkedSetOf<String>()
        val pendingCases = linkedMapOf<String, MutableList<String>>()
        val accepted = mutableSetOf<String>()
        val rejected = mutableSetOf<String>()
        var validCases = 0
        var invalidCases = 0
        for (fixture in cases) {
            val name = fixture.envelope["dto"].stringValue()
            when (entries[name] ?: throw CorpusException("Unknown DTO $name")) {
                DtoRegistration.PendingK10 -> {
                    pendingCases.getOrPut(name) { mutableListOf() }.add(fixture.name)
                    for (file in fixture.files) corpusRequire(pendingFiles.add(file.relativePath), "Duplicate pending DTO file")
                }
                is DtoRegistration.Completed -> {
                    checkCase(fixture, validator)
                    if (fixture.expected["valid"].booleanValue()) { accepted.add(name); validCases++ }
                    else { rejected.add(name); invalidCases++ }
                    for (file in fixture.files) corpusRequire(completedFiles.add(file.relativePath), "Duplicate completed DTO file")
                }
            }
        }
        corpusRequire(accepted == completedNames && rejected == completedNames, "Missing valid/invalid typed DTO coverage")
        corpusRequire(pendingCases.keys == pendingNames, "Missing pending K10 DTO coverage")
        corpusRequire(completedFiles.intersect(pendingFiles).isEmpty(), "Overlapping DTO accounting")
        val expectedFiles = corpus.cases(Category.DTO).flatMap { it.files }.map { it.relativePath }.toSet()
        corpusRequire(completedFiles + pendingFiles == expectedFiles, "DTO accounting gap")
        return DtoCoverage(validCases + invalidCases, validCases, invalidCases, completedFiles, pendingCases, pendingFiles)
    }

    fun checkCase(fixture: FixtureCase, validator: SchemaValidator) {
        val name = fixture.envelope["dto"].stringValue()
        val registration = entries[name] as? DtoRegistration.Completed
            ?: throw CorpusException("DTO $name has no completed typed codec")
        val valid = fixture.expected["valid"].booleanValue()
        val bytes = fixture.source().bytes()
        assertEquals(valid, validator.validate(bytes, name), "Schema mismatch: ${fixture.name}")

        // Keep encoding outside the decoding catch: an encode failure cannot make
        // a rejected fixture pass. Only the public decoding failure is accepted.
        val decoded = try { registration.decode(bytes) } catch (_: WireDecodingException) { null }
        if (!valid) {
            assertEquals(null, decoded, "Invalid DTO decoded: ${fixture.name}")
            return
        }
        val encoded = assertNotNull(decoded, "Valid DTO rejected: ${fixture.name}").encode()
        assertBytesEqual(bytes, encoded, "Canonical DTO bytes: ${fixture.name}")
        assertEquals(true, validator.validate(encoded, name), "Encoded DTO schema: ${fixture.name}")
    }
}
