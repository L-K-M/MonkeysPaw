package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.domain.ranking.Utf8Order
import ch.lkmc.monkeyspaw.core.ports.*
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.ResolverStyle
import java.util.Locale
import kotlinx.serialization.json.*

/** Exact previous bytes; unexpected files survive retention and move verbatim with their identity. */
class HistoryStore internal constructor(private val files: StateStore, private val mutations: MutationBoundary) : PromptKeyedStore {
    private val syncWriteGates = SyncKeyedWriteGates()
    private val formatter = DateTimeFormatter.ofPattern("uuuuMMdd'T'HHmmss.SSS'Z'", Locale.ROOT)
        .withResolverStyle(ResolverStyle.STRICT).withZone(ZoneOffset.UTC)
    private val filenamePattern = Regex("[0-9]{8}T[0-9]{6}\\.[0-9]{3}Z-[0-9]{6}\\.md")

    fun revisions(identity: PromptIdentity): List<HistoryRevision> = mutations.run {
        syncWriteGates.requireEditable()
        val prefix = directory(identity) + "/"
        files.listFiles().mapNotNull { file ->
            if (!file.relativePath.startsWith(prefix)) return@mapNotNull null
            val filename = file.relativePath.removePrefix(prefix)
            parts(filename)?.let { HistoryRevision(identity, filename, it.first) }
        }.sortedByDescending { it.filename }
    }

    internal fun snapshot(bytes: ByteArray, identity: PromptIdentity, at: Instant): HistoryRevision = mutations.run {
        syncWriteGates.requireEditable()
        if (at.epochSecond < 0 || at.epochSecond >= Limits.historyMaxUnixSeconds) throw LibraryError.InvalidTimestamp
        val timestamp = formatter.format(at)
        if (timestamp.length != 20) throw LibraryError.InvalidTimestamp
        val sequence = (revisions(identity).filter { it.filename.startsWith("$timestamp-") }
            .mapNotNull { parts(it.filename)?.second }.maxOrNull() ?: -1) + 1
        if (sequence > Limits.historySequenceMax) throw LibraryError.HistoryCollisionLimitReached
        val filename = timestamp + "-" + sequence.toString().padStart(6, '0') + ".md"
        try { files.create(bytes, directory(identity) + "/" + filename) }
        catch (_: StoreError.AlreadyExists) { throw LibraryError.HistoryCollisionLimitReached }
        HistoryRevision(identity, filename, parseTimestamp(timestamp))
    }

    fun read(revision: HistoryRevision): ByteArray = mutations.run {
        syncWriteGates.requireEditable()
        val path = path(revision)
        try { files.read(path) } catch (_: StoreError.NotFound) { throw LibraryError.RevisionNotFound }
    }

    internal fun remove(revision: HistoryRevision) = mutations.run {
        syncWriteGates.requireEditable()
        val path = path(revision)
        try { files.delete(path) } catch (_: StoreError.NotFound) { throw LibraryError.RevisionNotFound }
        // Older desktop histories may carry attribution sidecars; keep them if revision deletion fails.
        if (files.stamp("$path.json") != null) {
            try { files.delete("$path.json") } catch (_: StoreError.NotFound) { /* Concurrent cleanup. */ }
        }
    }

    internal fun prune(identity: PromptIdentity) = mutations.run {
        revisions(identity).drop(Limits.historyCapPerPrompt).asReversed().forEach(::remove)
    }

    override fun migrateKey(source: PromptIdentity, destination: PromptIdentity): KeyMigration = mutations.run {
        syncWriteGates.requireEditable()
        val sourcePrefix = directory(source) + "/"
        val targetPrefix = directory(destination) + "/"
        if (source == destination) return@run KeyMigration.UNCHANGED
        val all = files.listFiles()
        val sources = all.filter { it.relativePath.startsWith(sourcePrefix) }.sortedWith { a, b ->
            Utf8Order.compare(a.relativePath.encodeToByteArray(), b.relativePath.encodeToByteArray())
        }
        if (sources.isEmpty()) return@run KeyMigration.UNCHANGED
        if (all.any { it.relativePath.startsWith(targetPrefix) }) throw LibraryError.KeyedStateConflict
        val moved = mutableListOf<Pair<String, String>>()
        try {
            for (file in sources) {
                val target = targetPrefix + file.relativePath.removePrefix(sourcePrefix)
                files.move(file.relativePath, target)
                moved.add(file.relativePath to target)
            }
        } catch (error: Exception) {
            var recovered = true
            for ((old, target) in moved.asReversed()) {
                try { files.move(target, old) } catch (_: Exception) { recovered = false }
            }
            if (!recovered) throw LibraryError.RecoveryRequired
            if (error is StoreError.AlreadyExists) throw LibraryError.KeyedStateConflict
            throw error
        }
        KeyMigration.MIGRATED
    }

