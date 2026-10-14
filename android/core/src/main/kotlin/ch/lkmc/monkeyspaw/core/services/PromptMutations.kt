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
