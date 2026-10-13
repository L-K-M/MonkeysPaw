package ch.lkmc.monkeyspaw.core.domain.`import`

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.FrontMatter
import ch.lkmc.monkeyspaw.core.domain.format.PortableYaml
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptDocument
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueLocation
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueSeverity
import ch.lkmc.monkeyspaw.core.domain.format.PromptWriteError
import ch.lkmc.monkeyspaw.core.domain.format.Template
import ch.lkmc.monkeyspaw.core.domain.format.YamlNode
import ch.lkmc.monkeyspaw.core.domain.format.YamlTag
import ch.lkmc.monkeyspaw.core.domain.format.equalChoiceValues
import java.nio.charset.CharacterCodingException

/** Pure, bounded conversion. Foreign declarations stay in the validated tree beside mapped fields. */
object ImportMapper {
    fun map(bytes: ByteArray, filename: String): ImportMappingResult {
        if (bytes.size > Limits.importFileCapBytes) throw ImportSkipReason.FileTooLarge
        val source = try {
            bytes.decodeToString(throwOnInvalidSequence = true)
        } catch (_: CharacterCodingException) {
            throw ImportSkipReason.InvalidUTF8
        }
        val format = ImportFormat.filename(filename) ?: throw ImportSkipReason.UnsupportedExtension
        val original = PromptCodec.parse(source, filename)
        val report = ImportMappingReport(preservedKeys = original.preservedHeader?.entries.orEmpty()
            .mapNotNull { PortableYaml.string(it.key) })

        // Validate portability and reject anchors before traversing any imported schema.
        validate(original)
        if (format == ImportFormat.MARKDOWN) {
            return ImportMappingResult(original, report.copy(warnings = original.issues
                .filter { it.severity == PromptIssueSeverity.WARNING }.map { ImportWarning.Validation(it.code) }))
        }
        val header = original.preservedHeader ?: return ImportMappingResult(original,
            report.copy(warnings = templateWarnings(original, format)))
        val mapper = FieldMapper(header, original.template.names)
        if (format == ImportFormat.DOTPROMPT) mapper.dotprompt() else mapper.prompty()

        val entries = header.entries.toMutableList()
        if (mapper.fields.isNotEmpty()) {
            val existing = (value("fields", header) as? YamlNode.Mapping)?.entries.orEmpty()
            entries.removeAll { PortableYaml.string(it.key) == "fields" }
            entries.add(entry("fields", YamlNode.Mapping(existing + mapper.fields)))
        }
        val document = canonical(entries, original.body, filename)
        return ImportMappingResult(document, report.copy(mappings = mapper.mappings.toList(),
            dropped = listOf(ImportLoss.FRONT_MATTER_PRESENTATION),
            warnings = mapper.warnings + templateWarnings(document, format)))
    }

    private fun validate(document: PromptDocument) {
        if (document.isReadOnly) throw ImportSkipReason.UnsupportedFormat(document.frontMatter.format)
        val errors = document.issues.filter { it.severity == PromptIssueSeverity.ERROR }.map { it.code }
        if (errors.isNotEmpty()) throw ImportSkipReason.InvalidPrompt(errors)
    }

    private fun canonical(entries: List<YamlNode.Entry>, body: String, filename: String): PromptDocument {
        val draft = PromptDocument("", body, FrontMatter(filename.substringBeforeLast('.', filename)),
            Template.parse(body), preservedHeader = YamlNode.Mapping(entries))
        val source = try {
            PromptCodec.write(draft)
        } catch (_: PromptWriteError.SourceTooLarge) {
            throw ImportSkipReason.ConvertedTooLarge
        } catch (_: PromptWriteError) {
            throw ImportSkipReason.OperationFailed
        }
        // Reparse generated declarations so validation and locations follow ordinary saved content.
        return PromptCodec.parse(source, filename).also(::validate)
    }

    private fun templateWarnings(document: PromptDocument, format: ImportFormat): List<ImportWarning> {
        val issues = document.issues.filter { it.severity == PromptIssueSeverity.WARNING }
        val validation = issues.filter { it.code != PromptIssueCode.INVALID_PLACEHOLDER }
            .map { ImportWarning.Validation(it.code) }
        val offsets = issues.filter { it.code == PromptIssueCode.INVALID_PLACEHOLDER }
            .mapNotNull { (it.location as? PromptIssueLocation.Body)?.byteOffset }.toMutableSet()
        if (format == ImportFormat.PROMPTY) {
            val bytes = document.body.toByteArray(Charsets.UTF_8)
            for (offset in 0 until bytes.size - 1) {
                if (bytes[offset] == 123.toByte() && (bytes[offset + 1] == 37.toByte() || bytes[offset + 1] == 35.toByte())) {
                    offsets.add(offset)
                }
            }
        }
        return validation + offsets.sorted().map { ImportWarning.UnsupportedTemplate(format, it) }
    }

