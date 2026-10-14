package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.library.PromptProvenance
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantTokenUsage
import ch.lkmc.monkeyspaw.core.domain.ranking.Utf8Order
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import java.security.MessageDigest
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.ResolverStyle
import java.util.Locale

/** Exact previous bytes; unexpected files survive retention and move verbatim with their identity. */
class HistoryStore internal constructor(private val files: StateStore, private val mutations: MutationBoundary) : PromptKeyedStore {
    private val formatter = DateTimeFormatter.ofPattern("uuuuMMdd'T'HHmmss.SSS'Z'", Locale.ROOT)
        .withResolverStyle(ResolverStyle.STRICT).withZone(ZoneOffset.UTC)
    private val filenamePattern = Regex("[0-9]{8}T[0-9]{6}\\.[0-9]{3}Z-[0-9]{6}\\.md")
    private val provenanceFormatter = DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT)
        .withResolverStyle(ResolverStyle.STRICT).withZone(ZoneOffset.UTC)

    fun revisions(identity: PromptIdentity): List<HistoryRevision> = mutations.run {
        val prefix = directory(identity) + "/"
        files.listFiles().mapNotNull { file ->
            if (!file.relativePath.startsWith(prefix)) return@mapNotNull null
            val filename = file.relativePath.removePrefix(prefix)
            parts(filename)?.let { HistoryRevision(identity, filename, it.first) }
        }.sortedByDescending { it.filename }
    }

    internal fun snapshot(bytes: ByteArray, identity: PromptIdentity, at: Instant): HistoryRevision = mutations.run {
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
        val path = path(revision)
        try { files.read(path) } catch (_: StoreError.NotFound) { throw LibraryError.RevisionNotFound }
    }

    internal fun remove(revision: HistoryRevision) = mutations.run {
        val path = path(revision)
        try { files.delete(path) } catch (_: StoreError.NotFound) { throw LibraryError.RevisionNotFound }
        // A failed revision deletion must leave its attribution intact.
        removeProvenance("$path.json")
    }

    internal fun headProvenance(identity: PromptIdentity, bytes: ByteArray): PromptProvenance? = mutations.run {
        provenance(directory(identity) + "/head.json", bytes)
    }

    internal fun provenance(revision: HistoryRevision, bytes: ByteArray): PromptProvenance? = mutations.run {
        provenance(path(revision) + ".json", bytes)
    }

    internal fun setHeadProvenance(provenance: PromptProvenance?, identity: PromptIdentity, bytes: ByteArray) = mutations.run {
        setProvenance(provenance, directory(identity) + "/head.json", bytes)
    }

    internal fun archiveProvenance(provenance: PromptProvenance?, revision: HistoryRevision, bytes: ByteArray) = mutations.run {
        setProvenance(provenance, path(revision) + ".json", bytes)
    }

    private fun provenance(path: String, bytes: ByteArray): PromptProvenance? {
        if (files.stamp(path) == null) return null
        // Read errors retain their type. Only readable, malformed metadata is invalid provenance.
        val stored = files.read(path)
        return try {
            val record = WireJson.parse(stored) as? WireValue.ObjectValue ?: throw LibraryError.InvalidProvenance
            val objectValue = WireObject(record)
            if (objectValue.long("version") != 1L || objectValue.string("origin") != PromptProvenance.Origin.LLM.rawValue) {
                throw LibraryError.InvalidProvenance
            }
            val timestamp = objectValue.string("timestamp")
            val date = LocalDateTime.parse(timestamp, provenanceFormatter).toInstant(ZoneOffset.UTC)
            if (provenanceFormatter.format(date) != timestamp) throw LibraryError.InvalidProvenance
            val host = objectValue.string("providerHost")
            val model = objectValue.string("model")
            if (host.isEmpty() || model.isEmpty()) throw LibraryError.InvalidProvenance
            val usage = record.fields["usage"]?.takeUnless { it == WireValue.Null }?.let {
                val value = WireObject(it)
                AssistantTokenUsage(value.long("inputTokens", minimum = 0), value.long("outputTokens", minimum = 0))
            }
            if (objectValue.string("contentSHA256") != hash(bytes)) null
            else PromptProvenance(date, host, model, usage)
        } catch (_: Exception) { throw LibraryError.InvalidProvenance }
    }

    private fun setProvenance(provenance: PromptProvenance?, path: String, bytes: ByteArray) {
        if (provenance == null) return removeProvenance(path)
        if (provenance.timestamp.epochSecond < 0 || provenance.timestamp.epochSecond >= Limits.historyMaxUnixSeconds ||
            provenance.providerHost.isEmpty() || provenance.model.isEmpty() ||
            provenance.usage?.let { it.inputTokens < 0 || it.outputTokens < 0 } == true) {
            throw LibraryError.InvalidProvenance
        }
        val record = mutableMapOf<String, JsonElement>(
            "version" to JsonPrimitive(1), "contentSHA256" to JsonPrimitive(hash(bytes)),
            "origin" to JsonPrimitive(provenance.origin.rawValue),
            "timestamp" to JsonPrimitive(provenanceFormatter.format(provenance.timestamp)),
            "providerHost" to JsonPrimitive(provenance.providerHost), "model" to JsonPrimitive(provenance.model),
        )
        provenance.usage?.let { record["usage"] = StateJson.objectOf(mapOf(
            "inputTokens" to JsonPrimitive(it.inputTokens), "outputTokens" to JsonPrimitive(it.outputTokens))) }
        val encoded = StateJson.objectOf(record).toString().replace("/", "\\/")
            .encodeToByteArray(throwOnInvalidSequence = true)
        files.writePrivate(encoded, path)
    }

    private fun removeProvenance(path: String) {
        if (files.stamp(path) == null) return
        try { files.delete(path) } catch (_: StoreError.NotFound) { /* Concurrent cleanup. */ }
    }

    private fun hash(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }

    internal fun prune(identity: PromptIdentity) = mutations.run {
        revisions(identity).drop(Limits.historyCapPerPrompt).asReversed().forEach(::remove)
    }

    override fun migrateKey(source: PromptIdentity, destination: PromptIdentity): KeyMigration = mutations.run {
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
