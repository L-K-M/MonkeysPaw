package ch.lkmc.monkeyspaw.core.conformance

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.llm.ArtifactDiff
import ch.lkmc.monkeyspaw.core.domain.llm.ArtifactMerge
import ch.lkmc.monkeyspaw.core.domain.llm.ArtifactMergeResult
import ch.lkmc.monkeyspaw.core.domain.llm.LineDiffError
import ch.lkmc.monkeyspaw.core.domain.llm.LineDiffLine
import ch.lkmc.monkeyspaw.core.domain.llm.LlmArtifact
import ch.lkmc.monkeyspaw.core.domain.llm.MyersLineDiff
import ch.lkmc.monkeyspaw.core.domain.llm.PlaceholderChange
import ch.lkmc.monkeyspaw.core.llm.LlmOutputDecoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal object LlmDiffContracts {
    fun read(envelope: JsonObject): List<String> {
        val common = setOf("schema", "category", "kind", "operation", "expected")
        val operation = envelope["operation"].stringValue()
        val references = mutableListOf<String>()
        if (operation == "lines") {
            envelope.members(common + setOf("original", "merged"), setOf("originalRepeat", "mergedRepeat"))
            references.add(sourceName(envelope["original"], ".txt"))
            references.add(sourceName(envelope["merged"], ".txt"))
            count(envelope["originalRepeat"]); count(envelope["mergedRepeat"])
        } else {
            corpusRequire(operation in setOf("write", "improve"), "Unknown diff operation")
            envelope.members(common + setOf("artifact", "original", "filename", "id"), setOf("originalRepeat", "artifactBodyRepeat"))
            references.add(sourceName(envelope["artifact"], ".json"))
            envelope["filename"].stringValue()
            count(envelope["artifactBodyRepeat"])
            if (operation == "write") {
                corpusRequire(envelope["original"] == JsonNull && "originalRepeat" !in envelope &&
                    ULID.parse(envelope["id"].stringValue()) != null, "Invalid write diff baseline")
            } else {
                corpusRequire(envelope["id"] == JsonNull, "Improve diff cannot replace identity")
                references.add(sourceName(envelope["original"], ".md"))
                count(envelope["originalRepeat"])
            }
        }
        val expected = envelope["expected"].objectValue()
        if ("error" in expected) {
            expected.members(setOf("error"))
            corpusRequire(expected["error"].stringValue() in setOf("sourceTooLarge", "comparisonTooComplex"), "Unknown diff error")
        } else if (operation == "lines") {
            expected.members(setOf("rows"))
            rows(expected["rows"])
        } else {
            expected.members(setOf("frontMatter", "body", "placeholderWarnings", "originalCanonical", "candidate"))
            rows(expected["frontMatter"]); rows(expected["body"]); warnings(expected["placeholderWarnings"])
            corpusRequire((expected["originalCanonical"] == JsonNull) == (operation == "write"), "Wrong canonical baseline")
            if (operation == "improve") references.add(sourceName(expected["originalCanonical"], ".md"))
            references.add(sourceName(expected["candidate"], ".md"))
        }
        return references
    }

    private fun rows(value: JsonElement?) {
        for (row in value.arrayValue()) {
            val row = row.objectValue()
            row.members(setOf("kind", "text", "originalLine", "mergedLine", "placeholderWarnings"))
            val kind = row["kind"].stringValue()
            corpusRequire(kind in LineDiffLine.Kind.entries.map { it.rawValue }, "Unknown line kind")
            row["text"].stringValue()
            for ((key, absent) in listOf("originalLine" to (kind == "added"), "mergedLine" to (kind == "removed"))) {
                corpusRequire((row[key] == JsonNull) == absent, "Wrong line side")
                if (!absent) corpusRequire(row[key].integerValue().signum() > 0, "Invalid line number")
            }
            warnings(row["placeholderWarnings"])
        }
    }

    private fun warnings(value: JsonElement?) {
        for (warning in value.arrayValue()) {
            val warning = warning.objectValue()
            if (warning["kind"].stringValue() == "renamed") {
                warning.members(setOf("kind", "from", "to"))
                warning["from"].stringValue(); warning["to"].stringValue()
            } else {
                corpusRequire(warning["kind"].stringValue() in setOf("added", "removed"), "Unknown placeholder warning")
                warning.members(setOf("kind", "name"))
                warning["name"].stringValue()
            }
        }
    }

    fun count(value: JsonElement?): Int {
        if (value == null) return 1
        val count = value.integerValue()
        corpusRequire(count.signum() > 0 && count <= (Limits.maxPromptBytes + 1).toBigInteger(), "Invalid diff repeat")
        return count.intValueExact()
    }

    private fun sourceName(value: JsonElement?, extension: String): String {
        val name = value.stringValue()
        corpusRequire(!name.startsWith(".") && '/' !in name && '\\' !in name && name != "case.json" &&
            name.endsWith(extension), "Invalid diff source basename")
        return name
    }
}

