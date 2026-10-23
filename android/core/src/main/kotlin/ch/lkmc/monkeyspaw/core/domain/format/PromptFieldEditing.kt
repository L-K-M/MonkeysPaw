package ch.lkmc.monkeyspaw.core.domain.format

import ch.lkmc.monkeyspaw.core.domain.Limits

/** Patch only changed properties; untouched optional keys and nested metadata survive. */
internal object PromptFieldEditing {
    fun edit(settings: PromptFieldSettings, document: PromptDocument, filename: String): PromptDocument {
        val current = PromptCodec.fieldSettings(document)?.firstOrNull { it.name == settings.name }
            ?: throw PromptWriteError.InvalidPrompt
        if (settings.validationIssue != null) throw PromptWriteError.InvalidPrompt
        val header = document.preservedHeader?.entries?.toMutableList() ?: mutableListOf()
        val fieldsIndex = header.indexOfFirst { PortableYaml.string(it.key) == "fields" }
        val fields = ((header.getOrNull(fieldsIndex)?.value as? YamlNode.Mapping)?.entries ?: emptyList()).toMutableList()
        val fieldIndex = fields.indexOfFirst { PortableYaml.string(it.key) == settings.name }
        val properties = ((fields.getOrNull(fieldIndex)?.value as? YamlNode.Mapping)?.entries ?: emptyList()).toMutableList()
        val originalOptions = (properties.firstOrNull { PortableYaml.string(it.key) == "options" }?.value as? YamlNode.Sequence)?.values
        var changed = false

        fun set(key: String, value: YamlNode?) {
            changed = true
            val index = properties.indexOfFirst { PortableYaml.string(it.key) == key }
            if (index >= 0) {
                if (value != null) properties[index] = properties[index].copy(value = value)
                else properties.removeAt(index)
            } else if (value != null) properties.add(YamlNode.Entry(YamlNode.Scalar(key, YamlTag.STR), value))
        }
        fun string(value: String?) = value?.let { YamlNode.Scalar(it, YamlTag.STR) }

        if (settings.kind != current.kind) {
            set("type", YamlNode.Scalar(settings.kind.rawValue, YamlTag.STR))
            if (settings.kind != FieldKind.CHOICE) set("options", null)
        }
        if (settings.label != current.label) set("label", string(settings.label))
        if (settings.description != current.description) set("description", string(settings.description))
        if (settings.defaultValue != current.defaultValue) set("default", string(settings.defaultValue))
        if (settings.optional != current.optional) set("optional", YamlNode.Scalar(settings.optional.toString(), YamlTag.BOOL))
        if (settings.remember != current.remember) set("remember", YamlNode.Scalar(settings.remember.toString(), YamlTag.BOOL))

        if (settings.kind == FieldKind.CHOICE && settings.options != current.options) {
            val options = settings.options.map { option ->
                val original = option.originalIndex?.let { originalOptions?.getOrNull(it) }
                if (original !is YamlNode.Mapping && option.label == option.value) {
                    YamlNode.Scalar(option.value, YamlTag.STR)
                } else {
                    val entries = ((original as? YamlNode.Mapping)?.entries ?: emptyList()).toMutableList()
                    for ((key, value) in listOf("label" to option.label, "value" to option.value)) {
                        val index = entries.indexOfFirst { PortableYaml.string(it.key) == key }
                        val scalar = YamlNode.Scalar(value, YamlTag.STR)
                        if (index >= 0) entries[index] = entries[index].copy(value = scalar)
                        else entries.add(YamlNode.Entry(YamlNode.Scalar(key, YamlTag.STR), scalar))
                    }
                    YamlNode.Mapping(entries)
                }
            }
            set("options", YamlNode.Sequence(options))
        }
        if (!changed) return document

        val declaration = YamlNode.Mapping(properties)
        if (fieldIndex >= 0) fields[fieldIndex] = fields[fieldIndex].copy(value = declaration)
        else fields.add(YamlNode.Entry(YamlNode.Scalar(settings.name, YamlTag.STR), declaration))
        val declarations = YamlNode.Mapping(fields)
        if (fieldsIndex >= 0) header[fieldsIndex] = header[fieldsIndex].copy(value = declarations)
        else header.add(YamlNode.Entry(YamlNode.Scalar("fields", YamlTag.STR), declarations))
        val headerDocument = PromptDocument("", "", document.frontMatter, Template.parse(""),
            preservedHeader = YamlNode.Mapping(header))
        val source = PromptCodec.write(headerDocument) + document.body
        if (source.toByteArray(Charsets.UTF_8).size > Limits.maxPromptBytes) throw PromptWriteError.SourceTooLarge
        val result = PromptCodec.parse(source, filename)
        if (result.decodingIssues.any { it.severity == PromptIssueSeverity.ERROR }) throw PromptWriteError.InvalidPrompt
        return result
    }
}