    internal val sync: SyncKeyedStore = object : SyncKeyedStore {
        override val syncKind = SyncKeyedStoreKind.HISTORY
        override fun bindSyncWriteGate(gate: SyncRecoveryGate) = mutations.run { syncWriteGates.bind(gate) }

        override fun prepareSyncMigration(source: PromptIdentity, destination: PromptIdentity,
                                          rebindingHeadTo: ByteArray?, originalBytes: ByteArray?): List<SyncKeyedMigration> = mutations.run {
            if (source == destination) return@run emptyList()
            val prefix = directory(source) + "/"
            val target = directory(destination) + "/"
            val all = files.listFiles()
            val originals = all.filter { it.relativePath.startsWith(prefix) }
            if (originals.isEmpty()) return@run emptyList()
            // A regular file at the identity directory also blocks publication before the ID rewrite.
            if (all.any { it.relativePath == directory(destination) || it.relativePath.startsWith(target) } ||
                occupiedDirectoryLeaf(directory(destination))) throw LibraryError.KeyedStateConflict
            originals.sortedWith { a, b ->
                Utf8Order.compare(a.relativePath.encodeToByteArray(), b.relativePath.encodeToByteArray())
            }.map { file ->
                val original = files.read(file.relativePath)
                if (files.stamp(file.relativePath) != file.stamp) throw LibraryError.Conflict
                if (original.size > Limits.syncRecordMaxBytes) throw SyncError.InvalidState
                val suffix = file.relativePath.removePrefix(prefix)
                val replacement = if (suffix == "head.json" && rebindingHeadTo != null && originalBytes != null) {
                    reboundHead(original, originalBytes, rebindingHeadTo)
                } else original
                SyncKeyedMigration(syncKind, SyncKeyedMigration.Change.File(
                    SyncKeyedFileMove(file.relativePath, target + suffix, original, replacement)))
            }
        }

        override fun applySyncMigration(migration: SyncKeyedMigration, operations: SyncFileFlushing) = mutations.run {
            checkedMove(migration).apply(files, operations)
        }

        override fun isSyncMigrationUnstarted(migration: SyncKeyedMigration): Boolean = mutations.run {
            checkedMove(migration).isUnstarted(files)
        }

        private fun checkedMove(migration: SyncKeyedMigration): SyncKeyedFileMove {
            migration.validate()
            if (migration.store != syncKind) throw SyncError.InvalidState
            return (migration.change as? SyncKeyedMigration.Change.File)?.move ?: throw SyncError.InvalidState
        }
    }

    private fun occupiedDirectoryLeaf(path: String): Boolean = try { files.stamp(path) != null }
        catch (_: StoreError.NotRegularFile) { false } // An existing empty history directory is reusable.

    /** Swift version-1 sidecars: only current head attribution follows adoption's new bytes. */
    private fun reboundHead(record: ByteArray, original: ByteArray, replacement: ByteArray): ByteArray {
        val root = try {
            StateJson.read(record).also { root ->
                fun text(key: String) = StateJson.text(root[key] ?: throw LibraryError.InvalidProvenance)
                val timestamp = text("timestamp")
                if (text("origin") != "llm" || text("providerHost").isEmpty() || text("model").isEmpty() ||
                    !Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z").matches(timestamp)) {
                    throw LibraryError.InvalidProvenance
                }
                Instant.parse(timestamp)
                val usage = root["usage"]
                if (usage != null && usage != JsonNull) {
                    val fields = StateJson.fields(usage)
                    for (key in listOf("inputTokens", "outputTokens")) {
                        val count = fields[key] as? JsonPrimitive ?: throw LibraryError.InvalidProvenance
                        if (count.isString || count.content.toLongOrNull()?.let { it < 0 } != false) throw LibraryError.InvalidProvenance
                    }
                }
                text("contentSHA256")
            }
        } catch (_: Exception) { throw LibraryError.InvalidProvenance }
        if (StateJson.text(root.getValue("contentSHA256")) != SyncHash.of(original).rawValue) return record
        return StateJson.objectOf(root + ("contentSHA256" to JsonPrimitive(SyncHash.of(replacement).rawValue)))
            .toString().encodeToByteArray(throwOnInvalidSequence = true)
    }

    private fun directory(identity: PromptIdentity): String = "history/" + identity.storageKey

    private fun path(revision: HistoryRevision): String {
        if (parts(revision.filename) == null) throw LibraryError.RevisionNotFound
        return directory(revision.identity) + "/" + revision.filename
    }

    private fun parts(filename: String): Pair<Instant, Int>? {
        if (!filenamePattern.matches(filename)) return null
        return try {
            val timestamp = filename.substring(0, 20)
            val instant = parseTimestamp(timestamp)
            if (formatter.format(instant) != timestamp) null else instant to filename.substring(21, 27).toInt()
        } catch (_: Exception) { null }
    }

    private fun parseTimestamp(timestamp: String): Instant = LocalDateTime.parse(timestamp, formatter).toInstant(ZoneOffset.UTC)
}
