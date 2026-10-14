package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.syncapi.Role
import kotlin.test.*

class SyncDomainTest {
    private val v = SyncTestValues

    @Test fun canonicalIDsHashesAndScopeSplitsRejectAliases() {
        for (raw in listOf(v.user.rawValue.lowercase(), v.user.rawValue.replace('0', 'O'),
            v.user.rawValue.replace('1', 'I'), v.user.rawValue.replace('1', 'L'), "invalid")) {
            assertFailsWith<SyncError.InvalidState> { SyncIdentifiers.ulid(raw) }
        }
        for (raw in listOf("", "user", "user:", ":${v.user.rawValue}", "USER:${v.user.rawValue}",
            "team:${v.user.rawValue}", "user:${v.user.rawValue}:extra")) {
            assertFailsWith<SyncError.InvalidState> { SyncScopeKey.parse(raw) }
        }
        assertEquals(v.userScope, SyncScopeKey.parse(v.userScope.rawValue))
        assertEquals(v.groupScope, SyncScopeKey.parse(v.groupScope.rawValue))
        for (raw in listOf(v.uuid.toString().uppercase(), "1-1-1-1-1", "invalid")) {
            assertFailsWith<SyncError.InvalidState> { SyncIdentifiers.uuid(raw) }
        }
        for (raw in listOf("a".repeat(63), "A".repeat(64), "z".repeat(64))) assertFailsWith<SyncError.InvalidHash> { SyncHash(raw) }
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", SyncHash.of(byteArrayOf()).rawValue)
    }

    @Test fun rootsAreAbsoluteLexicalAndByteDistinctWithoutFilesystemLookups() {
        for (root in listOf("", "relative", "/one/../two", "/one/./two", "/one//two", "/one/", "/one\\two", "/one\u0000two", "/one\u200btwo", "/\ud800")) {
            assertFailsWith<SyncError.InvalidRoot> { SyncLibraryRoot(root) }
        }
        for (root in listOf("/", "/home/not-existing/library", "/Caf\u00e9", "/Cafe\u0301", "/" + "a".repeat(2048))) {
            assertEquals(root, SyncLibraryRoot(root).path)
        }
        assertNotEquals(SyncLibraryRoot("/Caf\u00e9"), SyncLibraryRoot("/Cafe\u0301"))
    }

    @Test fun accountSyntaxRequiresAnAlreadyCanonicalBaseWithoutActingAsHTTPPolicy() {
        val invalid = listOf("", "https://username:password@example.test", "https://example.test?device_token=secret",
            "https://example.test#secret", "https://EXAMPLE.test", "https://example.test:443", "https://example.test/",
            "https://example.test/a/../b", "https://example.test/a%2fb", "https://example.test/api/v1", "https://example.test/%00",
            "https://example.test/a%5cb", "https://example.test/a//b", "https://example.test.", "https://example.test:",
            "http://example.test:80", "https://example.test:0", "https://example.test:65536", "HTTPS://example.test", "https://é.test")
        for (server in invalid) assertFailsWith<SyncError.InvalidAccount>(server) { v.accountIdentity(server) }
        // Z5 owns transport authorization. Syntax alone may represent an HTTP server requiring rejection there.
        for (server in listOf("https://example.test", "https://example.test/paw", "http://example.test", "http://127.0.0.1:8080",
            "http://[::1]:8080/paw", "https://example.test/Caf%C3%A9")) assertEquals(server, v.accountIdentity(server).serverURL)
    }

    @Test fun directDomainValidationUsesFixedErrorsWithoutRetainingInputs() {
        val validations: List<() -> Any> = listOf(
            { v.account().copy(username = "UPPER") },
            { v.account().copy(deviceName = "") },
            { SyncManagedFolder(v.accountIdentity(), "../secret-sentinel") },
            { SyncManagedFolder(v.accountIdentity(), "a".repeat(256)) },
            { SyncManagedFolder(v.accountIdentity(), "Cafe\u0301") },
            { SyncHeldPrompt(PromptIdentity.Local("secret-sentinel"), "Held.md", v.accountIdentity(), v.hash) },
            { SyncHeldPrompt(v.personalID, "../secret-sentinel.md", v.accountIdentity(), v.hash) },
            { SyncGroupState("", "Team", Role.VIEWER) },
        )
        for (validate in validations) {
            val error = assertFailsWith<SyncError.InvalidState> { validate() }
            assertNull(error.cause)
            assertFalse("secret-sentinel" in error.toString())
        }
    }

    @Test fun scopesFoldersAndHoldUniquenessPreservePriorOwnershipAndDuplicateVersions() {
        val state = v.state()
        assertFailsWith<SyncError.InvalidScope> { state.copy(cursors = mapOf(SyncScopeKey.User(v.otherUser) to "opaque")) }
        assertFailsWith<SyncError.InvalidState> { state.copy(groups = mapOf(v.group to SyncGroupState("a", "Straße", Role.VIEWER),
            v.device to SyncGroupState("b", "STRASSE", Role.EDITOR))) }
        assertFailsWith<SyncError.InvalidState> { SyncPromptState(v.groupScope, "a.md", 1, v.hash, SyncPromptOrigin.Rescued) }
        val ownership = v.ownership()
        assertFailsWith<SyncError.InvalidState> { ownership.copy(holds = ownership.holds + ownership.holds.first()) }
        val next = ownership.copy(owner = v.accountIdentity(userID = v.otherUser),
            holds = listOf(ownership.holds.first(), ownership.holds.first().copy(path = "Copy.md")))
        assertEquals(next, SyncAccountJson.binding(SyncAccountJson.binding(next)))
        val nestedGroupPath = state.prompts.getValue(v.groupID).copy(path = "Other/File.md")
        assertEquals("Other/File.md", state.copy(prompts = state.prompts + (v.groupID to nestedGroupPath)).prompts[v.groupID]!!.path)
    }

    @Test fun fingerprintOwnsHashesAndChangesWithEveryOffendingInput() {
        val bytes = byteArrayOf(1)
        val original = SyncInputFingerprint(bytes, "A.md", v.userScope, 0, SyncOperation.PUT)
        bytes[0] = 2
        assertEquals(SyncHash.of(byteArrayOf(1)), original.contentHash)
        val changed = listOf(original.copy(contentHash = SyncHash.of(bytes)),
            SyncInputFingerprint(byteArrayOf(1), "B.md", v.userScope, 0, SyncOperation.PUT),
            original.copy(scope = v.groupScope), original.copy(accessGeneration = 1), original.copy(operation = SyncOperation.MOVE))
        for (candidate in changed) assertNotEquals(original, candidate)
        assertFailsWith<SyncError.InvalidState> { original.copy(accessGeneration = -1) }
    }
}
