package ch.lkmc.monkeyspaw.core.conformance

import java.math.BigInteger
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Checks fixture shapes and references; it never runs prompt or DTO implementations. */
internal object FixtureContracts {
    fun read(category: Category, envelope: JsonObject, schemas: Set<String>, envelopeName: String): List<String> {
        if (category == Category.LLM) return LlmFixtureContracts.read(envelope)
        val required = setOf("schema", "category", "expected") + when (category) {
            Category.FORMAT, Category.GRAMMAR, Category.RENDER, Category.VALIDATION -> setOf("filename")
            Category.RANKING -> setOf("query", "now", "prompts")
            Category.IMPORT -> setOf("source")
            Category.PATHS, Category.CANONICAL -> setOf("source", "scope")
            Category.DTO -> setOf("source", "dto")
            Category.LLM -> error("LLM contract dispatched above")
        }
        val optional = when (category) {
            Category.RENDER -> setOf("repeat", "values", "builtins")
            Category.FORMAT -> setOf("repeat", "edits")
            Category.GRAMMAR, Category.VALIDATION, Category.IMPORT -> setOf("repeat")
            Category.CANONICAL -> setOf("comparison")
            else -> emptySet()
        }
        envelope.members(required, optional)
        // The Swift paths reader rejects float-spelled integers; other envelopes use numeric equality.
        val schema = if (category == Category.PATHS) integerToken(envelope["schema"]) else envelope["schema"].integerValue()
        corpusRequire(schema == BigInteger.ONE, "Unknown schema version")
        corpusRequire(envelope["category"].stringValue() == category.directory, "Wrong category discriminator")
        envelope["repeat"]?.let { corpusRequire(it.integerValue().signum() > 0, "Repeat must be positive") }
        val expected = envelope["expected"].objectValue()

        return when (category) {
            Category.FORMAT, Category.GRAMMAR, Category.RENDER, Category.VALIDATION -> {
                envelope["filename"].stringValue()
                content(category, envelope, expected)
                listOf(envelopeName.removeSuffix(".json") + ".md")
            }
            Category.RANKING -> ranking(envelope, expected)
            Category.IMPORT -> {
                imported(expected)
                listOf(sourceName(envelope["source"], setOf(".md", ".prompt", ".prompty"), category))
            }
            Category.PATHS -> {
                scope(envelope)
                corpusRequire(envelope["source"].stringValue() == "path.txt", "Paths source must be path.txt")
                paths(expected)
                listOf("path.txt")
            }
            Category.CANONICAL -> {
                scope(envelope)
                canonical(expected)
                val sources = mutableListOf(sourceName(envelope["source"], setOf(".md"), category))
                envelope["comparison"]?.let {
                    corpusRequire("error" !in expected, "Refusal cannot have a comparison")
                    val comparison = it.objectValue()
                    comparison.members(setOf("source", "equivalent"))
                    comparison["equivalent"].booleanValue()
                    sources.add(sourceName(comparison["source"], setOf(".md"), category))
                }
                sources
            }
            Category.DTO -> {
                val dto = envelope["dto"].stringValue()
                corpusRequire(dto in schemas, "Unknown DTO $dto")
                val valid = expected["valid"].booleanValue()
                val extra = when {
                    valid && dto == "ErrorResponse" -> setOf("http_status")
                    valid && dto == "RetryAfter" -> setOf("header_value")
                    else -> emptySet()
                }
                expected.members(setOf("valid") + extra)
                expected["http_status"]?.integerValue()
                expected["header_value"]?.stringValue()
                val source = sourceName(envelope["source"], setOf(".json"), category)
                corpusRequire(source != "case.json", "DTO source cannot be case.json")
                listOf(source)
            }
            Category.LLM -> error("LLM contract dispatched above")
        }
    }

