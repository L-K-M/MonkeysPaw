package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.llm.ProviderProfileID
import ch.lkmc.monkeyspaw.core.domain.llm.SecretAccount
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlin.test.*

class SyncAccountStoreTest {
    private val accountPath = "sync/account.json"
    private val bindingPath = "sync/binding.json"
    private val v = SyncTestValues

    @Test fun versionOneConnectionAndDeviceFactoryRoundTripWithoutSecrets() {
        val files = MemoryStore()
        val flushes = SyncFlushes()
        val store = SyncAccountStore(files, flushes)
        assertNull(store.loadAccount())
        val account = v.account()
        store.setAccount(account)
        assertEquals(account, store.cachedAccount)
        assertEquals(account, SyncAccountStore(files, flushes).loadAccount())
        assertTrue(files.isPrivate(accountPath))
        assertEquals("device:${v.uuid}", account.secretAccount.rawValue)
        assertEquals(SecretAccount.device(v.uuid), account.secretAccount)
        assertNotEquals(SecretAccount.provider(ProviderProfileID.parse(v.uuid.toString())), account.secretAccount)
        assertEquals(listOf("file:$accountPath", "directory:sync", "directory:<root>"), flushes.calls)
        val expected = """{"account":{"connection_id":"12345678-1234-abcd-9876-123456789abc","device_id":"01ARZ3NDEKTSV4RRFFQ69G5FB0","device_name":"Android","server_url":"https:\/\/example.test\/paw","user_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","username":"user_1"},"activation":"enabled","cleanup_connections":[],"version":1}"""
        assertContentEquals(expected.encodeToByteArray(), files.read(accountPath))
        store.updateBinding(v.ownership().root) { v.ownership() }
        SyncStateStore(files, flushes).update(v.binding()) { v.state() }
        for (file in files.listFiles()) {
            assertTrue(files.isPrivate(file.relativePath))
            val text = files.text(file.relativePath)
            for (key in listOf("device_token", "invite_token", "password", "Authorization", "Bearer ")) assertFalse(key in text)
        }
        // This slice has no credential input. Runtime secret lifecycle scans belong to Z14/Z27.
    }

    @Test fun legacyActivationNullSignOutAndCleanupReferencesSurviveRestart() {
        val files = MemoryStore()
        v.put(files, accountPath, syncObject("version" to wireLong(1), "account" to SyncAccountJson.account(v.account())))
        val store = SyncAccountStore(files, SyncFlushes())
        assertEquals(SyncAccountActivation.ENABLED, store.loadConnection().activation)
        val old = SyncIdentifiers.uuid("00000000-0000-0000-0000-000000000001")
        store.setAccount(v.account(), SyncAccountActivation.INACTIVE, retiring = listOf(old, old))
        store.setAccount(v.account(), SyncAccountActivation.ENABLED)
        assertEquals(listOf(old), store.loadConnection().cleanupConnections)
        store.disableAutomaticResume()
        assertEquals(SyncAccountActivation.INACTIVE, SyncAccountStore(files, SyncFlushes()).loadConnection().activation)
        store.setAccount(null)
        assertEquals(WireValue.Null, v.raw(files, accountPath).required("account"))
        assertNull(SyncAccountStore(files, SyncFlushes()).loadAccount())
        assertEquals(listOf(old), store.loadConnection().cleanupConnections)
        store.finishSecretCleanup(old)
        assertTrue(store.loadConnection().cleanupConnections.isEmpty())
    }

    @Test fun ownershipHoldsAndByteDistinctRootsSurviveSignOutAndAccountChanges() {
        val files = MemoryStore()
        val store = SyncAccountStore(files, SyncFlushes())
        val first = v.ownership("/Caf\u00e9")
        val second = v.ownership("/Cafe\u0301")
        store.setAccount(v.account())
        store.updateBinding(first.root) { first }
        store.updateBinding(second.root) { second }
        store.setAccount(null)
        val restart = SyncAccountStore(files, SyncFlushes())
        assertEquals(first, restart.binding(first.root))
        assertEquals(second, restart.binding(second.root))
        assertNotEquals(first.root, second.root)
        val other = v.account().copy(identity = v.accountIdentity(userID = v.otherUser))
        restart.setAccount(other)
        assertEquals(first, restart.binding(first.root))
        for (hold in first.holds) {
            assertTrue(first.isHeld(hold.identity, "Renamed.md", SyncHash.of(byteArrayOf(7))))
            assertTrue(first.isHeld(PromptIdentity.Assigned(v.device), hold.path, SyncHash.of(byteArrayOf(7))))
            assertTrue(first.isHeld(PromptIdentity.at("Renamed.md"), "Renamed.md", hold.contentHash))
        }
        restart.updateBinding(first.root) { it!!.copy(owner = other.identity, holds = it.holds.drop(1)) }
        assertEquals(first.managedFolders, restart.binding(first.root)!!.managedFolders)
        assertEquals(first.holds.drop(1), SyncAccountStore(files, SyncFlushes()).binding(first.root)!!.holds)
        assertFailsWith<SyncError.BindingMismatch> { restart.updateBinding(first.root) { second } }
    }

