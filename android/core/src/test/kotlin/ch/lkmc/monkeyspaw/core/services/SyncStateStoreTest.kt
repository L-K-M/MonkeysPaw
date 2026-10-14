package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathIssueCode
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlin.test.*

class SyncStateStoreTest {
    private val path = "sync/state.json"
    private val v = SyncTestValues

    @Test fun versionOneRoundTripRestartAndCheckedPrivatePublication() {
        val files = MemoryStore()
        val flushes = SyncFlushes()
        val store = SyncStateStore(files, flushes)
        val state = v.state()
        assertNull(store.load(state.binding))
        assertTrue(flushes.calls.isEmpty())
        store.update(state.binding) { state }
        assertEquals(state, store.snapshot.value)
        assertEquals(state, SyncStateStore(files, flushes).load(state.binding))
        assertEquals(Long.MAX_VALUE, store.snapshot.value!!.prompts[v.groupID]!!.rev)
        assertTrue(files.isPrivate(path))
        assertEquals(listOf("file:$path", "directory:sync", "directory:<root>"), flushes.calls)
        assertEquals(listOf(path), files.listFiles().map { it.relativePath })
    }

    @Test fun knownStateBytesMatchFoundationVersionOneProfile() {
        val files = MemoryStore()
        val store = SyncStateStore(files, SyncFlushes())
        val state = SyncState(v.binding(), cursors = mapOf(v.userScope to "opaque"))
        store.update(state.binding) { state }
        val expected = """{"cursors":{"user:01ARZ3NDEKTSV4RRFFQ69G5FAV":"opaque"},"database_id":null,"favorites":{},"groups":{},"library_root":"\/library","prompts":{},"server_url":"https:\/\/example.test\/paw","user_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","version":1}"""
        assertContentEquals(expected.encodeToByteArray(), files.read(path))
        files.put(expected, path)
        assertEquals(state, SyncStateStore(files, SyncFlushes()).load(state.binding))
    }

    @Test fun pendingLocalBaselineAndIdentityMigration() {
        val files = MemoryStore()
        val store = SyncStateStore(files, SyncFlushes())
        val original = v.state()
        val local = PromptIdentity.at("Cafe\u0301.md")
        val prompt = SyncPromptState(v.groupScope, "Cafe\u0301.md", 0, lastError = original.prompts[v.personalID]!!.lastError)
        store.update(original.binding) { original.copy(prompts = original.prompts + (local to prompt)).applyGroupFavorite(true, local) }
        val loaded = SyncStateStore(files, SyncFlushes()).load(original.binding)!!
        assertEquals(prompt, loaded.prompts[local])
        assertNull(loaded.prompts[local]!!.canonicalHash)
        assertEquals(true, loaded.favorites[local])
        store.update(original.binding) {
            it.copy(prompts = (it.prompts - local) + (PromptIdentity.Assigned(v.device) to prompt),
                favorites = (it.favorites - local) + (PromptIdentity.Assigned(v.device) to true))
        }
        assertNull(store.load(original.binding)!!.prompts[local])
        assertEquals(prompt, store.load(original.binding)!!.prompts[PromptIdentity.Assigned(v.device)])
        assertFailsWith<SyncError.InvalidState> { SyncPromptState(v.userScope, "Pending.md", 0, v.hash) }
        assertFailsWith<SyncError.InvalidState> { SyncPromptState(v.userScope, "Pending.md", 1) }
        assertFailsWith<SyncError.InvalidState> { SyncPromptState(v.userScope, "Cafe\u0301.md", 1, v.hash) }
        assertFailsWith<SyncError.InvalidState> { original.copy(prompts = original.prompts + (local to original.prompts.getValue(v.groupID))) }
    }

