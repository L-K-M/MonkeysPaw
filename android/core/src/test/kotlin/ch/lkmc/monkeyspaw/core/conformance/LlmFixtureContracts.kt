package ch.lkmc.monkeyspaw.core.conformance

import java.math.BigInteger
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

    private fun result(result: JsonObject, outputKind: String) {
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