    @Test fun unknownFieldsFollowRetainedArrayIdentitiesAndMapEntriesAcrossReorderAndRemoval() {
        val files = MemoryStore()
        val first = v.ownership()
        val other = v.ownership("/other")
        val raw = SyncAccountJson.binding(first).withText("future_root", "kept")
            .edit("owner") { it.withText("future_owner", "kept") }
            .edit("managed_folders") { it.edit(v.group.rawValue) { folder -> folder.withText("future_folder", "kept") } }
        val holds = raw.required("holds").arrayValue().mapIndexed { index, item ->
            if (index == 0) item.objectValue().withText("future_hold", "kept") else item
        }
        v.put(files, bindingPath, syncObject("version" to wireLong(1), "future_binding" to wireBoolean(true),
            "libraries" to WireValue.ArrayValue(listOf(SyncAccountJson.binding(other), raw.setting("holds", WireValue.ArrayValue(holds))))))
        v.put(files, accountPath, syncObject("version" to wireLong(1), "future" to wireBoolean(true),
            "account" to SyncAccountJson.account(v.account()).withText("future_account", "kept")))
        val store = SyncAccountStore(files, SyncFlushes())
        store.setAccount(v.account())
        store.updateBinding(first.root) { it!!.copy(holds = it.holds.reversed()) }
        assertEquals("kept", v.raw(files, accountPath).required("account").objectValue().text("future_account"))
        val bindings = v.raw(files, bindingPath)
        assertEquals(wireBoolean(true), bindings.required("future_binding"))
        val saved = bindings.required("libraries").arrayValue().map { it.objectValue() }.single { it.text("library_root") == first.root.path }
        assertEquals("kept", saved.text("future_root"))
        assertEquals("kept", saved.required("owner").objectValue().text("future_owner"))
        assertEquals("kept", saved.required("holds").arrayValue()[1].objectValue().text("future_hold"))
        assertEquals("kept", saved.required("managed_folders").objectValue().required(v.group.rawValue).objectValue().text("future_folder"))
        store.updateBinding(first.root) { it!!.copy(holds = emptyList(), managedFolders = emptyMap()) }
        assertTrue(store.binding(first.root)!!.holds.isEmpty())
        assertEquals(other, store.binding(other.root))
        store.setAccount(null)
        assertEquals(WireValue.Null, v.raw(files, accountPath).required("account"))
        store.resetBindings()
        assertTrue(v.raw(files, bindingPath).required("libraries").arrayValue().isEmpty())
    }

    @Test fun independentReadHealthAndExplicitSignOutRecoveryDoNotResetOwnership() {
        val files = MemoryStore()
        val store = SyncAccountStore(files, SyncFlushes())
        val ownership = v.ownership()
        store.setAccount(v.account())
        store.updateBinding(ownership.root) { ownership }
        files.put("{bad", accountPath)
        val corruptConnection = SyncAccountStore(files, SyncFlushes())
        assertEquals(ownership, corruptConnection.binding(ownership.root))
        assertFailsWith<SyncError.CorruptFile> { corruptConnection.updateBinding(ownership.root) { ownership } }
        corruptConnection.resetAccount()
        assertEquals(ownership, corruptConnection.binding(ownership.root))
        corruptConnection.setAccount(v.account())
        val bytes = files.read(bindingPath)
        files.put("{bad", bindingPath)
        val corruptOwnership = SyncAccountStore(files, SyncFlushes())
        assertEquals(v.account(), corruptOwnership.connectionForSignOut().account)
        assertFailsWith<SyncError.CorruptFile> { corruptOwnership.loadAccount() }
        corruptOwnership.saveInactive(null, listOf(v.uuid))
        assertNull(corruptOwnership.connectionForSignOut().account)
        assertEquals("{bad", files.text(bindingPath))
        assertEquals(SyncError.CorruptFile, corruptOwnership.readOnlyError)
        files.put(bytes, bindingPath)
        assertEquals(ownership, SyncAccountStore(files, SyncFlushes()).binding(ownership.root))
    }

