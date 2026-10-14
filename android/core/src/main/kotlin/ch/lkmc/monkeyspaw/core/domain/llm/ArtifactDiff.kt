package ch.lkmc.monkeyspaw.core.domain.llm

import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptDocument
import ch.lkmc.monkeyspaw.core.domain.format.Template
import ch.lkmc.monkeyspaw.core.domain.format.TemplateToken

/** A rename is a possible one-for-one substitution in a replacement hunk. */
sealed interface PlaceholderChange {
    data class Added(val name: String) : PlaceholderChange
    data class Removed(val name: String) : PlaceholderChange
    data class Renamed(val from: String, val to: String) : PlaceholderChange
}

class ArtifactDiff private constructor(
    frontMatter: List<LineDiffLine>,
    body: List<LineDiffLine>,
    placeholderWarnings: List<PlaceholderChange>,
) {
    val frontMatter: List<LineDiffLine> = frontMatter.immutableCopy()
    val body: List<LineDiffLine> = body.immutableCopy()
    /** Unique changes in original first-use order, followed by added first-use order. */
    val placeholderWarnings: List<PlaceholderChange> = placeholderWarnings.immutableCopy()

    override fun equals(other: Any?): Boolean = other is ArtifactDiff && frontMatter == other.frontMatter &&
        body == other.body && placeholderWarnings == other.placeholderWarnings
    override fun hashCode(): Int = listOf(frontMatter, body, placeholderWarnings).hashCode()

    companion object {
        /** Canonical header (with delimiters) and exact body compare separately; null is a write baseline. */
        fun compare(original: PromptDocument?, candidate: ArtifactMergeCandidate): ArtifactDiff {
            val oldSource = original?.let(PromptCodec::write).orEmpty().toByteArray(Charsets.UTF_8)
            val oldBody = original?.body.orEmpty()
            val newBody = candidate.document.body
            val newSource = candidate.canonicalBytes
            val oldHeader = oldSource.copyOfRange(0, oldSource.size - oldBody.toByteArray(Charsets.UTF_8).size)
            val newHeader = newSource.copyOfRange(0, newSource.size - newBody.toByteArray(Charsets.UTF_8).size)
            val headerDiff = MyersLineDiff.compare(oldHeader.toString(Charsets.UTF_8), newHeader.toString(Charsets.UTF_8))
            val bodyDiff = MyersLineDiff.compare(oldBody, newBody)
            val oldTemplate = original?.template ?: Template.parse("")
            val newTemplate = candidate.document.template
            val oldNames = oldTemplate.names.toSet()
            val newNames = newTemplate.names.toSet()
            val removed = oldTemplate.names.filter { it !in newNames }
            val added = newTemplate.names.filter { it !in oldNames }
            val removedSet = removed.toSet()
            val addedSet = added.toSet()
            val oldLines = placeholderLines(oldBody, oldTemplate)
            val newLines = placeholderLines(newBody, newTemplate)

            val targets = mutableMapOf<String, MutableSet<String>>()
            val sources = mutableMapOf<String, MutableSet<String>>()
            val ambiguousRemoved = mutableSetOf<String>()
            val ambiguousAdded = mutableSetOf<String>()
            var start = 0
            while (start < bodyDiff.size) {
                if (bodyDiff[start].kind == LineDiffLine.Kind.UNCHANGED) { start++; continue }
                var end = start
                val hunkRemoved = mutableSetOf<String>()
                val hunkAdded = mutableSetOf<String>()
                while (end < bodyDiff.size && bodyDiff[end].kind != LineDiffLine.Kind.UNCHANGED) {
                    val row = bodyDiff[end]
                    hunkRemoved.addAll(oldLines[row.originalLine].orEmpty().filter { it in removedSet })
                    hunkAdded.addAll(newLines[row.mergedLine].orEmpty().filter { it in addedSet })
                    end++
                }
                if (hunkRemoved.size == 1 && hunkAdded.size == 1) {
                    val from = hunkRemoved.single()
                    val to = hunkAdded.single()
                    targets.getOrPut(from) { mutableSetOf() }.add(to)
                    sources.getOrPut(to) { mutableSetOf() }.add(from)
                } else {
                    ambiguousRemoved.addAll(hunkRemoved)
                    ambiguousAdded.addAll(hunkAdded)
                }
                start = end
            }
            val removedChanges = mutableMapOf<String, PlaceholderChange>()
            val addedChanges = added.associateWithTo(mutableMapOf<String, PlaceholderChange>()) { PlaceholderChange.Added(it) }
            val renameTargets = mutableSetOf<String>()
            for (name in removed) {
                val to = targets[name]?.singleOrNull()
                if (to != null && sources[to]?.size == 1 && name !in ambiguousRemoved && to !in ambiguousAdded) {
                    val change = PlaceholderChange.Renamed(name, to)
                    removedChanges[name] = change
                    addedChanges[to] = change
                    renameTargets.add(to)
                } else removedChanges[name] = PlaceholderChange.Removed(name)
            }
            val changes = removed.mapNotNull { removedChanges[it] } +
                added.filter { it !in renameTargets }.mapNotNull { addedChanges[it] }
            val marked = bodyDiff.map { row ->
                val warnings = when (row.kind) {
                    LineDiffLine.Kind.REMOVED -> oldLines[row.originalLine].orEmpty().mapNotNull { removedChanges[it] }
                    LineDiffLine.Kind.ADDED -> newLines[row.mergedLine].orEmpty().mapNotNull { addedChanges[it] }
                    LineDiffLine.Kind.UNCHANGED -> emptyList()
                }
                LineDiffLine(row.kind, row.bytes, row.originalLine, row.mergedLine, warnings)
            }
            return ArtifactDiff(headerDiff, marked, changes)
        }

        /** Walk whole-template tokens so escapes and invalid multiline literals cannot invent names. */
        private fun placeholderLines(body: String, template: Template): Map<Int, List<String>> {
            val bytes = body.toByteArray(Charsets.UTF_8)
            val result = mutableMapOf<Int, MutableList<String>>()
            val lineNames = mutableSetOf<String>()
            var offset = 0
            var line = 1
            for (token in template.tokens) {
                when (token) {
                    is TemplateToken.Literal -> {
                        val literal = token.text.toByteArray(Charsets.UTF_8)
                        offset += literal.size
                        val newlines = literal.count { it == 10.toByte() }
                        line += newlines
                        if (newlines > 0) lineNames.clear()
                    }
                    TemplateToken.EscapedOpener -> offset += 3
                    is TemplateToken.Placeholder -> {
                        if (lineNames.add(token.name)) result.getOrPut(line) { mutableListOf() }.add(token.name)
                        offset += 2
                        while (offset + 1 < bytes.size && !(bytes[offset] == 125.toByte() && bytes[offset + 1] == 125.toByte())) offset++
                        offset += 2
                    }
                }
            }
            return result
        }
    }
}