    private class FieldMapper(private val header: YamlNode.Mapping, bodyNames: List<String>) {
        private val bodyNames = bodyNames.toSet()
        private val used = (value("fields", header) as? YamlNode.Mapping)?.entries.orEmpty()
            .mapNotNull { PortableYaml.string(it.key) }.toMutableSet()
        val fields = mutableListOf<YamlNode.Entry>()
        val mappings = mutableListOf<ImportFieldMapping>()
        val warnings = mutableListOf<ImportWarning>()

        fun dotprompt() {
            val inputNode = value("input", header) ?: return
            val input = inputNode as? YamlNode.Mapping
            val schema = input?.let { value("schema", it) } as? YamlNode.Mapping
            if (input == null || schema == null) {
                warnings.add(ImportWarning.UnsupportedInput("input.schema"))
                return
            }
            val defaults = value("default", input) as? YamlNode.Mapping
            val type = PortableYaml.string(value("type", schema))
            val properties = value("properties", schema) as? YamlNode.Mapping
            // Dotprompt 1.1.2 selects JSON Schema by a recognized type or a properties mapping.
            if (type in setOf("any", "boolean", "integer", "null", "number", "string", "object", "array") || properties != null) {
                if ((type != null && type != "object") || properties == null) {
                    warnings.add(ImportWarning.UnsupportedInput("input.schema"))
                    return
                }
                val required = (value("required", schema) as? YamlNode.Sequence)?.values.orEmpty()
                    .mapNotNull(PortableYaml::string)
                for ((key, declaration) in properties.entries) {
                    val name = PortableYaml.string(key) ?: continue
                    mapDeclaration(declaration, name, "input.schema.properties.$name",
                        defaults?.let { value(name, it) }, "input.default.$name", optional = name !in required)
                }
                return
            }
            for ((key, declaration) in schema.entries) {
                val name = PortableYaml.string(key)
                if (name == null) {
                    warnings.add(ImportWarning.UnsupportedInput("input.schema"))
                    continue
                }
                val source = "input.schema.$name"
                if (declaration is YamlNode.Mapping) {
                    mapDeclaration(declaration, name, source, defaults?.let { value(name, it) }, "input.default.$name")
                    continue
                }
                val pico = PicoName(name)
                if (!canMap(pico.name, source)) continue
                val scalar = PortableYaml.string(declaration)
                val definition = when {
                    pico.kind == "enum" -> YamlNode.Mapping(listOf(entry("type", string("string")), entry("enum", declaration)))
                    pico.kind == null && scalar != null -> {
                        val parts = scalar.split(',', limit = 2)
                        if (parts[0].trimForeignWhitespace() != "string") {
                            warnings.add(ImportWarning.UnsupportedInput(source))
                            continue
                        }
                        val pairs = mutableListOf(entry("type", string("string")))
                        if (parts.size == 2) pairs.add(entry("description", string(parts[1].trimForeignWhitespace())))
                        YamlNode.Mapping(pairs)
                    }
                    else -> {
                        warnings.add(ImportWarning.UnsupportedInput(source))
                        continue
                    }
                }
                mapDeclaration(definition, pico.name, source, defaults?.let { value(pico.name, it) },
                    "input.default.${pico.name}", pico.optional, pico.description)
            }
        }

        fun prompty() {
            val samples = value("sample", header) as? YamlNode.Mapping
            val inputs = value("inputs", header)
            val declared = mutableSetOf<String>()
            when (inputs) {
                is YamlNode.Mapping -> for ((key, declaration) in inputs.entries) {
                    val name = PortableYaml.string(key)
                    if (name == null) {
                        warnings.add(ImportWarning.UnsupportedInput("inputs"))
                        continue
                    }
                    declared.add(name)
                    mapPrompty(declaration, name, "inputs.$name", samples)
                }
                is YamlNode.Sequence -> for ((index, declaration) in inputs.values.withIndex()) {
                    val source = "inputs[$index]"
                    val name = (declaration as? YamlNode.Mapping)?.let { PortableYaml.string(value("name", it)) }
                    if (name == null) {
                        warnings.add(ImportWarning.UnsupportedInput(source))
                        continue
                    }
                    declared.add(name)
                    mapPrompty(declaration, name, source, samples)
                }
                null -> Unit
                else -> {
                    warnings.add(ImportWarning.UnsupportedInput("inputs"))
                    return
                }
            }
            // Sample-only v1 inputs refine implicit body fields, without overriding unsupported declarations.
            for ((key, sample) in samples?.entries.orEmpty()) {
                val name = PortableYaml.string(key) ?: continue
                if (name !in bodyNames || name in declared) continue
                val source = "sample.$name"
                mapDeclaration(YamlNode.Mapping(listOf(entry("type", string("string")))), name, source, sample, source)
            }
        }

