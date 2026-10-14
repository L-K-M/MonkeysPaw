package ch.lkmc.monkeyspaw.core.domain.llm

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.FieldOption
import ch.lkmc.monkeyspaw.core.domain.format.PortableYaml
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptDocument
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueSeverity
import ch.lkmc.monkeyspaw.core.domain.format.PromptWriteError
import ch.lkmc.monkeyspaw.core.domain.format.YamlNode
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ArtifactMergeTest {
    private val id = ULID.parse("01K6Z4V9KQWZX7MPQ4T8ZNB2PD")!!
    private val field = LlmArtifact.Field("tone", FieldKind.CHOICE, "Tone", "Help", "",
        listOf(FieldOption("Rust", "Rust"), FieldOption("Swift 6", "Swift")), false, true)

    private fun artifact(body: String = "New {{tone}}", fields: List<LlmArtifact.Field> = listOf(field)) =
        LlmArtifact("New", "Description", listOf("on", "010"), fields, body, "Session-only notes")

    private fun LlmArtifact.Field.changed(name: String = this.name, type: FieldKind = this.type,
        label: String = this.label, description: String = this.description, defaultValue: String = this.defaultValue,
        options: List<FieldOption> = this.options, optional: Boolean = this.optional, remember: Boolean = this.remember) =
        LlmArtifact.Field(name, type, label, description, defaultValue, options, optional, remember)

    private fun ready(result: ArtifactMergeResult): ArtifactMergeCandidate = assertIs<ArtifactMergeResult.Ready>(result).candidate
    private fun node(key: String, document: PromptDocument): YamlNode? =
        document.preservedHeader?.entries?.singleOrNull { PortableYaml.string(it.key) == key }?.value

    @Test fun replacesOnlyFiveContentAreasAndPreservesTypedUnknownMetadata() {
        val source = """
            ---
            id: 01k6z4v9kqwzx7mpq4t8znb2pd
            title: Old
            description: Old description
            tags: [old]
            fields: {old: {type: text}}
            favorite: true
            private: true
            format: 1
            model:
              settings: {enabled: true, count: 2, ratio: 1.5, absent: null}
              strings: ["on", "010", "true"]
              nested: [{second: [false, {deep: value}], first: 1}]
            extension: {"1": string key, 1: integer key}
            notes: User metadata
            ---
            Old {{old}}
        """.trimIndent()
        val original = PromptCodec.parse(source, "Unsaved.md")
        val value = artifact()
        val candidate = ready(ArtifactMerge.improve(value, original))
        val merged = candidate.document
        assertEquals(id, merged.frontMatter.id)
        assertEquals(value.title, merged.frontMatter.title)
        assertEquals(value.description, merged.frontMatter.description)
        assertEquals(value.tags, merged.frontMatter.tags)
        assertEquals(value.fields.map { it.name }, merged.frontMatter.fields.map { it.name })
        assertEquals(value.body, merged.body)
        assertTrue(merged.frontMatter.favorite)
        assertTrue(merged.frontMatter.isPrivate)
        assertEquals(original.frontMatter.format, merged.frontMatter.format)
        // Compare canonical trees without parser source marks or lexical styles.
        val canonicalOriginal = PromptCodec.parse(PromptCodec.write(original), "Original.md")
        for (key in listOf("model", "extension", "notes", "favorite", "private", "format", "id")) {
            assertEquals(typed(node(key, canonicalOriginal)), typed(node(key, merged)), key)
        }
        assertFalse(merged.source.contains(value.notes))
        assertContentEquals(PromptCodec.write(merged).toByteArray(), candidate.canonicalBytes)
        assertContentEquals(merged.source.toByteArray(), candidate.canonicalBytes)
        assertTrue(merged.issues.isEmpty())
        assertEquals(source, original.source)
    }

    @Test fun personalKeysAndIdentityKeepPresenceIncludingAbsentId() {
        for (identity in listOf("", "id: ${id.rawValue}\n")) {
            for (favorite in listOf("", "favorite: false\n", "favorite: true\n")) {
                for (privacy in listOf("", "private: false\n", "private: true\n")) {
                    for (format in listOf("", "format: 1\n")) {
                        val original = PromptCodec.parse("---\n$identity$favorite$privacy${format}title: Old\n---\nOld", "Old.md")
                        val merged = ready(ArtifactMerge.improve(artifact(), original)).document
                        assertEquals(original.frontMatter.id, merged.frontMatter.id)
                        assertEquals(original.frontMatter.favorite, merged.frontMatter.favorite)
                        assertEquals(original.frontMatter.isPrivate, merged.frontMatter.isPrivate)
                        assertEquals(original.frontMatter.format, merged.frontMatter.format)
                        for (key in listOf("id", "favorite", "private", "format")) {
                            assertEquals(typed(node(key, original)), typed(node(key, merged)), key)
                        }
                    }
                }
            }
        }
        val plain = ready(ArtifactMerge.improve(artifact(), PromptCodec.parse("Unsaved", "Old.md"))).document
        assertNull(plain.frontMatter.id)
        assertNull(node("id", plain))
        val written = ready(ArtifactMerge.write(artifact(), id)).document
        assertEquals(id, written.frontMatter.id)
        for (key in listOf("favorite", "private", "format", "notes", "model")) assertNull(node(key, written))
    }

    @Test fun optionsCollapseOnlyOnEqualUtf8AndEmptyDefaultsAreOmitted() {
        val options = listOf(FieldOption("Rust", "Rust"), FieldOption("Swift 6", "Swift"),
            FieldOption("true", "true"), FieldOption("é", "e\u0301"))
        val value = artifact(fields = listOf(field.changed(options = options)))
        val merged = ready(ArtifactMerge.write(value, id)).document
        val tone = assertIs<YamlNode.Mapping>(node("fields", merged)).entries.single().value as YamlNode.Mapping
        assertFalse(tone.entries.any { PortableYaml.string(it.key) == "default" })
        val nodes = assertIs<YamlNode.Sequence>(tone.entries.single { PortableYaml.string(it.key) == "options" }.value).values
        assertEquals("Rust", PortableYaml.string(nodes[0]))
        assertIs<YamlNode.Mapping>(nodes[1])
        assertEquals("true", PortableYaml.string(nodes[2]))
        assertIs<YamlNode.Mapping>(nodes[3])
        assertEquals(options, merged.frontMatter.fields.single().options)
        assertEquals("", merged.frontMatter.fields.single().defaultValue)
    }

    @Test fun allFieldPropertiesAndExactBodyBytesRoundTrip() {
        val updated = field.changed(label = "on", description = "line one\n---\nline two", defaultValue = "Swift",
            optional = true, remember = false)
        val body = "\uFEFF  文書 {{tone}}\r\ne\u0301\n\n"
        val merged = ready(ArtifactMerge.write(artifact(body, listOf(updated)), id)).document
        val converted = merged.frontMatter.fields.single()
        assertEquals(updated.name, converted.name)
        assertEquals(updated.type, converted.kind)
        assertEquals(updated.label, converted.label)
        assertEquals(updated.description, converted.description)
        assertEquals(updated.defaultValue, converted.defaultValue)
        assertEquals(updated.options, converted.options)
        assertTrue(converted.optional)
        assertFalse(converted.remember)
        assertContentEquals(body.toByteArray(), merged.body.toByteArray())
    }

    @Test fun invalidOriginalAndArtifactNeverBecomeReady() {
        for (source in listOf("---\nprivate: on\n---\nOld", "---\nformat: 2\n---\nOld", "---\nid: bad\n---\nOld",
            "---\nmodel: {duplicate: 1, duplicate: 2}\n---\nOld", "---\nmodel: [\n---\nOld", "Old {{unfinished")) {
            val original = PromptCodec.parse(source, "Old.md")
            assertEquals(original.issues, assertIs<ArtifactMergeResult.Invalid>(ArtifactMerge.improve(artifact(), original)).issues)
        }
        val malformedFile = PromptCodec.parseFile(byteArrayOf(0xed.toByte(), 0xa0.toByte(), 0x80.toByte()), "Old.md")
        assertEquals(PromptIssueCode.INVALID_UTF8,
            assertIs<ArtifactMergeResult.Invalid>(ArtifactMerge.improve(artifact(), malformedFile)).issues.single().code)
        for (value in listOf(artifact("{{unfinished"), artifact("{{uuid}}"),
            artifact(fields = listOf(field.changed(name = "not valid"))), artifact(fields = listOf(field.changed(options = emptyList()))),
            artifact(fields = listOf(field.changed(defaultValue = "not an option"))),
            artifact(fields = listOf(field.changed(type = FieldKind.TEXT))))) {
            val issues = assertIs<ArtifactMergeResult.Invalid>(ArtifactMerge.write(value, id)).issues
            assertEquals(value.issues, issues)
            assertTrue(issues.any { it.severity == PromptIssueSeverity.ERROR })
        }
    }

    @Test fun reparseRejectsInvalidFinalBytesEvenForDirectlyConstructedArtifacts() {
        // Wire decoding rejects duplicates first; the pure domain entry point also fails closed.
        val duplicate = artifact(fields = listOf(field, field))
        assertTrue(duplicate.issues.none { it.severity == PromptIssueSeverity.ERROR })
        val result = assertIs<ArtifactMergeResult.Invalid>(ArtifactMerge.write(duplicate, id))
        assertTrue(result.issues.any { it.code == PromptIssueCode.DUPLICATE_KEY })
        val invalidText = LlmArtifact("\uD800", "", emptyList(), emptyList(), "Body", "")
        assertEquals(PromptWriteError.SerializationFailed, assertIs<ArtifactMergeResult.Failed>(ArtifactMerge.write(invalidText, id)).error)
    }

    @Test fun warningsStayVisibleAndCanonicalOutputHonorsUtf8Cap() {
        val warnings = ready(ArtifactMerge.write(artifact("{{#if x}}"), id)).document.issues
        assertTrue(warnings.isNotEmpty())
        assertTrue(warnings.all { it.severity == PromptIssueSeverity.WARNING })
        for (body in listOf("x".repeat(Limits.maxPromptBytes), "é".repeat(Limits.maxPromptBytes / 2))) {
            assertEquals(PromptWriteError.SourceTooLarge,
                assertIs<ArtifactMergeResult.Failed>(ArtifactMerge.write(artifact(body, emptyList()), id)).error)
        }
        assertIs<ArtifactMergeResult.Invalid>(ArtifactMerge.write(artifact("x".repeat(Limits.maxPromptBytes + 1), emptyList()), id))
        val headerSize = ready(ArtifactMerge.write(artifact("", emptyList()), id)).canonicalBytes.size
        val boundary = ready(ArtifactMerge.write(artifact("x".repeat(Limits.maxPromptBytes - headerSize), emptyList()), id))
        assertEquals(Limits.maxPromptBytes, boundary.canonicalBytes.size)
        assertNotNull(boundary.document.frontMatter.id)
        val bytes = boundary.canonicalBytes
        bytes[0] = 0
        assertEquals('-'.code.toByte(), boundary.canonicalBytes[0])
    }

    private fun typed(node: YamlNode?): Any? = when (node) {
        null -> null
        is YamlNode.Scalar -> node.tag to node.value
        is YamlNode.Sequence -> node.values.map(::typed)
        is YamlNode.Mapping -> node.entries.map { typed(it.key) to typed(it.value) }
        is YamlNode.Rejected -> error("Rejected YAML")
    }
}
