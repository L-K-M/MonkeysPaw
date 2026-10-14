package ch.lkmc.monkeyspaw.core.conformance

import java.math.BigInteger
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.llm.LlmReviewSeverity
import ch.lkmc.monkeyspaw.core.domain.llm.LlmRubricCriterion
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject

internal object LlmFixtureContracts {
    fun read(envelope: JsonObject): List<String> {
        corpusRequire(envelope["schema"].integerValue() == BigInteger.ONE, "Unknown LLM schema version")
        corpusRequire(envelope["category"].stringValue() == "llm", "Wrong LLM category")
        if (envelope["kind"].stringValue() == "merge") return merge(envelope)
        if (envelope["kind"].stringValue() == "exchange") return LlmExchangeContracts.read(envelope)
        val outputKind = envelope["outputKind"].stringValue()
        corpusRequire(outputKind in setOf("artifact", "review"), "Unknown LLM output kind")
        val expected = envelope["expected"].objectValue()
        val common = setOf("schema", "category", "kind", "outputKind", "expected")
        return when (envelope["kind"].stringValue()) {
            "schema" -> {
                envelope.members(common)
                expected.members(setOf("bytes"))
                listOf(sourceName(expected["bytes"], setOf(".json")))
            }
            "decode" -> {
                envelope.members(common + "source" + if (outputKind == "review") setOf("reviewedSource") else emptySet(),
                    setOf("prefix") + if (outputKind == "review") setOf("reviewedRepeat") else emptySet())
                val references = mutableListOf(sourceName(envelope["source"], setOf(".txt", ".bin")))
                envelope["prefix"]?.let {
                    val prefix = it.objectValue()
                    prefix.members(setOf("source", "repeat"))
                    positiveCount(prefix["repeat"], 2_097_153)
                    references.add(sourceName(prefix["source"], setOf(".txt")))
                }
                if (outputKind == "review") {
                    references.add(sourceName(envelope["reviewedSource"], setOf(".md")))
                    envelope["reviewedRepeat"]?.let { positiveCount(it, 262_145) }
                }
                expected.members(setOf("recovered", "parsed", "result"))
                expected["parsed"].booleanValue()
                if (expected["recovered"] != JsonNull) references.add(sourceName(expected["recovered"], setOf(".json")))
                result(expected["result"].objectValue(), outputKind)
                references
            }
            else -> throw CorpusException("Unknown LLM fixture kind")
        }
    }

    private fun merge(envelope: JsonObject): List<String> {
        envelope.members(setOf("schema", "category", "kind", "operation", "artifact", "original", "filename", "id", "expected"),
            setOf("originalRepeat", "artifactBodyRepeat"))
        val operation = envelope["operation"].stringValue()
        corpusRequire(operation in setOf("write", "improve"), "Unknown merge operation")
        envelope["filename"].stringValue()
        val references = mutableListOf(sourceName(envelope["artifact"], setOf(".json")))
        if (operation == "write") {
            corpusRequire(envelope["original"] == JsonNull && ULID.parse(envelope["id"].stringValue()) != null &&
                "originalRepeat" !in envelope, "Invalid write inputs")
        } else {
            corpusRequire(envelope["id"] == JsonNull, "Improve must retain original identity")
            references.add(sourceName(envelope["original"], setOf(".md", ".bin")))
        }
        listOf("originalRepeat", "artifactBodyRepeat").forEach { key -> envelope[key]?.let { positiveCount(it, 262_145) } }
        val expected = envelope["expected"].objectValue()
        when {
            "ready" in expected -> {
                expected.members(setOf("ready"))
                val ready = expected["ready"].objectValue()
                ready.members(setOf("candidate", "id", "issues", "preserved"))
                references.add(sourceName(ready["candidate"], setOf(".md")))
                corpusRequire(ready["id"] == JsonNull || ULID.parse(ready["id"].stringValue()) != null, "Invalid candidate ID")
                issues(ready["issues"])
                ready["preserved"].arrayValue().forEach(::yamlPair)
            }
            "invalid" in expected -> { expected.members(setOf("invalid")); issues(expected["invalid"]) }
            "failed" in expected -> {
                expected.members(setOf("failed"))
                val failed = expected["failed"].objectValue()
                val error = failed["error"].stringValue()
                failed.members(setOf("error") + if (error == "unsupportedFormat") setOf("format") else emptySet())
                corpusRequire(error in setOf("invalidPrompt", "serializationFailed", "sourceTooLarge", "unsupportedFormat"), "Unknown write error")
                if (error == "unsupportedFormat") failed["format"].stringValue()
            }
            else -> {
                expected.members(setOf("error"))
                corpusRequire(expected["error"].stringValue() == "invalidOutput", "Unknown merge decoding error")
            }
        }
        return references
    }

