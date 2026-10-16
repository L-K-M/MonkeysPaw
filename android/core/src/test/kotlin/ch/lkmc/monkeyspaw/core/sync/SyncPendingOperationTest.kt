package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.util.Base64
import kotlin.test.*

class SyncPendingOperationTest {
    private val v = SyncTestValues

    private fun request(h: PushHarness, operation: SyncOperation = SyncOperation.PUT): SyncPendingOperation {
        val file = if (operation == SyncOperation.DELETE) null else h.mutations.read("a.md")!!
        val record = h.record
        val intent = SyncConflictIntent(v.personal, operation, record.rev, record.scope, record.path,
            file?.bytes, file?.bytes ?: byteArrayOf(), 7)
        return SyncPendingOperation(h.binding, intent, "a.md", file, record)
    }

    @Test fun versionOneSwiftStorageShapeRoundTripsOwnedBytesAndRedactsDiagnostics() {
        val h = PushHarness().seed(3, ScanHarness.bytes("sensitive sentinel\r\n", extra = "# exact\n"))
        val request = request(h)
        val encoded = SyncPendingOperationJson.codec.encode(request)
        assertEquals(setOf("version", "account", "root", "id", "operation", "baseRev", "scope", "path", "sentBytes",
            "sentHash", "fingerprint", "libraryPath", "file", "recorded"), encoded.fields.keys)
        assertEquals("/library", encoded.text("root"))
        assertEquals("put", encoded.text("operation"))
        assertEquals(h.binding.account.serverURL, encoded.required("account").objectValue().text("server_url"))
        assertEquals(v.personal.rawValue, encoded.text("id"))
        assertEquals(Base64.getEncoder().encodeToString(request.file!!.bytes), encoded.text("sentBytes"))
        val f = encoded.required("file").objectValue()
        assertEquals(setOf("path", "stamp", "identityKey", "bytes", "hash"), f.fields.keys)
        assertEquals(request.file.stamp.journalToken(), f.required("stamp").objectValue().text("token"))
        assertEquals(setOf("scope_key", "path", "rev", "canonical_hash", "origin", "last_error"), encoded.required("recorded").objectValue().fields.keys)
        h.pending.save(request)
        val exact = h.data.read("sync/push.json")
        val loaded = h.restart().pending.load(h.binding)!!
        assertContentEquals(exact, syncDocumentBytes(SyncPendingOperationJson.codec.encode(loaded)))
        loaded.intent.sentBytes!!.fill(0)
        loaded.file!!.bytes.fill(0)
        assertContentEquals(request.intent.sentBytes, loaded.intent.sentBytes)
        assertContentEquals(request.file.bytes, loaded.file.bytes)
        assertFalse(listOf(request, request.intent, loaded, loaded.file).toString().contains("sentinel"))
        assertEquals(request.intent.fingerprint, loaded.intent.fingerprint)
        assertEquals(request.recorded, loaded.recorded)
        assertEquals(h.binding, loaded.binding)
        assertTrue(h.data.isPrivate("sync/push.json"))
    }

    @Test fun putMoveDeleteShapesPreserveOriginErrorFingerprintAndExplicitNulls() {
        for (operation in SyncOperation.entries) {
            val h = PushHarness().seed(3)
            h.states.update(h.binding) { it.copy(prompts = it.prompts + (v.personalID to h.record.copy(
                origin = SyncPromptOrigin.ConflictOf(v.groupPrompt), lastError = SyncPromptError(SyncIssueCode.NotFound,
                    SyncInputFingerprint(ScanHarness.bytes(), "a.md", v.userScope, 4, SyncOperation.PUT))))) }
            val request = request(h, operation)
            h.pending.save(request)
            val loaded = h.restart().pending.load(h.binding)!!
            assertEquals(operation, loaded.intent.operation)
            assertEquals(request.recorded, loaded.recorded)
            assertEquals(request.intent.fingerprint, loaded.intent.fingerprint)
            val encoded = SyncPendingOperationJson.codec.encode(loaded)
            if (operation == SyncOperation.DELETE) {
                assertEquals(WireValue.Null, encoded.required("file"))
                assertEquals(WireValue.Null, encoded.required("sentBytes"))
                assertEquals(WireValue.Null, encoded.required("sentHash"))
            }
        }
    }

