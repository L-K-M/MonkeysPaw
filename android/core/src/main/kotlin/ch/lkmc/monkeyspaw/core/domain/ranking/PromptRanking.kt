package ch.lkmc.monkeyspaw.core.domain.ranking

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.PromptDocument
import java.time.Instant
import kotlin.math.pow

enum class PromptSearchField(val rawValue: String, internal val weight: Double) {
    TITLE("title", 4.0), TAGS("tags", 2.0), FOLDER("folder", 2.0), DESCRIPTION("description", 1.0), BODY("body", 0.5);
}

data class PromptSearchResult(
    val input: PromptRanking.Input,
    val score: Double,
    val matchedFields: List<PromptSearchField>,
) {
    val relativePath: String get() = input.relativePath
}

/** Pure ranking of indexed snapshots. The caller samples its clock once and owns usage persistence. */
object PromptRanking {
    /** Retained events are supplied in recording order, after resolving the prompt's identity. */
    class Input(val relativePath: String, val document: PromptDocument, useEvents: List<Instant> = emptyList()) {
        internal val content = PromptSearchContent(relativePath, document)
        internal val useEvents = useEvents.toList()
        internal val titleBytes = document.frontMatter.title.encodeToByteArray(throwOnInvalidSequence = true)
        internal val pathBytes = relativePath.encodeToByteArray(throwOnInvalidSequence = true)
    }

    fun rank(prompts: Iterable<Input>, query: String, at: Instant): List<PromptSearchResult> {
        val parsed = SearchQuery(query)
        val results = prompts.mapNotNull { input ->
            val match = input.content.match(parsed) ?: return@mapNotNull null
            val frecency = frecency(input.useEvents, at)
            val boost = if (input.document.frontMatter.favorite) Limits.favoriteBoost else 1.0
            val score = if (parsed.isEmpty) frecency else match.score * (1 + frecency) * boost
            PromptSearchResult(input, score, match.fields)
        }
        return results.sortedWith { left, right ->
            if (left.score != right.score) return@sortedWith right.score.compareTo(left.score)
            if (parsed.isEmpty) {
                val leftFavorite = left.input.document.frontMatter.favorite
                val rightFavorite = right.input.document.frontMatter.favorite
                if (leftFavorite != rightFavorite) return@sortedWith if (leftFavorite) -1 else 1
            }
            val titles = Utf8Order.compare(left.input.titleBytes, right.input.titleBytes)
            if (titles != 0) titles else Utf8Order.compare(left.input.pathBytes, right.input.pathBytes)
        }
    }

    internal fun frecency(events: List<Instant>, at: Instant): Double {
        var sum = 0.0
        for (event in events) {
            val elapsed = (at.epochSecond - event.epochSecond).toDouble() + (at.nano - event.nano) / 1_000_000_000.0
            val ageDays = maxOf(0.0, elapsed / secondsPerDay)
            sum += 2.0.pow(-ageDays / Limits.frecencyHalfLifeDays)
        }
        return minOf(Limits.frecencyCap, sum)
    }

    private const val secondsPerDay = 86_400.0
}

internal data class PromptMatch(val score: Double, val fields: List<PromptSearchField>)

internal class PromptSearchContent(relativePath: String, document: PromptDocument) {
    private val fields: List<Pair<PromptSearchField, FuzzyText>>
    private val tags: Set<String>

    init {
        val front = document.frontMatter
        // Slash is a scalar boundary even when the following mark extends its grapheme.
        val folder = relativePath.substringBeforeLast('/', "")
        fields = listOf(PromptSearchField.TITLE to FuzzyText(front.title)) +
            front.tags.map { PromptSearchField.TAGS to FuzzyText(it) } +
            listOf(PromptSearchField.FOLDER to FuzzyText(folder),
                PromptSearchField.DESCRIPTION to FuzzyText(front.description ?: ""),
                PromptSearchField.BODY to FuzzyText(document.body))
        tags = front.tags.map(SearchNormalizer::normalize).toSet()
    }

    fun match(query: SearchQuery): PromptMatch? {
        if (query.tags.any { it.isEmpty() || it !in tags }) return null
        val matched = mutableSetOf<PromptSearchField>()
        if (query.tags.isNotEmpty()) matched.add(PromptSearchField.TAGS)
        var total = 0.0
        for (term in query.terms) {
            var bestField: PromptSearchField? = null
            var bestScore = 0.0
            for ((field, text) in fields) {
                val score = FuzzyMatcher.score(term, text) ?: continue
                val weighted = score * field.weight
                if (bestField == null || weighted > bestScore) {
                    bestField = field
                    bestScore = weighted
                }
            }
            if (bestField == null) return null
            total += bestScore
            matched.add(bestField)
        }
        return PromptMatch(if (query.terms.isEmpty()) 1.0 else total / query.terms.size,
            PromptSearchField.entries.filter { it in matched })
    }
}