    private fun issues(value: JsonElement?) {
        value.arrayValue().forEach {
            val issue = it.objectValue()
            issue.members(setOf("code", "severity", "location"))
            corpusRequire(issue["code"].stringValue() in PromptIssueCode.entries.map { code -> code.rawValue }, "Unknown merge issue")
            corpusRequire(issue["severity"].stringValue() in setOf("error", "warning"), "Unknown merge issue severity")
            if (issue["location"] != JsonNull) {
                val location = issue["location"].objectValue()
                if ("bodyByteOffset" in location) {
                    location.members(setOf("bodyByteOffset")); nonnegative(location["bodyByteOffset"])
                } else {
                    location.members(setOf("line", "column"))
                    corpusRequire(location["line"].integerValue().signum() > 0 && location["column"].integerValue().signum() > 0,
                        "Invalid merge issue location")
                }
            }
        }
    }

    private fun yamlPair(value: JsonElement) {
        val pair = value.objectValue()
        pair.members(setOf("key", "value"))
        yamlNode(pair["key"]); yamlNode(pair["value"])
    }

    private fun yamlNode(value: JsonElement?) {
        val node = value.objectValue()
        node.members(setOf("tag", "value"))
        when (node["tag"].stringValue()) {
            "map" -> node["value"].arrayValue().forEach(::yamlPair)
            "seq" -> node["value"].arrayValue().forEach(::yamlNode)
            "str", "int", "float", "bool", "null" -> node["value"].stringValue()
            else -> throw CorpusException("Unknown preserved YAML tag")
        }
    }

    fun result(result: JsonObject, outputKind: String) {
        if ("error" in result) {
            result.members(setOf("error"))
            corpusRequire(result["error"].stringValue() == "invalidOutput", "Unknown LLM error")
        } else if (outputKind == "artifact") {
            result.members(setOf("artifact", "issues"))
            val artifact = result["artifact"].objectValue()
            artifact.members(setOf("title", "description", "tags", "fields", "body", "notes"))
            listOf("title", "description", "body", "notes").forEach { artifact[it].stringValue() }
            artifact["tags"].strings()
            artifact["fields"].arrayValue().forEach {
                val field = it.objectValue()
                field.members(setOf("name", "type", "label", "description", "default", "options", "optional", "remember"))
                listOf("name", "label", "description", "default").forEach { key -> field[key].stringValue() }
                corpusRequire(field["type"].stringValue() in setOf("text", "multiline", "choice"), "Unknown LLM field type")
                field["optional"].booleanValue()
                field["remember"].booleanValue()
                field["options"].arrayValue().forEach { item ->
                    val option = item.objectValue()
                    option.members(setOf("label", "value"))
                    option["label"].stringValue(); option["value"].stringValue()
                }
            }
            result["issues"].arrayValue().forEach {
                val issue = it.objectValue()
                issue.members(setOf("code", "severity", "location"))
                corpusRequire(issue["code"].stringValue() in PromptIssueCode.entries.map { code -> code.rawValue }, "Unknown LLM issue")
                corpusRequire(issue["severity"].stringValue() in setOf("error", "warning"), "Unknown LLM issue severity")
                if (issue["location"] != JsonNull) {
                    val location = issue["location"].objectValue()
                    location.members(setOf("bodyByteOffset"))
                    nonnegative(location["bodyByteOffset"])
                }
            }
        } else {
            result.members(setOf("review"))
            val review = result["review"].objectValue()
            review.members(setOf("summary", "findings"))
            review["summary"].stringValue()
            review["findings"].arrayValue().forEach {
                val finding = it.objectValue()
                finding.members(setOf("severity", "criterion", "quote", "problem", "suggestion", "quoteMatch"))
                corpusRequire(finding["severity"].stringValue() in LlmReviewSeverity.entries.map { severity -> severity.rawValue }, "Unknown LLM severity")
                corpusRequire(finding["criterion"].stringValue() in LlmRubricCriterion.entries.map { criterion -> criterion.rawValue }, "Unknown LLM criterion")
                listOf("quote", "problem", "suggestion").forEach { key -> finding[key].stringValue() }
                if (finding["quoteMatch"] != JsonNull) {
                    val match = finding["quoteMatch"].objectValue()
                    match.members(setOf("startByte", "endByteExclusive"))
                    nonnegative(match["startByte"])
                    corpusRequire(match["endByteExclusive"].integerValue() > match["startByte"].integerValue(), "Empty quote range")
                }
            }
        }
    }

    private fun nonnegative(value: JsonElement?) { corpusRequire(value.integerValue().signum() >= 0, "Negative byte offset") }
    private fun positiveCount(value: JsonElement?, cap: Int) {
        val count = value.integerValue()
        corpusRequire(count.signum() > 0 && count <= cap.toBigInteger(), "Invalid LLM repeat count")
    }
    private fun sourceName(value: JsonElement?, extensions: Set<String>): String {
        val name = value.stringValue()
        corpusRequire(!name.startsWith(".") && '/' !in name && '\\' !in name && name != "case.json" &&
            extensions.any { name.endsWith(it) }, "Invalid LLM source basename")
        return name
    }
}