        private fun mapPrompty(node: YamlNode, name: String, source: String, samples: YamlNode.Mapping?) {
            val localSample = (node as? YamlNode.Mapping)?.let { value("sample", it) }
            mapDeclaration(node, name, source, localSample ?: samples?.let { value(name, it) },
                if (localSample == null) "sample.$name" else "$source.sample")
        }

        private fun canMap(name: String, source: String): Boolean {
            when {
                !Template.isValidName(name) -> warnings.add(ImportWarning.InvalidName(source))
                Template.isReserved(name) -> warnings.add(ImportWarning.ReservedName(name))
                name in used -> warnings.add(ImportWarning.FieldCollision(name))
                else -> return true
            }
            return false
        }

        private fun mapDeclaration(node: YamlNode, name: String, source: String, fallback: YamlNode?,
                                   fallbackSource: String, optional: Boolean = false, description: String? = null) {
            if (!canMap(name, source)) return
            val properties = node as? YamlNode.Mapping
            if (properties == null || PortableYaml.string(value("type", properties)) != "string") {
                warnings.add(ImportWarning.UnsupportedInput(source))
                return
            }
            val pairs = mutableListOf<YamlNode.Entry>()
            var choices = emptyList<String>()
            val options = value("enum", properties)
            val kind = if (options != null) {
                val sequence = options as? YamlNode.Sequence
                if (sequence == null || sequence.values.isEmpty()) {
                    warnings.add(ImportWarning.InvalidOptions(source))
                    return
                }
                choices = sequence.values.mapNotNull(PortableYaml::string)
                if (choices.size != sequence.values.size) {
                    warnings.add(ImportWarning.InvalidOptions(source))
                    return
                }
                pairs.add(entry("options", options))
                FieldKind.CHOICE
            } else FieldKind.TEXT
            pairs.add(0, entry("type", string(kind.rawValue)))

            val explicitDefault = value("default", properties)
            fun usableDefault(candidate: YamlNode?): YamlNode? {
                val text = PortableYaml.string(candidate) ?: return null
                return candidate.takeIf { kind != FieldKind.CHOICE || choices.any { equalChoiceValues(it, text) } }
            }
            var defaultNode = usableDefault(explicitDefault)
            var defaultSource = defaultNode?.let { "$source.default" }
            if (defaultNode == null) {
                defaultNode = usableDefault(fallback)
                defaultSource = defaultNode?.let { fallbackSource }
                if (explicitDefault != null || (fallback != null && defaultNode == null)) {
                    warnings.add(ImportWarning.InvalidDefault(source))
                    if (defaultNode == null) return
                }
            }
            if (defaultNode != null) pairs.add(entry("default", defaultNode))
            val descriptionNode = value("description", properties)
            if (descriptionNode != null) {
                if (PortableYaml.string(descriptionNode) == null) {
                    warnings.add(ImportWarning.InvalidDescription(source))
                    return
                }
                pairs.add(entry("description", descriptionNode))
            } else if (description != null) pairs.add(entry("description", string(description)))
            if (optional || PortableYaml.boolean(value("required", properties)) == false) {
                pairs.add(entry("optional", YamlNode.Scalar("true", YamlTag.BOOL)))
            }
            fields.add(entry(name, YamlNode.Mapping(pairs)))
            used.add(name)
            mappings.add(ImportFieldMapping(source, name, kind, defaultSource))
        }
    }

    private class PicoName(key: String) {
        val name: String
        val optional: Boolean
        val kind: String?
        val description: String?

        init {
            val parts = key.split('(', limit = 2)
            val base = parts[0]
            optional = base.endsWith('?')
            name = if (optional) base.dropLast(1) else base
            if (parts.size == 2 && parts[1].endsWith(')')) {
                val annotation = parts[1].dropLast(1).split(',', limit = 2)
                kind = annotation[0].trimForeignWhitespace()
                description = annotation.getOrNull(1)?.trimForeignWhitespace()
            } else {
                kind = if (parts.size == 1) null else "unsupported"
                description = null
            }
        }
    }

    private fun value(key: String, mapping: YamlNode.Mapping): YamlNode? =
        mapping.entries.firstOrNull { PortableYaml.string(it.key) == key }?.value

    private fun string(text: String) = YamlNode.Scalar(text, YamlTag.STR)
    private fun entry(key: String, value: YamlNode) = YamlNode.Entry(string(key), value)

    // Foundation's whitespaces excludes newlines; JVM trim() would widen the accepted declarations.
    private fun String.trimForeignWhitespace(): String = trim {
        it == '\t' || it == ' ' || it == '\u00A0' || it == '\u1680' || it in '\u2000'..'\u200A' ||
            it == '\u202F' || it == '\u205F' || it == '\u3000'
    }
}