    private fun content(category: Category, envelope: JsonObject, expected: JsonObject) {
        when (category) {
            Category.FORMAT -> {
                expected.members(setOf("metadata", "body", "issues", "canonical"))
                edits(envelope["edits"])
                val metadata = expected["metadata"].objectValue()
                metadata.members(setOf("id", "title", "description", "tags", "favorite", "private", "format", "declarations"))
                nullableString(metadata["id"])
                metadata["title"].stringValue()
                nullableString(metadata["description"])
                metadata["tags"].strings()
                metadata["favorite"].booleanValue()
                metadata["private"].booleanValue()
                metadata["format"].stringValue()
                fields(metadata["declarations"])
                expected["body"].stringValue()
                nullableString(expected["canonical"])
            }
            Category.GRAMMAR -> {
                expected.members(setOf("tokens", "names", "fields", "issues"))
                for (token in expected["tokens"].arrayValue()) {
                    val value = token.objectValue()
                    when (value["kind"].stringValue()) {
                        "literal" -> { value.members(setOf("kind", "text")); value["text"].stringValue() }
                        "placeholder" -> { value.members(setOf("kind", "name")); value["name"].stringValue() }
                        "escape" -> value.members(setOf("kind"))
                        else -> throw CorpusException("Unknown token kind")
                    }
                }
                expected["names"].strings()
                fields(expected["fields"])
            }
            Category.RENDER -> {
                expected.members(setOf("fields", "builtins", "issues", "result"))
                fields(expected["fields"])
                expected["builtins"].strings()
                envelope["values"]?.objectValue()?.values?.forEach { it.stringValue() }
                envelope["builtins"]?.objectValue()?.let { builtins ->
                    builtins.members(emptySet(), setOf("clipboard", "date", "time"))
                    builtins.values.forEach { it.stringValue() }
                }
                val result = expected["result"].objectValue()
                if ("text" in result) {
                    result.members(setOf("text"))
                    result["text"].stringValue()
                } else {
                    val extra = when (result["error"].stringValue()) {
                        "invalid_prompt", "output_too_large" -> emptySet()
                        "unsupported_format" -> setOf("version")
                        "required_value_missing", "choice_value_invalid" -> setOf("field")
                        "builtin_missing" -> setOf("name")
                        else -> throw CorpusException("Unknown render error")
                    }
                    result.members(setOf("error") + extra)
                    extra.forEach { result[it].stringValue() }
                }
            }
            Category.VALIDATION -> {
                expected.members(setOf("issues", "private", "fields", "canRender", "readOnly", "canWrite"))
                fields(expected["fields"])
                listOf("private", "canRender", "readOnly", "canWrite").forEach { expected[it].booleanValue() }
            }
            else -> throw CorpusException("Unknown content category")
        }
        issues(expected["issues"])
    }

    private fun edits(value: JsonElement?) {
        if (value == null) return
        for (element in value.arrayValue()) {
            val edit = element.objectValue()
            edit.members(setOf("property", "value"))
            when (edit["property"].stringValue()) {
                "title", "description", "body" -> edit["value"].stringValue()
                "tags" -> edit["value"].strings()
                "private" -> edit["value"].booleanValue()
                "field" -> {
                    val field = edit["value"].objectValue()
                    field.members(setOf("name", "type", "label", "description", "default", "options", "optional", "remember"))
                    field["name"].stringValue()
                    field["label"].stringValue()
                    corpusRequire(field["type"].stringValue() in setOf("text", "multiline", "choice"), "Unknown field type")
                    nullableString(field["description"])
                    nullableString(field["default"])
                    field["optional"].booleanValue()
                    field["remember"].booleanValue()
                    for (entry in field["options"].arrayValue()) {
                        val option = entry.objectValue()
                        option.members(setOf("label", "value"), setOf("sourceIndex"))
                        option["label"].stringValue()
                        option["value"].stringValue()
                        option["sourceIndex"]?.let { corpusRequire(it.integerValue().signum() >= 0, "Negative option index") }
                    }
                }
                else -> throw CorpusException("Unknown edit property")
            }
        }
    }

