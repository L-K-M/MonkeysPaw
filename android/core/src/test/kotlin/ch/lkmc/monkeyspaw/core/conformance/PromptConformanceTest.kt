package ch.lkmc.monkeyspaw.core.conformance

import ch.lkmc.monkeyspaw.core.domain.format.FrontMatter
import ch.lkmc.monkeyspaw.core.domain.format.PromptBuiltinValues
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptField
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
import ch.lkmc.monkeyspaw.core.domain.format.PromptRenderError
import ch.lkmc.monkeyspaw.core.domain.format.PromptRenderer
import ch.lkmc.monkeyspaw.core.domain.format.PromptValidator
import ch.lkmc.monkeyspaw.core.domain.format.TemplateToken
import java.math.BigInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** All content cases are enumerated; only actual writer expectations remain pending for K5. */
internal class PromptConformanceTest {
    @Test fun everyContentExpectationAndPendingSliceIsAccounted() {
        val corpus = Corpus.load()
        val registrations = corpus.cases.filter { it.category in categories }
            .map(::registration)
        assertEquals(categories.sumOf { corpus.cases(it).size }, registrations.size)
        val checkedFiles = registrations.flatMap { it.fixture.files }.map { it.relativePath }.toSet()
        assertEquals(corpus.cases.filter { it.category in categories }
            .flatMap { it.files }.map { it.relativePath }.toSet(), checkedFiles)

        for (entry in registrations) {
            val fixture = entry.fixture
            assertEquals(fixture.expected.keys, entry.completed + entry.pending.keys,
                "Unregistered expectation in ${fixture.envelopeFile.relativePath}")
            entry.pending.values.forEach { assertTrue(it.slice == "K5" && it.reason.isNotBlank()) }
            checkContent(entry)
        }
        for (category in categories) {
            val entries = registrations.filter { it.fixture.category == category }
            println("${category.directory}: ${entries.size} cases / ${entries.sumOf { it.fixture.files.size }} files; " +
                "completed expectations ${entries.sumOf { it.completed.size }}; K5 pending ${entries.sumOf { it.pending.size }}.")
        }
        println("Content conformance: ${registrations.size} cases / ${checkedFiles.size} files; " +
            "${registrations.count { "issues" in it.completed }} complete issue lists; K4 pending 0; " +
            "K5 pending cases ${registrations.count { it.pending.isNotEmpty() }}, " +
            "expectations ${registrations.sumOf { it.pending.size }}.")
    }

    private data class Pending(val slice: String, val reason: String)
    private data class Registration(val fixture: FixtureCase, val completed: Set<String>, val pending: Map<String, Pending>)

    private fun registration(fixture: FixtureCase): Registration = when (fixture.category) {
        Category.FORMAT -> Registration(fixture, setOf("metadata", "body", "issues"),
            mapOf("canonical" to Pending("K5", "Exact canonical writer bytes")))
        Category.GRAMMAR -> Registration(fixture, setOf("tokens", "names", "fields", "issues"), emptyMap())
        Category.RENDER -> Registration(fixture, setOf("fields", "builtins", "issues", "result"), emptyMap())
        Category.VALIDATION -> Registration(fixture, setOf("private", "readOnly", "issues", "fields", "canRender"),
            mapOf("canWrite" to Pending("K5", "Writer refusal after final validation")))
        else -> error("Unsupported content category")
    }

