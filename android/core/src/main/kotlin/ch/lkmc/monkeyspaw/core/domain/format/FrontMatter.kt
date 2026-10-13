package ch.lkmc.monkeyspaw.core.domain.format

import ch.lkmc.monkeyspaw.core.domain.ULID

data class FrontMatter(
    val title: String,
    val id: ULID? = null,
    val description: String? = null,
    val tags: List<String> = emptyList(),
    val favorite: Boolean = false,
    val isPrivate: Boolean = false,
    val fields: List<PromptField> = emptyList(),
    val format: PromptFormatVersion = PromptFormatVersion.current,
)

internal class FrontMatterDecoder(private val mapping: YamlNode.Mapping, initialIssues: List<PromptIssue>) {
    val issues = initialIssues.toMutableList()
    val locations = linkedMapOf<String, PromptIssueLocation>()

    fun decode(fallbackTitle: String): FrontMatter {
        val idNode = value("id", mapping)
        val id = PortableYaml.string(idNode)?.let(ULID::parse)
        if (idNode != null && id == null) add(PromptIssueCode.INVALID_ID, idNode)

        val title = string("title", mapping, PromptIssueCode.INVALID_METADATA_TYPE) ?: fallbackTitle
        val description = string("description", mapping, PromptIssueCode.INVALID_METADATA_TYPE)
        val tagsNode = value("tags", mapping)
        val tags = if (tagsNode is YamlNode.Sequence) {
            tagsNode.values.mapNotNull(PortableYaml::string).also {
                if (it.size != tagsNode.values.size) add(PromptIssueCode.INVALID_METADATA_TYPE, tagsNode)
            }
        } else {
            if (tagsNode != null) add(PromptIssueCode.INVALID_METADATA_TYPE, tagsNode)
            emptyList()
        }
        val favorite = boolean("favorite", mapping, false, false, PromptIssueCode.INVALID_METADATA_TYPE)
        val isPrivate = boolean("private", mapping, false, true, PromptIssueCode.INVALID_METADATA_TYPE)
        var format = PromptFormatVersion.current
        value("format", mapping)?.let { node ->
            val version = PortableYaml.formatVersion(node)
            if (version == null) add(PromptIssueCode.INVALID_FORMAT, node) else {
                format = version
                if (version.isFuture) add(PromptIssueCode.UNSUPPORTED_FORMAT, node)
            }
        }
        return FrontMatter(title, id, description, tags, favorite, isPrivate, declarations(), format)
    }

    private fun declarations(): List<PromptField> {
        val node = value("fields", mapping) ?: return emptyList()
        if (node !is YamlNode.Mapping) {
            add(PromptIssueCode.INVALID_FIELD_DECLARATION, node)
            return emptyList()
        }
        val fields = mutableListOf<PromptField>()
        for ((key, declaration) in node.entries) {
            val name = PortableYaml.string(key)
            if (name == null) { add(PromptIssueCode.INVALID_FIELD_NAME, key); continue }
            key.mark?.let { locations[name] = it }
            if (!Template.isValidName(name)) add(PromptIssueCode.INVALID_FIELD_NAME, key)
            if (Template.isReserved(name)) add(PromptIssueCode.RESERVED_FIELD_NAME, key)
            if (declaration !is YamlNode.Mapping) {
                add(PromptIssueCode.INVALID_FIELD_DECLARATION, declaration)
                fields.add(PromptField(name))
                continue
            }
            var kind = FieldKind.TEXT
            value("type", declaration)?.let { type ->
                val decoded = FieldKind.entries.firstOrNull { it.rawValue == PortableYaml.string(type) }
                if (decoded == null) add(PromptIssueCode.UNKNOWN_FIELD_TYPE, type) else kind = decoded
            }
            val label = string("label", declaration, PromptIssueCode.INVALID_FIELD_PROPERTY) ?: name
            val description = string("description", declaration, PromptIssueCode.INVALID_FIELD_PROPERTY)
            val default = string("default", declaration, PromptIssueCode.INVALID_FIELD_DEFAULT) ?: ""
            val optional = boolean("optional", declaration, false, false, PromptIssueCode.INVALID_FIELD_BOOLEAN)
            val remember = boolean("remember", declaration, true, false, PromptIssueCode.INVALID_FIELD_BOOLEAN)
            val options = options(kind, declaration)
            val defaultNode = value("default", declaration)
            val defaultString = PortableYaml.string(defaultNode)
            if (kind == FieldKind.CHOICE && defaultNode != null && defaultString != null &&
                options.none { equalChoiceValues(it.value, defaultString) }) add(PromptIssueCode.INVALID_FIELD_DEFAULT, defaultNode)
            fields.add(PromptField(name, kind, label, description, default, options, optional, remember))
        }
        return fields
    }

    private fun options(kind: FieldKind, declaration: YamlNode.Mapping): List<FieldOption> {
        val node = value("options", declaration)
        if (node == null) {
            if (kind == FieldKind.CHOICE) add(PromptIssueCode.INVALID_FIELD_OPTIONS, declaration)
            return emptyList()
        }
        if (kind != FieldKind.CHOICE || node !is YamlNode.Sequence || node.values.isEmpty()) {
            add(PromptIssueCode.INVALID_FIELD_OPTIONS, node)
            return emptyList()
        }
        return node.values.mapNotNull { entry ->
            val text = PortableYaml.string(entry)
            val label = (entry as? YamlNode.Mapping)?.let { PortableYaml.string(value("label", it)) }
            val value = (entry as? YamlNode.Mapping)?.let { PortableYaml.string(value("value", it)) }
            when {
                text != null -> FieldOption(text, text)
                label != null && value != null -> FieldOption(label, value)
                else -> { add(PromptIssueCode.INVALID_FIELD_OPTIONS, entry); null }
            }
        }
    }

    private fun value(key: String, mapping: YamlNode.Mapping): YamlNode? =
        mapping.entries.filter { PortableYaml.string(it.key) == key }.singleOrNull()?.value

    private fun string(key: String, mapping: YamlNode.Mapping, error: PromptIssueCode): String? {
        val node = value(key, mapping) ?: return null
        return PortableYaml.string(node).also { if (it == null) add(error, node) }
    }

    private fun boolean(key: String, mapping: YamlNode.Mapping, default: Boolean, invalid: Boolean,
                        error: PromptIssueCode): Boolean {
        val node = value(key, mapping) ?: return if (mapping.entries.any { PortableYaml.string(it.key) == key }) invalid else default
        return PortableYaml.boolean(node) ?: invalid.also { add(error, node) }
    }

    private fun add(code: PromptIssueCode, node: YamlNode) { issues.add(PromptIssue(code, node.mark)) }
}