    private fun fields(value: JsonElement?) {
        for (element in value.arrayValue()) {
            val field = element.objectValue()
            field.members(setOf("name", "type", "label", "description", "default", "options", "optional", "remember", "implicit"))
            listOf("name", "label", "default").forEach { field[it].stringValue() }
            corpusRequire(field["type"].stringValue() in setOf("text", "multiline", "choice"), "Unknown field type")
            nullableString(field["description"])
            listOf("optional", "remember", "implicit").forEach { field[it].booleanValue() }
            for (elementOption in field["options"].arrayValue()) {
                val option = elementOption.objectValue()
                option.members(setOf("label", "value"))
                option["label"].stringValue()
                option["value"].stringValue()
            }
        }
    }

    private fun issues(value: JsonElement?) {
        value.arrayValue().forEach {
            val issue = it.objectValue()
            issue.members(setOf("code", "severity"))
            issue["code"].stringValue()
            corpusRequire(issue["severity"].stringValue() in setOf("error", "warning"), "Unknown severity")
        }
    }

    private fun ranking(envelope: JsonObject, expected: JsonObject): List<String> {
        envelope["query"].stringValue()
        timestamp(envelope["now"])
        val prompts = envelope["prompts"].arrayValue()
        corpusRequire(prompts.isNotEmpty(), "Empty ranking prompt set")
        val paths = mutableSetOf<String>()
        val sources = prompts.map {
            val prompt = it.objectValue()
            prompt.members(setOf("source", "path", "uses"))
            corpusRequire(paths.add(prompt["path"].stringValue()), "Duplicate ranking path")
            prompt["uses"].arrayValue().forEach(::timestamp)
            sourceName(prompt["source"], setOf(".md"), Category.RANKING)
        }
        expected.members(setOf("results"))
        val resultPaths = mutableSetOf<String>()
        expected["results"].arrayValue().forEach {
            val result = it.objectValue()
            result.members(setOf("path", "score", "matchedFields"))
            val path = result["path"].stringValue()
            corpusRequire(path in paths && resultPaths.add(path), "Unknown or duplicate ranking result path")
            corpusRequire(result["score"].numberValue().toDouble().isFinite(), "Nonfinite ranking score")
            corpusRequire(result["matchedFields"].strings().all {
                it in setOf("title", "tags", "folder", "description", "body")
            }, "Unknown ranking field")
        }
        return sources
    }

    private fun imported(expected: JsonObject) {
        if ("refusal" in expected) {
            expected.members(setOf("refusal"))
            val refusal = expected["refusal"].objectValue()
            refusal.members(setOf("code", "issues"))
            corpusRequire(refusal["code"].stringValue() in setOf("invalidPrompt", "fileTooLarge", "convertedTooLarge"), "Unknown import refusal")
            refusal["issues"].strings()
            return
        }
        expected.members(setOf("source", "body", "mappings", "preservedKeys", "dropped", "warnings"))
        expected["source"].stringValue()
        expected["body"].stringValue()
        expected["preservedKeys"].strings()
        corpusRequire(expected["dropped"].strings().all { it == "frontMatterPresentation" }, "Unknown import loss")
        expected["mappings"].arrayValue().forEach {
            val mapping = it.objectValue()
            mapping.members(setOf("sourceKey", "fieldName", "kind", "defaultSource"))
            mapping["sourceKey"].stringValue()
            mapping["fieldName"].stringValue()
            corpusRequire(mapping["kind"].stringValue() in setOf("text", "multiline", "choice"), "Unknown mapping kind")
            nullableString(mapping["defaultSource"])
        }
        expected["warnings"].arrayValue().forEach {
            val warning = it.objectValue()
            when (warning["code"].stringValue()) {
                "unsupportedInput", "invalidName", "reservedName", "fieldCollision", "invalidOptions",
                "invalidDefault", "invalidDescription", "validation" -> {
                    warning.members(setOf("code", "key"))
                    warning["key"].stringValue()
                }
                "unsupportedTemplate" -> {
                    warning.members(setOf("code", "format", "byteOffset"))
                    corpusRequire(warning["format"].stringValue() in setOf("markdown", "dotprompt", "prompty"), "Unknown import format")
                    corpusRequire(warning["byteOffset"].integerValue().signum() >= 0, "Negative byte offset")
                }
                "identityReassigned" -> warning.members(setOf("code"))
                else -> throw CorpusException("Unknown import warning")
            }
        }
    }