    @Test fun refusesSlotOverwriteAndForeignBindingWithoutChangingExactIntent() {
        val h = PushHarness().seed(3)
        val request = request(h)
        h.pending.save(request)
        val exact = h.data.read("sync/push.json")
        assertFailsWith<SyncError.InvalidState> { h.pending.save(request) }
        assertContentEquals(exact, h.data.read("sync/push.json"))
        assertFailsWith<SyncError.BindingMismatch> { h.pending.load(v.binding(account = v.accountIdentity(userID = v.otherUser))) }
        assertFailsWith<SyncError.BindingMismatch> { h.pending.load(v.binding(root = "/another")) }
        assertContentEquals(exact, h.data.read("sync/push.json"))
    }

    @Test fun tamperedHashesFingerprintIdentityBytesAndFileBaselinesFailClosed() {
        val h = PushHarness().seed(3)
        val valid = SyncPendingOperationJson.codec.encode(request(h))
        val bad = listOf(
            valid.withText("sentHash", "f".repeat(64)),
            valid.withText("sentBytes", Base64.getEncoder().encodeToString(ScanHarness.bytes("Different"))),
            valid.withText("sentBytes", "@"),
            valid.withText("id", v.groupPrompt.rawValue),
            valid.withText("scope", SyncScopeKey.User(v.otherUser).rawValue),
            valid.withText("libraryPath", "../outside.md"),
            valid.withText("operation", "unknown"),
            valid.setting("baseRev", wireLong(4)),
            valid.edit("file") { it.withText("hash", "f".repeat(64)) },
            valid.edit("file") { it.withText("identityKey", v.groupPrompt.rawValue) },
            valid.edit("file") { it.withText("path", "other.md") },
            valid.edit("file") { it.edit("stamp") { stamp -> stamp.withText("token", "") } },
            valid.edit("fingerprint") { it.withText("content_hash", "f".repeat(64)) },
            valid.edit("fingerprint") { it.withText("path_hash", "f".repeat(64)) },
            valid.edit("fingerprint") { it.withText("scope_key", SyncScopeKey.Group(v.group).rawValue) },
            valid.edit("fingerprint") { it.withText("operation", "delete") },
        )
        for (value in bad) {
            h.data.put(syncDocumentBytes(value), "sync/push.json")
            val store = SyncPendingOperationStore(h.data, h.operations)
            assertFailsWith<SyncError.CorruptFile> { store.load(h.binding) }
            assertFailsWith<SyncError.CorruptFile> { store.load(h.binding) }
        }
    }

    @Test fun malformedFutureUnsupportedOversizeAndUnreadableDocumentsRemainBlocked() {
        val h = PushHarness().seed(3)
        val valid = SyncPendingOperationJson.codec.encode(request(h))
        for ((bytes, expected) in listOf(
            "not json".encodeToByteArray() to SyncError.CorruptFile,
            syncDocumentBytes(valid.setting("version", wireBoolean(true))) to SyncError.CorruptFile,
            syncDocumentBytes(valid.setting("version", wireLong(2))) to SyncError.FutureVersion(2),
            syncDocumentBytes(valid.setting("version", wireLong(0))) to SyncError.UnsupportedVersion(0),
            ByteArray(Limits.syncRecordMaxBytes + 1) { 32 } to SyncError.CorruptFile,
        )) {
            h.data.put(bytes, "sync/push.json")
            val store = SyncPendingOperationStore(h.data, h.operations)
            assertEquals(expected, runCatching { store.load(h.binding) }.exceptionOrNull())
            assertContentEquals(bytes, h.data.read("sync/push.json"))
        }
        h.data.put(syncDocumentBytes(valid), "sync/push.json")
        h.data.fault = { operation, path -> if (operation == MemoryStore.Operation.READ && path == "sync/push.json") StoreError.IOFailure else null }
        val store = SyncPendingOperationStore(h.data, h.operations)
        h.data.fault = null
        assertFailsWith<SyncError.ReadFailed> { store.load(h.binding) }
        assertNotNull(SyncPendingOperationStore(h.data, h.operations).load(h.binding))
    }