    @Test fun writeAndEveryFlushFailurePreserveBothCachesAndBlockUnsafeEdits() {
        for (bindingWrite in listOf(false, true)) for (offset in 0..3) {
            val files = MemoryStore()
            val flushes = SyncFlushes()
            val store = SyncAccountStore(files, flushes)
            val ownership = v.ownership()
            store.setAccount(v.account())
            store.updateBinding(ownership.root) { ownership }
            val beforeAccount = files.read(accountPath)
            val beforeBinding = files.read(bindingPath)
            if (offset == 0) files.fault = { op, _ -> if (op == MemoryStore.Operation.PRIVATE_WRITE) StoreError.IOFailure else null }
            else flushes.failAt = flushes.calls.size + offset
            val expected = if (offset == 0) SyncError.WriteFailed(StoreError.IOFailure) else SyncError.DurabilityUncertain
            assertEquals(expected, assertFailsWith<SyncError> {
                if (bindingWrite) store.updateBinding(ownership.root) { it!!.copy(holds = emptyList()) }
                else store.setAccount(null)
            })
            assertEquals(v.account(), store.cachedAccount)
            assertEquals(listOf(ownership), store.cachedBindings)
            if (offset == 0) {
                assertNull(store.readOnlyError)
                assertContentEquals(beforeAccount, files.read(accountPath))
                assertContentEquals(beforeBinding, files.read(bindingPath))
            } else {
                assertEquals(SyncError.DurabilityUncertain, store.readOnlyError)
                assertFailsWith<SyncError.DurabilityUncertain> { store.loadAccount() }
                assertFailsWith<SyncError.DurabilityUncertain> { store.setAccount(v.account()) }
            }
        }
    }

    @Test fun malformedActivationBindingAndVersionsFailClosedWithFixedErrors() {
        val account = SyncAccountJson.account(v.account())
        val invalidConnections = listOf(
            syncObject("version" to wireLong(1)),
            syncObject("version" to wireLong(1), "account" to WireValue.Null, "activation" to wireString("enabled")),
            syncObject("version" to wireLong(1), "account" to account, "activation" to wireString("bad")),
            syncObject("version" to wireLong(1), "account" to account,
                "cleanup_connections" to WireValue.ArrayValue(listOf(wireString(v.uuid.toString())))),
            syncObject("version" to wireLong(1), "account" to account,
                "cleanup_connections" to WireValue.ArrayValue(listOf(wireString(v.uuid.toString()), wireString(v.uuid.toString())))),
        )
        val binding = SyncAccountJson.binding(v.ownership())
        val invalidBindings = listOf(
            listOf(binding, binding),
            listOf(binding.withText("library_root", "relative")),
            listOf(binding.setting("holds", WireValue.ArrayValue(binding.required("holds").arrayValue().let { it + it.first() }))),
            listOf(binding.edit("managed_folders") { it.withText("invalid-id", "invalid") }),
        ).map { syncObject("version" to wireLong(1), "libraries" to WireValue.ArrayValue(it)) }
        for ((path, values) in listOf(accountPath to invalidConnections, bindingPath to invalidBindings)) {
            for (raw in values) {
                val files = MemoryStore()
                v.put(files, path, raw)
                val bytes = files.read(path)
                val store = SyncAccountStore(files, SyncFlushes())
                assertEquals(SyncError.CorruptFile, store.readOnlyError)
                assertFailsWith<SyncError.CorruptFile> { store.setAccount(v.account()) }
                assertContentEquals(bytes, files.read(path))
            }
            for ((source, error) in listOf("{bad" to SyncError.CorruptFile, "{\"version\":8}" to SyncError.FutureVersion(8),
                "{\"version\":0}" to SyncError.UnsupportedVersion(0))) {
                val files = MemoryStore()
                files.put(source, path)
                val store = SyncAccountStore(files, SyncFlushes())
                assertEquals(error, store.readOnlyError)
                assertEquals(error, assertFailsWith<SyncError> { store.loadAccount() })
                if (path == accountPath) store.resetAccount() else store.resetBindings()
                assertNull(store.readOnlyError)
                assertNull(store.loadAccount())
            }
        }
    }
}
