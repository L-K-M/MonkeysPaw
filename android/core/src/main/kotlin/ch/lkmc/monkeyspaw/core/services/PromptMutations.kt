package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.*

/** Lifecycle edits reuse the content writer's preserved tree; the public writer still assigns no ID. */
internal object PromptMutations {
    fun assigningIdentity(id: ULID, document: PromptDocument, filename: String): PromptDocument {
        PromptCodec.write(document)
        if (document.frontMatter.id != null) {
            if (document.frontMatter.id != id) throw LibraryError.IdentityMismatch
            return document
        }
        return setting("id", YamlNode.Scalar(id.rawValue, YamlTag.STR), document,
            document.frontMatter.copy(id = id), filename)
    }

    /** Sync duplicate repair/adoption explicitly replaces identity; ordinary saves keep their guard. */
    fun replacingIdentity(id: ULID, document: PromptDocument, filename: String): PromptDocument {
        PromptWriter.validate(document)
        val node = document.preservedHeader?.entries?.firstOrNull { PortableYaml.string(it.key) == "id" }?.value
        val literal = node?.let(PortableYaml::string)
        val mark = node?.mark
        if (literal != null && mark != null) {
            val source = document.source
            var start = 0
            var line = 1
            while (start < source.length && line < mark.line) {
                val point = source.codePointAt(start)
                if (point == 10) line++
                start += Character.charCount(point)
            }
            var column = 1
            while (start < source.length && column < mark.column) {
                start += Character.charCount(source.codePointAt(start))
                column++
            }
            // Splice only the marked literal; repeated IDs in comments, metadata and body remain exact.
            for (quote in listOf("", "'", "\"")) {
                if (!source.startsWith(quote + literal + quote, start)) continue
                val valueStart = start + quote.length
                val changed = source.replaceRange(valueStart, valueStart + literal.length, id.rawValue)
                val parsed = PromptCodec.parse(changed, filename)
                if (parsed.canRender && parsed.frontMatter.id == id) return parsed
            }
        }
        // Escaped/block scalars and idless documents require the canonical writer, with the body intact.
        return setting("id", YamlNode.Scalar(id.rawValue, YamlTag.STR), document,
            document.frontMatter.copy(id = id), filename)
    }

    fun favorite(value: Boolean, document: PromptDocument, filename: String): PromptDocument {
        PromptCodec.write(document)
        return setting("favorite", YamlNode.Scalar(value.toString(), YamlTag.BOOL), document,
            document.frontMatter.copy(favorite = value), filename)
    }

    private fun setting(key: String, value: YamlNode, document: PromptDocument,
                        metadata: FrontMatter, filename: String): PromptDocument {
        val header = document.preservedHeader ?: YamlNode.Mapping(emptyList())
        val entries = header.entries.filterNot { PortableYaml.string(it.key) == key } +
            YamlNode.Entry(YamlNode.Scalar(key, YamlTag.STR), value)
        val changed = PromptDocument(document.source, document.body, metadata, document.template,
            document.decodingIssues, header.copy(entries = entries), document.declarationLocations)
        return PromptCodec.parse(PromptCodec.write(changed), filename)
    }
}