internal object LlmDiffFixtures {
    fun consume(envelope: JsonObject, bytes: (String) -> ByteArray): JsonObject {
        val expected = envelope["expected"].objectValue()
        val oldGolden = expected["originalCanonical"]?.takeIf { it != JsonNull }?.let { bytes(it.stringValue()) }
        val newGolden = expected["candidate"]?.let { bytes(it.stringValue()) }
        fun text(key: String, repeatKey: String): String = expanded(strictUtf8(bytes(envelope[key].stringValue())),
            LlmDiffContracts.count(envelope[repeatKey]))

        return try {
            if (envelope["operation"].stringValue() == "lines") {
                val old = text("original", "originalRepeat")
                val new = text("merged", "mergedRepeat")
                val rows = MyersLineDiff.compare(old, new)
                assertBytesEqual(old.toByteArray(Charsets.UTF_8), project(rows, LineDiffLine.Kind.ADDED), "Original line reconstruction")
                assertBytesEqual(new.toByteArray(Charsets.UTF_8), project(rows, LineDiffLine.Kind.REMOVED), "Merged line reconstruction")
                buildJsonObject { put("rows", rows(rows)) }
            } else {
                val original = if (envelope["operation"].stringValue() == "improve")
                    PromptCodec.parse(text("original", "originalRepeat"), envelope["filename"].stringValue()) else null
                val decoded = LlmOutputDecoder.artifact(strictUtf8(bytes(envelope["artifact"].stringValue())))
                val artifact = LlmArtifact(decoded.title, decoded.description, decoded.tags, decoded.fields,
                    expanded(decoded.body, LlmDiffContracts.count(envelope["artifactBodyRepeat"])), decoded.notes)
                val merged = if (original == null) ArtifactMerge.write(artifact, ULID.parse(envelope["id"].stringValue())!!)
                    else ArtifactMerge.improve(artifact, original)
                corpusRequire(merged is ArtifactMergeResult.Ready, "Diff fixture requires a ready candidate")
                val candidate = (merged as ArtifactMergeResult.Ready).candidate
                val diff = ArtifactDiff.compare(original, candidate)
                corpusRequire(newGolden != null, "Unexpected ready diff")
                val canonicalOriginal = original?.let { PromptCodec.write(it).toByteArray(Charsets.UTF_8) }
                if (canonicalOriginal == null) corpusRequire(oldGolden == null, "Unexpected baseline bytes")
                else assertBytesEqual(oldGolden ?: error("Missing baseline"), canonicalOriginal, "Canonical original bytes")
                assertBytesEqual(newGolden!!, candidate.canonicalBytes, "Canonical candidate bytes")
                assertBytesEqual(oldGolden ?: byteArrayOf(), project(diff.frontMatter + diff.body, LineDiffLine.Kind.ADDED), "Original artifact reconstruction")
                assertBytesEqual(newGolden, project(diff.frontMatter + diff.body, LineDiffLine.Kind.REMOVED), "Merged artifact reconstruction")
                buildJsonObject {
                    put("frontMatter", rows(diff.frontMatter)); put("body", rows(diff.body))
                    put("placeholderWarnings", warnings(diff.placeholderWarnings))
                    put("originalCanonical", expected["originalCanonical"]!!)
                    put("candidate", expected["candidate"]!!)
                }
            }
        } catch (error: LineDiffError) { buildJsonObject {
            put("error", if (error == LineDiffError.SourceTooLarge) "sourceTooLarge" else "comparisonTooComplex")
        } }
    }

    private fun rows(rows: List<LineDiffLine>): JsonArray = JsonArray(rows.map { row -> buildJsonObject {
        put("kind", row.kind.rawValue); put("text", row.text)
        put("originalLine", row.originalLine?.let(::JsonPrimitive) ?: JsonNull)
        put("mergedLine", row.mergedLine?.let(::JsonPrimitive) ?: JsonNull)
        put("placeholderWarnings", warnings(row.placeholderWarnings))
    } })

    private fun warnings(warnings: List<PlaceholderChange>): JsonArray = JsonArray(warnings.map { change -> buildJsonObject {
        when (change) {
            is PlaceholderChange.Added -> { put("kind", "added"); put("name", change.name) }
            is PlaceholderChange.Removed -> { put("kind", "removed"); put("name", change.name) }
            is PlaceholderChange.Renamed -> { put("kind", "renamed"); put("from", change.from); put("to", change.to) }
        }
    } })

    private fun project(rows: List<LineDiffLine>, excluding: LineDiffLine.Kind): ByteArray =
        rows.filter { it.kind != excluding }.flatMap { it.bytes.asIterable() }.toByteArray()

    private fun expanded(text: String, count: Int): String {
        corpusRequire(text.toByteArray(Charsets.UTF_8).size <= (Limits.maxPromptBytes + 1) / count, "Invalid diff expansion")
        return text.repeat(count)
    }
}
