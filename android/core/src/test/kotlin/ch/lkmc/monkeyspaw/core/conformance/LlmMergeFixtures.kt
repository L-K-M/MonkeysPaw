package ch.lkmc.monkeyspaw.core.conformance

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.PortableYaml
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueLocation
import ch.lkmc.monkeyspaw.core.domain.format.PromptWriteError
import ch.lkmc.monkeyspaw.core.domain.format.YamlNode
import ch.lkmc.monkeyspaw.core.domain.llm.ArtifactMerge
import ch.lkmc.monkeyspaw.core.domain.llm.ArtifactMergeResult
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantError
import ch.lkmc.monkeyspaw.core.domain.llm.LlmArtifact
import ch.lkmc.monkeyspaw.core.llm.LlmOutputDecoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal object LlmMergeFixtures {
    fun consume(envelope: JsonObject, bytes: (String) -> ByteArray): JsonObject {
        val output = strictUtf8(bytes(envelope["artifact"].stringValue()))
        val original = if (envelope["operation"].stringValue() == "improve") {
            val name = envelope["original"].stringValue()
            val source = bytes(name)
            if (name.endsWith(".md")) strictUtf8(source)
            val count = envelope["originalRepeat"]?.integerValue()?.intValueExact() ?: 1
            corpusRequire(source.size <= (Limits.maxPromptBytes + 1) / count, "Invalid original expansion")
            PromptCodec.parseFile(ByteArray(source.size * count) { source[it % source.size] }, envelope["filename"].stringValue())
        } else null
        // Consume a ready golden even if production unexpectedly returns an invalid outcome.
        val ready = envelope["expected"].objectValue()["ready"]?.objectValue()
        val candidateName = ready?.get("candidate")?.stringValue()
        val golden = candidateName?.let(bytes)
        return try {
            val decoded = LlmOutputDecoder.artifact(output)
            val count = envelope["artifactBodyRepeat"]?.integerValue()?.intValueExact() ?: 1
            corpusRequire(decoded.body.toByteArray(Charsets.UTF_8).size <= (Limits.maxPromptBytes + 1) / count,
                "Invalid artifact expansion")
            val artifact = LlmArtifact(decoded.title, decoded.description, decoded.tags, decoded.fields,
                decoded.body.repeat(count), decoded.notes)
            val result = if (original == null) ArtifactMerge.write(artifact, ULID.parse(envelope["id"].stringValue())!!)
                else ArtifactMerge.improve(artifact, original)
            when (result) {
                is ArtifactMergeResult.Ready -> {
                    corpusRequire(candidateName != null, "Unexpected ready merge")
                    assertBytesEqual(golden!!, result.candidate.canonicalBytes, "Merge candidate bytes")
                    val document = result.candidate.document
                    assertBytesEqual(document.source.toByteArray(Charsets.UTF_8), result.candidate.canonicalBytes, "Candidate source bytes")
                    buildJsonObject { put("ready", buildJsonObject {
                        put("candidate", candidateName)
                        put("id", document.frontMatter.id?.rawValue?.let(::JsonPrimitive) ?: JsonNull)
                        put("issues", issues(document.issues))
                        put("preserved", JsonArray(document.preservedHeader!!.entries.filter {
                            PortableYaml.string(it.key) !in setOf("title", "description", "tags", "fields")
                        }.map { pair(it) }))
                    }) }
                }
                is ArtifactMergeResult.Invalid -> buildJsonObject { put("invalid", issues(result.issues)) }
                is ArtifactMergeResult.Failed -> buildJsonObject { put("failed", buildJsonObject {
                    put("error", when (result.error) {
                        PromptWriteError.InvalidPrompt -> "invalidPrompt"
                        PromptWriteError.SerializationFailed -> "serializationFailed"
                        PromptWriteError.SourceTooLarge -> "sourceTooLarge"
                        is PromptWriteError.UnsupportedFormat -> "unsupportedFormat"
                    })
                    (result.error as? PromptWriteError.UnsupportedFormat)?.let { put("format", it.version.decimalValue) }
                }) }
            }
        } catch (_: AssistantError.InvalidOutput) { buildJsonObject { put("error", "invalidOutput") } }
    }

    private fun issues(issues: List<PromptIssue>): JsonArray = JsonArray(issues.map { issue -> buildJsonObject {
        put("code", issue.code.rawValue); put("severity", issue.severity.rawValue)
        put("location", when (val location = issue.location) {
            null -> JsonNull
            is PromptIssueLocation.Body -> buildJsonObject { put("bodyByteOffset", location.byteOffset) }
            is PromptIssueLocation.FrontMatter -> buildJsonObject { put("line", location.line); put("column", location.column) }
        })
    } })

    private fun pair(entry: YamlNode.Entry): JsonObject = buildJsonObject {
        put("key", yaml(entry.key)); put("value", yaml(entry.value))
    }

    private fun yaml(node: YamlNode): JsonObject = buildJsonObject {
        put("tag", node.tag.substringAfterLast(':'))
        val value: JsonElement = when (node) {
            is YamlNode.Scalar -> JsonPrimitive(node.value)
            is YamlNode.Sequence -> JsonArray(node.values.map(::yaml))
            is YamlNode.Mapping -> JsonArray(node.entries.map(::pair))
            is YamlNode.Rejected -> throw CorpusException("Rejected preserved YAML")
        }
        put("value", value)
    }
}