    private fun paths(expected: JsonObject) {
        if ("issue" !in expected) {
            expected.members(setOf("path", "path_key"))
            expected["path"].stringValue()
            expected["path_key"].stringValue()
            return
        }
        expected.members(setOf("issue"))
        val issue = expected["issue"].objectValue()
        issue.members(setOf("code", "segment"))
        when (issue["code"].stringValue()) {
            "path.segment_empty", "path.segment_dot", "path.segment_hidden", "path.backslash",
            "path.control_character", "path.trailing_dot_or_space", "path.segment_too_long" ->
                corpusRequire(integerToken(issue["segment"]).signum() >= 0, "Negative path segment")
            "path.empty", "path.normalization_failed", "path.absolute", "path.too_long",
            "path.invalid_extension", "path.reserved_groups_prefix" ->
                corpusRequire(issue["segment"] == JsonNull, "Global path issue requires null segment")
            else -> throw CorpusException("Unknown path issue")
        }
    }

    private fun canonical(expected: JsonObject) {
        if ("error" in expected) {
            expected.members(setOf("error"))
            val error = expected["error"].objectValue()
            when (error["code"].stringValue()) {
                "invalid_prompt", "source_too_large" -> error.members(setOf("code"))
                "unsupported_format" -> {
                    error.members(setOf("code", "version"))
                    val version = error["version"].stringValue()
                    corpusRequire(Regex("[1-9][0-9]*").matches(version) && version.toBigInteger() > BigInteger.ONE, "Invalid future format")
                }
                else -> throw CorpusException("Unknown canonical error")
            }
            return
        }
        expected.members(setOf("bytes", "body", "canonicalHash", "favorite", "warnings"))
        expected["bytes"].stringValue()
        expected["body"].stringValue()
        corpusRequire(Regex("[0-9a-f]{64}").matches(expected["canonicalHash"].stringValue()), "Invalid canonical hash")
        if (expected["favorite"] != JsonNull) expected["favorite"].booleanValue()
        issues(expected["warnings"])
        expected["warnings"].arrayValue().forEach {
            val warning = it.objectValue()
            corpusRequire(warning["severity"].stringValue() == "warning" && warning["code"].stringValue() in
                setOf("template.invalid_placeholder", "field.unused", "metadata.group_private_removed"), "Unknown canonical warning")
        }
    }

    private fun scope(envelope: JsonObject) {
        corpusRequire(envelope["scope"].stringValue() in setOf("user", "group"), "Unknown scope")
    }

    private fun sourceName(value: JsonElement?, extensions: Set<String>, category: Category): String {
        val name = value.stringValue()
        val separators = if (category == Category.CANONICAL || category == Category.DTO) setOf('/', '\\') else setOf('/')
        corpusRequire(!name.startsWith(".") && name.none { it in separators } &&
            extensions.any { name.endsWith(it) }, "Invalid source basename")
        return name
    }

    private fun nullableString(value: JsonElement?) {
        if (value != JsonNull) value.stringValue()
    }

    private fun integerToken(value: JsonElement?): BigInteger {
        val primitive = value as? JsonPrimitive ?: throw CorpusException("Expected an integer token")
        corpusRequire(!primitive.isString && Regex("-?(0|[1-9][0-9]*)").matches(primitive.content), "Expected an integer token")
        return primitive.integerValue()
    }

    private fun timestamp(value: JsonElement?) {
        val text = value.stringValue()
        corpusRequire(Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z").matches(text), "Noncanonical UTC time")
        try {
            LocalDateTime.parse(text.dropLast(1), DateTimeFormatter.ISO_LOCAL_DATE_TIME)
        } catch (_: DateTimeParseException) {
            throw CorpusException("Invalid UTC time")
        }
    }
}