    @Test fun threeWayGroupFavoriteAndAbsentArbitraryTargets() {
        val files = MemoryStore()
        val store = SyncStateStore(files, SyncFlushes())
        val state = v.state()
        store.update(state.binding) { state }
        var expected: Boolean? = true
        for (favorite in listOf(null, false, null, true, null)) {
            store.update(state.binding) { it.applyGroupFavorite(favorite, v.groupID) }
            if (favorite != null) expected = favorite.takeIf { it }
            assertEquals(expected, SyncStateStore(files, SyncFlushes()).load(state.binding)!!.favorites[v.groupID])
            assertEquals(state.prompts, store.snapshot.value!!.prompts)
        }
        for (id in listOf(v.personalID, PromptIdentity.Assigned(v.device), PromptIdentity.Local("bad"))) {
            assertSame(state, state.applyGroupFavorite(null, id))
            for (favorite in listOf(false, true)) assertFailsWith<SyncError.InvalidState> { state.applyGroupFavorite(favorite, id) }
        }
    }

    @Test fun unknownNestedFieldsPersistWithoutResurrectingRemovedMapsOrClearedOptionals() {
        val files = MemoryStore()
        val state = v.state()
        val raw = SyncStateJson.codec.encode(state)
            .setting("future", syncObject("fraction" to WireValue.Number("1.25"), "null" to WireValue.Null))
            .edit("groups") { groups -> groups.edit(v.group.rawValue) { it.withText("future_group", "kept") } }
            .edit("prompts") { prompts -> prompts.edit(v.personal.rawValue) { prompt ->
                prompt.withText("future_prompt", "kept").edit("origin") { it.withText("future_origin", "kept") }
                    .edit("last_error") { error -> error.edit("fingerprint") { it.withText("future_fingerprint", "kept") } }
            } }
        // The wire encoder intentionally accepts only integers, unlike supported storage extensions.
        files.put(rawJson(raw), path)
        val store = SyncStateStore(files, SyncFlushes())
        store.update(state.binding) { it.copy(cursors = mapOf(v.userScope to "new")) }
        val updated = v.raw(files, path)
        assertEquals(raw.fields["future"], updated.fields["future"])
        val prompt = updated.required("prompts").objectValue().required(v.personal.rawValue).objectValue()
        assertEquals("kept", prompt.text("future_prompt"))
        assertEquals("kept", prompt.required("origin").objectValue().text("future_origin"))
        assertEquals("kept", prompt.required("last_error").objectValue().required("fingerprint").objectValue().text("future_fingerprint"))
        assertEquals("kept", updated.required("groups").objectValue().required(v.group.rawValue).objectValue().text("future_group"))
        store.update(state.binding) {
            it.copy(databaseID = null, cursors = emptyMap(),
                prompts = it.prompts + (v.personalID to SyncPromptState(v.userScope, "Pending.md", 0)))
                .applyGroupFavorite(false, v.groupID)
        }
        val reloaded = SyncStateStore(files, SyncFlushes()).load(state.binding)!!
        assertEquals(store.snapshot.value, reloaded)
        assertNull(reloaded.databaseID)
        assertNull(reloaded.prompts[v.personalID]!!.canonicalHash)
        assertNull(reloaded.prompts[v.personalID]!!.lastError)
        assertNull(reloaded.prompts[v.personalID]!!.origin)
        store.update(state.binding) { it.copy(groups = emptyMap(), prompts = emptyMap(), favorites = emptyMap()) }
        val pruned = v.raw(files, path)
        for (key in listOf("groups", "prompts", "favorites", "cursors")) assertTrue(pruned.required(key).objectValue().fields.isEmpty())
    }

    @Test fun originTransitionRemovesOnlyObsoletePromptID() {
        val files = MemoryStore()
        val state = v.state()
        val raw = SyncStateJson.codec.encode(state).edit("prompts") { it.edit(v.personal.rawValue) { prompt ->
            prompt.edit("origin") { origin -> origin.withText("extension", "kept") }
        } }
        v.put(files, path, raw)
        val store = SyncStateStore(files, SyncFlushes())
        store.update(state.binding) {
            it.copy(prompts = it.prompts + (v.personalID to it.prompts.getValue(v.personalID).copy(origin = SyncPromptOrigin.Rescued)))
        }
        val origin = v.raw(files, path).required("prompts").objectValue().required(v.personal.rawValue).objectValue().required("origin").objectValue()
        assertEquals(setOf("kind", "extension"), origin.fields.keys)
        assertEquals("kept", origin.text("extension"))
        assertEquals(SyncPromptOrigin.Rescued, store.load(state.binding)!!.prompts[v.personalID]!!.origin)
    }

