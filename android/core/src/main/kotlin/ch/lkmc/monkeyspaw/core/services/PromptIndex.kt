package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.ranking.PromptRanking
import ch.lkmc.monkeyspaw.core.domain.ranking.PromptSearchField
import ch.lkmc.monkeyspaw.core.domain.ranking.Utf8Order
import java.time.Instant
import java.util.Collections

class IndexedPrompt internal constructor(val entry: LibraryEntry, events: List<Instant>) {
    val useEvents: List<Instant> = Collections.unmodifiableList(events.toList())
    internal val ranking = PromptRanking.Input(entry.relativePath, entry.document, useEvents)
}

data class LocalSearchResult(val entry: LibraryEntry, val score: Double, val matchedFields: List<PromptSearchField>)

data class LibrarySnapshot(val version: Long, val prompts: List<IndexedPrompt>)

/** Memory-only browse/search over the latest complete publication, including invalid/future entries. */
class PromptIndex internal constructor(private val library: LibraryService) {
    private var prompts = emptyMap<String, IndexedPrompt>()
    private var version = 0L

    /** Stage every library and usage read before replacing the cache. Failure preserves its version. */
    fun rebuild(): LibrarySnapshot = library.mutations.run {
        val entries = library.entries()
        val events = entries.map { it.identity }.distinct().associateWith(library.usage::useEvents)
        val rebuilt = entries.associate { it.relativePath to IndexedPrompt(it, events.getValue(it.identity)) }
        prompts = rebuilt
        version++
        snapshot()
    }

    fun snapshot(): LibrarySnapshot = library.mutations.run {
        LibrarySnapshot(version, Collections.unmodifiableList(prompts.values.sortedWith { a, b ->
            Utf8Order.compare(a.entry.relativePath.encodeToByteArray(), b.entry.relativePath.encodeToByteArray())
        }))
    }

    fun search(query: String): List<LocalSearchResult> {
        val (snapshot, now) = library.mutations.run { prompts to library.clock.now() }
        return PromptRanking.rank(snapshot.values.map { it.ranking }, query, now).map {
            LocalSearchResult(snapshot.getValue(it.relativePath).entry, it.score, it.matchedFields)
        }
    }

    fun recordUse(identity: PromptIdentity): List<Instant> = library.usage.recordUse(identity)

    internal fun acceptCommitted(entry: LibraryEntry, source: String) {
        val previous = prompts[source]
        val events = library.usage.cachedEvents(entry.identity) ?: previous?.useEvents ?: emptyList()
        prompts = (prompts - source) + (entry.relativePath to IndexedPrompt(entry, events))
        version++
    }

    internal fun acceptDeleted(path: String) {
        prompts = prompts - path
        version++
    }

    internal fun acceptRelocated(source: String, destination: String, current: PromptLoadResult) {
        prompts = prompts - source - destination
        if (current is PromptLoadResult.Loaded) acceptCommitted(current.prompt.entry, source) else version++
    }

    internal fun acceptUsage(identity: PromptIdentity, events: List<Instant>) {
        if (prompts.values.none { it.entry.identity == identity }) return
        prompts = prompts.mapValues { (_, input) ->
            if (input.entry.identity == identity) IndexedPrompt(input.entry, events) else input
        }
        version++
    }
}