    private fun checkContent(entry: Registration) {
        val fixture = entry.fixture
        val count = (fixture.envelope["repeat"]?.integerValue() ?: BigInteger.ONE).intValueExact()
        val source = fixture.source().utf8().repeat(count)
        val document = PromptCodec.parse(source, fixture.envelope["filename"].stringValue())
        val label = fixture.envelopeFile.relativePath
        assertUtf8Equal(source, document.source, "$label source")
        assertEquals(document.issues, PromptValidator.validate(document), "$label validator")
        assertEquals(fixture.expected["issues"], JsonArray(document.issues.map(::issueJson)), "$label issues")
        if (fixture.category != Category.FORMAT) {
            assertEquals(fixture.expected["fields"], JsonArray(document.effectiveFields.map(::fieldJson)), "$label fields")
        }
        when (fixture.category) {
            Category.FORMAT -> {
                assertEquals(fixture.expected["metadata"], metadataJson(document.frontMatter), "$label metadata")
                assertUtf8Equal(fixture.expected["body"].stringValue(), document.body, "$label body")
            }
            Category.VALIDATION -> {
                assertEquals(fixture.expected["private"].booleanValue(), document.frontMatter.isPrivate, "$label private")
                assertEquals(fixture.expected["readOnly"].booleanValue(), document.isReadOnly, "$label readOnly")
                assertEquals(fixture.expected["canRender"].booleanValue(), document.canRender, "$label canRender")
            }
            Category.GRAMMAR -> {
                assertEquals(fixture.expected["tokens"], JsonArray(document.template.tokens.map(::tokenJson)), "$label tokens")
                assertEquals(fixture.expected["names"].strings(), document.template.names, "$label names")
            }
            Category.RENDER -> {
                assertEquals(fixture.expected["builtins"].strings(), document.template.builtins.map { it.rawValue }, "$label builtins")
                val values = fixture.envelope["values"]?.objectValue()?.mapValues { it.value.stringValue() } ?: emptyMap()
                val snapshots = fixture.envelope["builtins"]?.objectValue()?.mapValues { it.value.stringValue() } ?: emptyMap()
                val result = try {
                    val text = PromptRenderer.render(document, values,
                        PromptBuiltinValues(snapshots["clipboard"], snapshots["date"], snapshots["time"]))
                    assertUtf8Equal(fixture.expected["result"].objectValue()["text"].stringValue(), text, "$label rendered bytes")
                    buildJsonObject { put("text", text) }
                } catch (error: PromptRenderError) {
                    renderFailure(error)
                }
                assertEquals(fixture.expected["result"], result, "$label result")
            }
            else -> error("Unexpected content category")
        }
    }

    private fun metadataJson(metadata: FrontMatter): JsonObject = buildJsonObject {
        put("id", metadata.id?.rawValue?.let(::JsonPrimitive) ?: JsonNull)
        put("title", metadata.title)
        put("description", metadata.description?.let(::JsonPrimitive) ?: JsonNull)
        put("tags", JsonArray(metadata.tags.map(::JsonPrimitive)))
        put("favorite", metadata.favorite)
        put("private", metadata.isPrivate)
        put("format", metadata.format.decimalValue)
        put("declarations", JsonArray(metadata.fields.map(::fieldJson)))
    }

    private fun fieldJson(field: PromptField): JsonObject = buildJsonObject {
        put("name", field.name)
        put("type", field.kind.rawValue)
        put("label", field.label)
        put("description", field.description?.let(::JsonPrimitive) ?: JsonNull)
        put("default", field.defaultValue)
        put("options", JsonArray(field.options.map { option -> buildJsonObject { put("label", option.label); put("value", option.value) } }))
        put("optional", field.optional)
        put("remember", field.remember)
        put("implicit", field.isImplicit)
    }

    private fun issueJson(issue: PromptIssue): JsonObject = buildJsonObject {
        put("code", issue.code.rawValue)
        put("severity", issue.severity.rawValue)
    }

    private fun tokenJson(token: TemplateToken): JsonObject = buildJsonObject {
        when (token) {
            is TemplateToken.Literal -> { put("kind", "literal"); put("text", token.text) }
            TemplateToken.EscapedOpener -> put("kind", "escape")
            is TemplateToken.Placeholder -> { put("kind", "placeholder"); put("name", token.name) }
        }
    }

    private fun renderFailure(error: PromptRenderError): JsonObject = buildJsonObject {
        when (error) {
            PromptRenderError.InvalidPrompt -> put("error", "invalid_prompt")
            is PromptRenderError.UnsupportedFormat -> { put("error", "unsupported_format"); put("version", error.version.decimalValue) }
            is PromptRenderError.MissingRequiredValue -> { put("error", "required_value_missing"); put("field", error.field) }
            is PromptRenderError.InvalidChoiceValue -> { put("error", "choice_value_invalid"); put("field", error.field) }
            is PromptRenderError.MissingBuiltin -> { put("error", "builtin_missing"); put("name", error.name.rawValue) }
        }
    }

    private companion object {
        val categories = setOf(Category.FORMAT, Category.GRAMMAR, Category.RENDER, Category.VALIDATION)
    }
}
