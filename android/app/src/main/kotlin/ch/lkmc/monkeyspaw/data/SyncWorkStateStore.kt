package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.*
import kotlinx.serialization.json.*
import java.util.UUID

/** Atomic private publication and checked flushes precede every OS enqueue. Corruption fails closed. */
internal class SyncWorkStateStore(private val files: StateStore, private val flush: SyncFileFlushing) : SyncWorkStore {
    override fun read(): SyncWorkState {
        val bytes = try { files.read(PATH) } catch (error: StoreError) {
            if (error == StoreError.NotFound) return SyncWorkState()
            throw error
        }
        try {
            require(bytes.size <= CAP)
            val json = Json.parseToJsonElement(bytes.decodeToString(throwOnInvalidSequence = true)).jsonObject
            require(json.keys == FIELDS)
            fun number(key: String) = json.getValue(key).jsonPrimitive.let { require(!it.isString); it.long }
            fun uuid(key: String) = json.getValue(key).jsonPrimitive.let {
                require(it.isString && UUID.fromString(it.content).toString() == it.content)
                it.content
            }
            require(number("version") == 1L)
            val state = SyncWorkState(uuid("generation"), if (json["connection"] == JsonNull) null else uuid("connection"),
                number("trigger"), number("consumed"), SyncWorkReason.valueOf(json.getValue("reason").jsonPrimitive.content),
                number("due_at"), number("retries").also { require(it in 0..SyncWorkPolicy.MAX_RETRIES) }.toInt(),
                json.getValue("needs_sign_in").jsonPrimitive.let { require(!it.isString); it.boolean })
            require(state.trigger >= state.consumed && state.consumed >= 0 && state.dueAt >= 0)
            require(state.pending == (state.reason != SyncWorkReason.NONE))
            require(state.connection != null || !state.pending && !state.needsSignIn)
            return state
        } catch (_: Exception) { throw StoreError.IOFailure }
    }

    override fun write(value: SyncWorkState) {
        val bytes = buildJsonObject {
            put("version", 1)
            put("generation", value.generation)
            put("connection", value.connection?.let(::JsonPrimitive) ?: JsonNull)
            put("trigger", value.trigger)
            put("consumed", value.consumed)
            put("reason", value.reason.name)
            put("due_at", value.dueAt)
            put("retries", value.retries)
            put("needs_sign_in", value.needsSignIn)
        }.toString().encodeToByteArray()
        files.writePrivate(bytes, PATH)
        flush.flushFile(PATH)
        flush.flushDirectory("sync")
        flush.flushDirectory(null)
    }

    private companion object {
        const val PATH = "sync/work.json"
        const val CAP = 4096
        val FIELDS = setOf("version", "generation", "connection", "trigger", "consumed", "reason", "due_at", "retries", "needs_sign_in")
    }
}
