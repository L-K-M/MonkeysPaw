package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.ports.SyncFileOperationError
import kotlinx.serialization.json.*
import java.nio.file.Files
import java.util.UUID
import kotlin.test.*

internal class SyncWorkStateStoreTest : TemporaryFiles() {
    private fun store(io: JvmCheckedSyncIO = JvmCheckedSyncIO()): SyncWorkStateStore {
        val files = AndroidStateStore(stateDir.toFile(), isMainThread = { false }, io = io)
        return SyncWorkStateStore(files, files.syncOperations)
    }

    @Test fun `due generation trigger retry and auth stop round trip without secret path or content`() {
        val value = SyncWorkState(connection = UUID.randomUUID().toString(), trigger = 7, consumed = 5,
            reason = SyncWorkReason.RETRY, dueAt = 123_456, retries = 8, needsSignIn = true)
        store().write(value)
        assertEquals(value, store().read())
        val json = Json.parseToJsonElement(Files.readString(stateDir.resolve("sync/work.json"))).jsonObject
        assertEquals(setOf("version", "generation", "connection", "trigger", "consumed", "reason", "due_at", "retries", "needs_sign_in"), json.keys)
        assertEquals(listOf("sync/work.json"), Files.walk(stateDir).use { files ->
            files.filter { Files.isRegularFile(it) }.map { stateDir.relativize(it).toString() }.toList()
        })
    }

    @Test fun `corrupt future malformed and inconsistent state fails closed without rewriting`() {
        val original = SyncWorkState(connection = UUID.randomUUID().toString(), trigger = 1,
            reason = SyncWorkReason.SAVE, dueAt = 3000)
        store().write(original)
        val good = Files.readString(stateDir.resolve("sync/work.json"))
        val cases = listOf("broken", good.replace("\"version\":1", "\"version\":99"),
            good.replace("\"consumed\":0", "\"consumed\":2"), good.replace("\"retries\":0", "\"retries\":9"),
            good.replace("\"SAVE\"", "\"NONE\""), good.replace("\"due_at\":3000", "\"due_at\":-1"),
            good.replace(original.generation, "not-a-uuid"), good.dropLast(1) + ",\"token\":\"synthetic\"}",
            " ".repeat(4097))
        for (invalid in cases) {
            Files.writeString(stateDir.resolve("sync/work.json"), invalid)
            assertFailsWith<StoreError> { store().read() }
            assertEquals(invalid, Files.readString(stateDir.resolve("sync/work.json")))
        }
    }

    @Test fun `missing state does not create files and publication reports checked durability failure`() {
        assertNull(store().read().connection)
        assertFalse(Files.exists(stateDir.resolve("sync/work.json")))
        val io = JvmCheckedSyncIO()
        io.onFlush = { throw java.io.IOException("Synthetic flush failure") }
        assertFailsWith<SyncFileOperationError> { store(io).write(SyncWorkState()) }
    }
}
