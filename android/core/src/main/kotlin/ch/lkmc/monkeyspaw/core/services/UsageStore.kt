package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.ports.*
import kotlinx.serialization.json.JsonArray
import java.time.Instant

/** Unix-second JSON events stay in recording order, including repeated and earlier timestamps. */
class UsageStore internal constructor(
    private val files: StateStore,
    private val clock: Clock,
    private val mutations: MutationBoundary,
) : PromptKeyedStore {
    private val cached = mutableMapOf<PromptIdentity, List<Instant>>()
    internal var onRecord: (PromptIdentity, List<Instant>) -> Unit = { _, _ -> }

    fun useEvents(identity: PromptIdentity): List<Instant> = mutations.run {
        read(path(identity)).also { cached[identity] = it }.toList()
    }

    fun recordUse(identity: PromptIdentity, at: Instant? = null): List<Instant> = mutations.run {
        val path = path(identity)
        val events = (read(path) + (at ?: clock.now())).takeLast(Limits.usageEventCap)
        files.write(StateJson.encode("events", JsonArray(events.map(StateJson::number))), path)
        cached[identity] = events
        onRecord(identity, events.toList())
        events.toList()
    }

    internal fun cachedEvents(identity: PromptIdentity): List<Instant>? = cached[identity]

    override fun migrateKey(source: PromptIdentity, destination: PromptIdentity): KeyMigration = mutations.run {
        val sourcePath = path(source)
        val targetPath = path(destination)
        if (source == destination || files.stamp(sourcePath) == null) return@run KeyMigration.UNCHANGED
        if (files.stamp(targetPath) != null) throw LibraryError.KeyedStateConflict
        try { files.move(sourcePath, targetPath) }
        catch (_: StoreError.AlreadyExists) { throw LibraryError.KeyedStateConflict }
        val events = cached.remove(source)
        if (events != null) cached[destination] = events else cached.remove(destination)
        KeyMigration.MIGRATED
    }

    private fun path(identity: PromptIdentity): String = "usage/" + identity.storageKey

    private fun read(path: String): List<Instant> {
        val bytes = try { files.read(path) } catch (_: StoreError.NotFound) { return emptyList() }
        val events = StateJson.read(bytes)["events"] as? JsonArray ?: throw LibraryError.OperationFailed
        if (events.size > Limits.usageEventCap) throw LibraryError.OperationFailed
        return events.map(StateJson::instant)
    }
}