    @Test fun failedWriteRetainsOldCacheAndDoesNotReplaceIntent() {
        val h = PushHarness().seed(3)
        h.data.fault = { operation, _ -> if (operation == MemoryStore.Operation.PRIVATE_WRITE) StoreError.IOFailure else null }
        assertFailsWith<SyncError.WriteFailed> { h.pending.save(request(h)) }
        assertNull(h.pending.snapshot.value)
        assertNull(h.data.stamp("sync/push.json"))
        h.data.fault = null
        h.pending.save(request(h))
        assertNotNull(h.pending.load(h.binding))
    }

    @Test fun uncertainPublicationAndDeletionNeedExplicitReflushOnSameStore() {
        for (delete in listOf(false, true)) {
            val h = PushHarness().seed(3)
            val request = request(h)
            if (delete) h.pending.save(request)
            h.operations.onOperation = { if (it == "directory:sync") throw SyncFileOperationError(SyncFileFailureCode.DURABILITY_FAILED) }
            assertFailsWith<SyncError.DurabilityUncertain> { if (delete) h.pending.clear() else h.pending.save(request) }
            assertFailsWith<SyncError.DurabilityUncertain> { h.pending.load(h.binding) }
            h.operations.onOperation = null
            h.operations.calls.clear()
            val recovered = h.pending.recoverForAccountTransition()
            assertEquals(delete, recovered == null)
            assertTrue("directory:sync" in h.operations.calls && "directory:<root>" in h.operations.calls)
            if (!delete) assertContentEquals(request.intent.sentBytes, recovered!!.intent.sentBytes)
        }
    }

    @Test fun clearRetriesFlushEvenIfPriorDeleteAlreadyRemovedFile() {
        val h = PushHarness().seed(3)
        h.pending.save(request(h))
        h.operations.onOperation = { if (it == "directory:sync") throw SyncFileOperationError(SyncFileFailureCode.DURABILITY_FAILED) }
        assertFailsWith<SyncError.DurabilityUncertain> { h.pending.clear() }
        assertNull(h.data.stamp("sync/push.json"))
        h.operations.onOperation = null
        h.operations.calls.clear()
        h.pending.clear()
        assertEquals(listOf("directory:sync", "directory:<root>"), h.operations.calls)
        assertNull(h.pending.load(h.binding))
    }

    @Test fun heldRetentionIsPrivateExactIdempotentAndRefusesConflictingBytes() {
        val h = PushHarness().seed(3)
        val request = request(h)
        h.pending.save(request)
        val exact = h.data.read("sync/push.json")
        h.pending.retainHeld(request)
        h.pending.retainHeld(request)
        val path = h.data.listFiles().single { it.relativePath.startsWith("sync/retained/push-") }.relativePath
        assertContentEquals(exact, h.data.read(path))
        assertTrue(h.data.isPrivate(path))
        assertTrue("file:$path" in h.operations.calls)
        assertTrue("directory:sync/retained" in h.operations.calls)
        h.data.put("keep prior evidence", path)
        assertFailsWith<SyncError.InvalidState> { h.pending.retainHeld(request) }
        assertEquals("keep prior evidence", h.data.text(path))
        assertContentEquals(exact, h.data.read("sync/push.json"))
    }

    @Test fun retainedFlushFailureLeavesActiveIntentAvailableForSafeRetry() {
        val h = PushHarness().seed(3)
        val request = request(h)
        h.pending.save(request)
        val exact = h.data.read("sync/push.json")
        h.operations.onOperation = { if (it.startsWith("file:sync/retained/push-")) throw SyncFileOperationError(SyncFileFailureCode.DURABILITY_FAILED) }
        assertFailsWith<SyncFileOperationError> { h.pending.retainHeld(request) }
        assertContentEquals(exact, h.data.read("sync/push.json"))
        h.operations.onOperation = null
        h.pending.retainHeld(request)
        h.pending.clear()
        assertNull(h.pending.load(h.binding))
    }
}