    @Test fun accountServerAndExactRootMismatchLeaveBytesUntouched() {
        val files = MemoryStore()
        val store = SyncStateStore(files, SyncFlushes())
        val state = v.state()
        store.update(state.binding) { state }
        val bytes = files.read(path)
        for (binding in listOf(v.binding("/other"), v.binding(account = v.accountIdentity(userID = v.otherUser)),
            v.binding(account = v.accountIdentity("https://other.test/paw")))) {
            assertFailsWith<SyncError.BindingMismatch> { store.load(binding) }
            assertFailsWith<SyncError.BindingMismatch> { store.update(binding) { it } }
            assertContentEquals(bytes, files.read(path))
        }
        assertEquals(state, store.load(state.binding))
        assertFailsWith<SyncError.BindingMismatch> { store.update(state.binding) { SyncState(v.binding("/other")) } }
    }

    @Test fun corruptUnsupportedAndFutureRecordsStayBlockedUntilExplicitReset() {
        val inputs = listOf("{bad" to SyncError.CorruptFile, "{\"version\":2}" to SyncError.FutureVersion(2),
            "{\"version\":0}" to SyncError.UnsupportedVersion(0), "{\"version\":true}" to SyncError.CorruptFile,
            "{\"version\":1.1}" to SyncError.CorruptFile)
        for ((source, expected) in inputs) {
            val files = MemoryStore()
            files.put(source, path)
            files.put("keep", "canary.md")
            val store = SyncStateStore(files, SyncFlushes())
            assertEquals(expected, store.snapshot.error)
            assertEquals(expected, assertFailsWith<SyncError> { store.update(v.binding()) { it } })
            assertEquals(expected, assertFailsWith<SyncError> { store.recover(v.binding()) })
            assertEquals(source, files.text(path))
            store.reset(v.binding())
            assertEquals(SyncState(v.binding()), store.load(v.binding()))
            assertEquals("keep", files.text("canary.md"))
        }
    }

    @Test fun invalidNestedStorageRecordsFailClosed() {
        val raw = SyncStateJson.codec.encode(v.state())
        val mutations: List<(SyncObject) -> SyncObject> = listOf(
            { it.withText("user_id", v.user.rawValue.lowercase()) },
            { it.withText("database_id", v.uuid.toString().uppercase()) },
            { it.setting("cursors", syncObject("user:${v.otherUser.rawValue}" to wireString("opaque"))) },
            { it.setting("cursors", syncObject(v.userScope.rawValue to wireString(""))) },
            { it.edit("prompts") { p -> p.edit(v.personal.rawValue) { it.setting("canonical_hash", WireValue.Null) } } },
            { it.edit("prompts") { p -> p.edit(v.personal.rawValue) { it.setting("rev", wireLong(0)) } } },
            { it.edit("prompts") { p -> p.edit(v.personal.rawValue) { it.withText("path", "Cafe\u0301.md") } } },
            { it.edit("prompts") { p -> p.edit(v.personal.rawValue) { it.withText("scope_key", "group:${v.device.rawValue}") } } },
            { it.setting("favorites", syncObject(v.groupPrompt.rawValue to wireBoolean(false))) },
            { it.edit("prompts") { p -> p.edit(v.personal.rawValue) { it.edit("last_error") { e -> e.withText("code", "body-sentinel") } } } },
        )
        for (mutation in mutations) {
            val files = MemoryStore()
            v.put(files, path, mutation(raw))
            val bytes = files.read(path)
            val store = SyncStateStore(files, SyncFlushes())
            assertEquals(SyncError.CorruptFile, store.snapshot.error)
            assertEquals(SyncError.CorruptFile, assertFailsWith<SyncError> { store.update(v.binding()) { it } })
            assertContentEquals(bytes, files.read(path))
        }
    }

