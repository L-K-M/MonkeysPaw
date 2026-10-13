package ch.lkmc.monkeyspaw.core.conformance

import ch.lkmc.monkeyspaw.core.domain.format.FrontMatter
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptField
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
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

/** Every format/validation case has completed parsing assertions and named downstream obligations. */
internal class ParsingConformanceTest {
    @Test fun everyParsingExpectationAndPendingSliceIsAccounted() {
        val corpus = Corpus.load()
        val registrations = corpus.cases.filter { it.category in setOf(Category.FORMAT, Category.VALIDATION) }
            .map(::registration)
        assertEquals(corpus.cases(Category.FORMAT).size + corpus.cases(Category.VALIDATION).size, registrations.size)
        val checkedFiles = registrations.flatMap { it.fixture.files }.map { it.relativePath }.toSet()
        assertEquals(corpus.cases.filter { it.category in setOf(Category.FORMAT, Category.VALIDATION) }
            .flatMap { it.files }.map { it.relativePath }.toSet(), checkedFiles)

        for (entry in registrations) {
            val fixture = entry.fixture
            assertEquals(fixture.expected.keys, entry.completed + entry.pending.keys,
                "Unregistered expectation in ${fixture.envelopeFile.relativePath}")
            entry.pending.values.forEach { assertTrue(it.slice in setOf("K4", "K5") && it.reason.isNotBlank()) }
            checkParsing(entry)
        }
        val format = registrations.filter { it.fixture.category == Category.FORMAT }
        val validation = registrations.filter { it.fixture.category == Category.VALIDATION }
        println("K3 parsing: ${format.size} format cases, ${validation.size} validation cases, ${checkedFiles.size} files; " +
            "complete issue expectations ${registrations.count { "issues" in it.completed }}; " +
            "K4 pending cases ${registrations.count { it.pending.values.any { it.slice == "K4" } }}; " +
            "K5 pending cases ${registrations.count { it.pending.values.any { it.slice == "K5" } }}.")
    }

    private data class Pending(val slice: String, val reason: String)
    private data class Registration(val fixture: FixtureCase, val completed: Set<String>, val pending: Map<String, Pending>)

    private fun registration(fixture: FixtureCase): Registration = when (fixture.category) {
        Category.FORMAT -> Registration(fixture, setOf("metadata", "body", "issues"),
            mapOf("canonical" to Pending("K5", "Exact canonical writer bytes")))
        Category.VALIDATION -> {
            val pendingIssues = fixture.expected["issues"].arrayValue().any {
                isK4Issue(fixture, it.objectValue()["code"].stringValue())
            }
            Registration(fixture, setOf("private", "readOnly") + if (pendingIssues) emptySet() else setOf("issues"),
                mapOf("fields" to Pending("K4", "Effective fields require template first-use assembly"),
                    "canRender" to Pending("K4", "Final validation and template errors control rendering"),
                    "canWrite" to Pending("K5", "Writer refusal after final validation")) +
                    if (pendingIssues) mapOf("issues" to Pending("K4", "Parsing prefix checked now; template/validator suffix pending")) else emptyMap())
        }
        else -> error("Parsing registration requires format or validation")
    }

    private fun isK4Issue(fixture: FixtureCase, code: String): Boolean =
        code in setOf("field.unused", "template.invalid_placeholder", "template.unbalanced_opener") ||
            (code == "field.reserved_name" && fixture.name in implicitReservedCases)

    private fun checkParsing(entry: Registration) {
        val fixture = entry.fixture
        val count = (fixture.envelope["repeat"]?.integerValue() ?: BigInteger.ONE).intValueExact()
        val source = fixture.source().utf8().repeat(count)
        val document = PromptCodec.parse(source, fixture.envelope["filename"].stringValue())
        val label = fixture.envelopeFile.relativePath
        assertUtf8Equal(source, document.source, "$label source")
        val expectedIssues = JsonArray(fixture.expected["issues"].arrayValue().filterNot {
            isK4Issue(fixture, it.objectValue()["code"].stringValue())
        })
        assertEquals(expectedIssues, JsonArray(document.decodingIssues.map(::issueJson)), "$label parsing issues")
        when (fixture.category) {
            Category.FORMAT -> {
                assertEquals(fixture.expected["metadata"], metadataJson(document.frontMatter), "$label metadata")
                assertUtf8Equal(fixture.expected["body"].stringValue(), document.body, "$label body")
            }
            Category.VALIDATION -> {
                assertEquals(fixture.expected["private"].booleanValue(), document.frontMatter.isPrivate, "$label private")
                assertEquals(fixture.expected["readOnly"].booleanValue(), document.isReadOnly, "$label readOnly")
                // Compare all reachable declared-field properties; implicit/order/exclusion work stays in K4.
                for (field in fixture.expected["fields"].arrayValue().map { it.objectValue() }) {
                    if (field["implicit"].booleanValue()) continue
                    val name = field["name"].stringValue()
                    val declaration = document.frontMatter.fields.single { it.name == name }
                    assertEquals(field, fieldJson(declaration), "$label declaration $name")
                }
            }
            else -> error("Unexpected parsing category")
        }
    }

    private fun metadataJson(metadata: FrontMatter): JsonObject = buildJsonObject {
        put("id", metadata.id?.let(::JsonPrimitive) ?: JsonNull)
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

    private companion object {
        // These corpus cases pin inference of reserved names, which is explicitly K4's responsibility.
        val implicitReservedCases = setOf("reserved-implicit-cursor", "reserved-implicit-datetime",
            "reserved-implicit-selection", "reserved-implicit-uuid")
    }
}
