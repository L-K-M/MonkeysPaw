package ch.lkmc.monkeyspaw.core.domain.ranking

import com.ibm.icu.lang.UCharacter
import com.ibm.icu.lang.UProperty
import com.ibm.icu.text.BreakIterator
import com.ibm.icu.util.ULocale

internal class SearchQuery(query: String) {
    val terms: List<IntArray>
    val tags: List<String>
    val isEmpty: Boolean

    init {
        val graphemes = BreakIterator.getCharacterInstance(ULocale.ROOT)
        graphemes.setText(query)
        val tokens = mutableListOf<String>()
        var tokenStart = 0
        var start = graphemes.first()
        var end = graphemes.next()
        while (end != BreakIterator.DONE) {
            // Swift Character.isWhitespace tests the first scalar of the entire grapheme.
            if (UCharacter.hasBinaryProperty(query.codePointAt(start), UProperty.WHITE_SPACE)) {
                if (start > tokenStart) tokens.add(query.substring(tokenStart, start))
                tokenStart = end
            }
            start = end
            end = graphemes.next()
        }
        if (tokenStart < query.length) tokens.add(query.substring(tokenStart))

        val ordinary = mutableListOf<IntArray>()
        val filters = mutableListOf<String>()
        for (token in tokens) {
            graphemes.setText(token)
            // Swift hasPrefix("#") requires a whole Character; an attached mark is ordinary text.
            if (token.startsWith("#") && graphemes.following(0) == 1) {
                filters.add(SearchNormalizer.tagKey(token.substring(1)))
            } else {
                ordinary.add(SearchNormalizer.normalize(token).codePoints().toArray())
            }
        }
        terms = ordinary
        tags = filters
        isEmpty = tokens.isEmpty()
    }
}