    @Test fun recordWriteCapIncludesMergedUnknownFieldsBeforeAnyMutationIO() {
        val files = MemoryStore()
        val flushes = SyncFlushes()
        val store = SyncStateStore(files, flushes)
        val state = v.state()
        store.update(state.binding) { state }
        val before = files.read(path)
        val writes = files.writes.size
        val flushCount = flushes.calls.size
        assertFailsWith<SyncError.InvalidState> {
            store.update(state.binding) { it.copy(cursors = mapOf(v.userScope to "a".repeat(Limits.syncRecordMaxBytes))) }
        }
        assertEquals(writes, files.writes.size)
        assertEquals(flushCount, flushes.calls.size)
        assertContentEquals(before, files.read(path))
        assertEquals(state, store.snapshot.value)
        assertNull(store.snapshot.error)

        val empty = SyncState(v.binding())
        val base = SyncStateJson.codec.encode(empty).withText("unknown", "")
        files.put(rawJson(base), path)
        val overhead = files.read(path).size
        val exact = rawJson(base.withText("unknown", "a".repeat(Limits.syncRecordMaxBytes - overhead)))
        assertEquals(Limits.syncRecordMaxBytes, exact.size)
        files.put(exact, path)
        val bounded = SyncStateStore(files, flushes)
        assertEquals(empty, bounded.load(empty.binding))
        bounded.update(empty.binding) { it }
        assertEquals(Limits.syncRecordMaxBytes, files.read(path).size)
        val saved = files.read(path)
        assertFailsWith<SyncError.InvalidState> { bounded.update(empty.binding) { it.copy(databaseID = v.uuid) } }
        assertContentEquals(saved, files.read(path))
        files.put(saved + byteArrayOf(32), path)
        assertEquals(SyncError.CorruptFile, SyncStateStore(files, flushes).snapshot.error)
    }

    @Test fun allIssueCodesAreDisjointAndRoundTrip() {
        val codes = PromptIssueCode.entries.map(SyncIssueCode::Content) + SyncPathIssueCode.entries.map(SyncIssueCode::Path) +
            listOf(SyncIssueCode.IDMismatch, SyncIssueCode.NotFound, SyncIssueCode.Forbidden, SyncIssueCode.PathClash, SyncIssueCode.LocalVisibility)
        assertEquals(codes.size, codes.map { it.rawValue }.toSet().size)
        for (code in codes) {
            assertEquals(code, SyncIssueCode.parse(code.rawValue))
            val state = v.state()
            val prompt = state.prompts.getValue(v.personalID)
            val next = state.copy(prompts = state.prompts + (v.personalID to prompt.copy(lastError = prompt.lastError!!.copy(code = code))))
            assertEquals(next, SyncStateJson.codec.decode(SyncStateJson.codec.encode(next)))
        }
    }

    @Test fun snapshotsOwnCollectionInputs() {
        val groups = v.state().groups.toMutableMap()
        val prompts = v.state().prompts.toMutableMap()
        val state = SyncState(v.binding(), groups = groups, prompts = prompts)
        groups.clear()
        prompts.clear()
        assertEquals(1, state.groups.size)
        assertEquals(2, state.prompts.size)
        assertFailsWith<UnsupportedOperationException> { (state.prompts as MutableMap).clear() }
    }

    private fun rawJson(value: WireValue): ByteArray {
        fun json(item: WireValue): kotlinx.serialization.json.JsonElement = when (item) {
            is WireValue.Text -> kotlinx.serialization.json.JsonPrimitive(item.value)
            is WireValue.Number -> kotlinx.serialization.json.JsonPrimitive(item.token.toBigDecimal())
            is WireValue.BooleanValue -> kotlinx.serialization.json.JsonPrimitive(item.value)
            WireValue.Null -> kotlinx.serialization.json.JsonNull
            is WireValue.ArrayValue -> kotlinx.serialization.json.JsonArray(item.values.map(::json))
            is SyncObject -> StateJson.objectOf(item.fields.mapValues { json(it.value) })
        }
        return json(value).toString().replace("/", "\\/").encodeToByteArray()
    }
}
