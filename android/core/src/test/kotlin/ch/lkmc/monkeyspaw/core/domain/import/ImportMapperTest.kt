package ch.lkmc.monkeyspaw.core.domain.`import`

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.PortableYaml
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptDocument
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.format.YamlNode
import ch.lkmc.monkeyspaw.core.domain.format.YamlTag
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.rules.TemporaryFolder

class ImportMapperTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun markdownCopiesBytesCommentsAndExistingIdentityWithoutWriting() {
        val sources = listOf("é\r\n\t{{name}}\n\n",
            "---\r\n# keep\r\ncustom: {a: [1, true]}\r\n---\r\n  {{name}}\r\n",
            "---\nid: 01k6z4v9kqwzx7mpq4t8znb2pd # keep spelling\nfields: {unused: {type: text}}\n---\n{{unknown helper}}")
        for (source in sources) {
            val mapped = map(source, "Example.md")
            assertUtf8(source, mapped.document.source)
            assertTrue(mapped.report.mappings.isEmpty())
            assertTrue(mapped.report.dropped.isEmpty())
            if (!source.contains("id:")) {
                assertNull(mapped.document.frontMatter.id)
            } else {
                assertEquals("01K6Z4V9KQWZX7MPQ4T8ZNB2PD", mapped.document.frontMatter.id?.rawValue)
            }
        }
        val warnings = map(sources.last(), "Example.md").report.warnings
        assertEquals(listOf(ImportWarning.Validation(PromptIssueCode.INVALID_PLACEHOLDER),
            ImportWarning.Validation(PromptIssueCode.UNUSED_FIELD)), warnings)
    }

    @Test fun bomAndHeaderlessForeignSourcesRetainLiteralBytes() {
        for (filename in filenames) {
            for (body in listOf("body {{name}}\r\n", "---\nmodel: literal\n---\nbody\n", "\uFEFFbody\n")) {
                val source = "\uFEFF$body"
                val mapped = map(source, filename)
                assertUtf8(source, mapped.document.source)
                assertUtf8(source, mapped.document.body)
                assertNull(mapped.document.preservedHeader)
                assertNull(mapped.document.frontMatter.id)
                assertTrue(mapped.report.dropped.isEmpty())
                assertTrue(mapped.report.preservedKeys.isEmpty())
            }
        }
        for (filename in listOf("Example.prompt", "Example.prompty")) {
            val result = map("é {{x.y}}", filename)
            assertEquals(listOf(ImportWarning.UnsupportedTemplate(ImportFormat.filename(filename)!!, 3)), result.report.warnings)
            assertUtf8("é {{x.y}}", result.document.source)
        }
    }

    @Test fun byteLimitAndStrictDecodingPrecedeExtensionAndParsing() {
        assertEquals(ImportSkipReason.FileTooLarge, assertFailsWith<ImportSkipReason> {
            ImportMapper.map(ByteArray(Limits.importFileCapBytes + 1) { 0xff.toByte() }, "x.MD")
        })
        for (bytes in listOf(byteArrayOf(0xff.toByte()), byteArrayOf(0xef.toByte(), 0xbb.toByte()),
            byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte(), 0xff.toByte()),
            byteArrayOf(0xc0.toByte(), 0xaf.toByte()), byteArrayOf(0xed.toByte(), 0xa0.toByte(), 0x80.toByte()))) {
            assertEquals(ImportSkipReason.InvalidUTF8, assertFailsWith<ImportSkipReason> { ImportMapper.map(bytes, "x.MD") })
        }
        for (filename in listOf("x.MD", "x.PROMPT", "x.PROMPTY", "x.txt", "x.prompt.bak")) {
            assertEquals(ImportSkipReason.UnsupportedExtension, assertFailsWith<ImportSkipReason> { map("{{unclosed", filename) })
        }
        assertEquals(Limits.importFileCapBytes, map("a".repeat(Limits.importFileCapBytes), "x.md").document.source.length)
    }

    @Test fun importExtensionsUseSwiftCaseSensitiveSuffixes() {
        for ((filename, format) in listOf("NOTES.md" to ImportFormat.MARKDOWN,
            "FLOW.prompt" to ImportFormat.DOTPROMPT, "Resume.prompty" to ImportFormat.PROMPTY)) {
            assertEquals(format, ImportFormat.filename(filename))
            assertUtf8("body", map("body", filename).document.source)
        }
        for (filename in listOf("Notes.MD", "Notes.Md", "Notes.mD", "FLOW.PROMPT", "Flow.Prompt",
            "Flow.pRoMpT", "Resume.PROMPTY", "Resume.Prompty", "Resume.pRoMpTy", "Notes", "Notes.prompt.bak")) {
            assertNull(ImportFormat.filename(filename))
            assertEquals(ImportSkipReason.UnsupportedExtension, assertFailsWith<ImportSkipReason> { map("body", filename) })
        }
    }

    @Test fun multibyteNativeSourcesAreBoundedByUtf8Bytes() {
        for (unit in listOf("é", "🦊")) {
            val source = unit.repeat(Limits.importFileCapBytes / unit.toByteArray(Charsets.UTF_8).size)
            val mapped = map(source, "Example.md")
            assertEquals(Limits.importFileCapBytes, mapped.document.source.toByteArray(Charsets.UTF_8).size)
            assertUtf8(source, mapped.document.source)
            assertEquals(ImportSkipReason.FileTooLarge, assertFailsWith<ImportSkipReason> { map(source + "a", "Example.md") })
        }
    }

    @Test fun nativeErrorsAreOrderedAndFutureFormatTakesPrecedence() {
        for (filename in filenames) {
            val error = assertFailsWith<ImportSkipReason.InvalidPrompt> {
                map("---\ntitle: 7\nfields: {date: {type: text}}\n---\n{{unclosed", filename)
            }
            assertEquals(listOf(PromptIssueCode.INVALID_METADATA_TYPE, PromptIssueCode.RESERVED_FIELD_NAME,
                PromptIssueCode.UNBALANCED_OPENER), error.issues)
            val future = "99999999999999999999999999999999999999"
            assertEquals(future, assertFailsWith<ImportSkipReason.UnsupportedFormat> {
                map("---\nformat: $future\ntitle: 7\n---\n{{unclosed", filename)
            }.version.decimalValue)
            assertEquals("This prompt format cannot be imported.", assertFailsWith<ImportSkipReason> {
                map("---\nformat: 2\n---\nsecret", filename)
            }.toString())
        }
    }

    @Test fun portableYamlIsValidatedBeforeMappingForeignDeclarations() {
        val headers = listOf("input: &a {schema: {name: string}}\ncopy: *a",
            "input: {schema: {name: string}}\nmodel: {nested: yes}", "input: {schema: {name: string, name: string}}",
            "!!seq [a, b]", "input: {schema: {name: string}}\nmodel: !execute /tmp/not-a-command")
        for (header in headers) {
            assertFailsWith<ImportSkipReason.InvalidPrompt> { map("---\n$header\n---\n{{name}}") }
        }
    }

    @Test fun dotpromptMissingUnsupportedSchemasAndAbsentInputFollowSwiftDispatch() {
        for (input in listOf("{type: object}", "string", "null", "{schema: string}",
            "{schema: {type: string}}", "{schema: {type: array, properties: {name: {type: string}}}}")) {
            val mapped = map("---\ninput: $input\n---\nbody")
            assertTrue(mapped.report.mappings.isEmpty())
            assertEquals(listOf(ImportWarning.UnsupportedInput("input.schema")), mapped.report.warnings)
        }
        assertTrue(map("---\nmodel: example\n---\nbody").report.warnings.isEmpty())
        val empty = map("---\n# discarded\n---\nbody")
        assertEquals("---\n{}\n---\nbody", empty.document.source)
        assertEquals(listOf(ImportLoss.FRONT_MATTER_PRESENTATION), empty.report.dropped)
    }

    @Test fun picoschemaMapsStringsEnumsOptionalAndDescriptionsWithFirstCommaOnly() {
        val body = "é\r\n{{name}} / {{tone}} / {{hint}}\r\n\n"
        val source = """
            ---
            input:
              schema:
                name: string, Your name, including initials
                tone(enum, Voice): [formal, casual]
                hint?: string
              default: {name: Ada, tone: casual}
            model: googleai/example
            output: {format: json}
            config: {temperature: 0.5}
            tools: [lookup]
            vendor: {nested: [true, 7, null]}
            ---

        """.trimIndent() + body
        val mapped = map(source)
        val fields = mapped.document.frontMatter.fields
        assertEquals(listOf("name", "tone", "hint"), fields.map { it.name })
        assertEquals(listOf(FieldKind.TEXT, FieldKind.CHOICE, FieldKind.TEXT), fields.map { it.kind })
        assertEquals(listOf("Ada", "casual", ""), fields.map { it.defaultValue })
        assertEquals("Your name, including initials", fields[0].description)
        assertEquals("Voice", fields[1].description)
        assertEquals(listOf("formal", "casual"), fields[1].options.map { it.value })
        assertTrue(fields[2].optional)
        assertUtf8(body, mapped.document.body)
        assertEquals(listOf("input", "model", "output", "config", "tools", "vendor"), mapped.report.preservedKeys)
        assertEquals(listOf("input.default.name", "input.default.tone", null), mapped.report.mappings.map { it.defaultSource })
        assertPreserved(source, mapped.document)
        assertEquals(listOf(ImportLoss.FRONT_MATTER_PRESENTATION), mapped.report.dropped)
    }

    @Test fun picoWhitespaceTrimsSpacesAndTabsWithoutAcceptingNewlines() {
        val source = "---\ninput:\n  schema:\n    name: \"\\t\\u00A0string\\u2003,\\u3000Description\\t\"\n" +
            "    bad: \"string\\n\"\n---\n{{name}}"
        val mapped = map(source)
        assertEquals("Description", mapped.document.frontMatter.fields.single().description)
        assertEquals(listOf(ImportWarning.UnsupportedInput("input.schema.bad")), mapped.report.warnings)
        assertPreserved(source, mapped.document)
    }

    @Test fun jsonSchemaPropertiesAndDeclarationFormsPreserveOptionalSemantics() {
        for ((schema, optional) in listOf(
            "type: object\nrequired: [name]\nproperties:\n  name: {type: string, default: Ada, description: Person}\n  tone: {type: string, enum: [formal, casual]}" to true,
            "required: [name]\nproperties:\n  name: {type: string, default: Ada, description: Person}\n  tone: {type: string, enum: [formal, casual]}" to true,
            "name: {type: string, default: Ada, description: Person}\ntone: {type: string, enum: [formal, casual]}" to false)) {
            val source = "---\ninput:\n  schema:\n" + schema.lines().joinToString("\n") { "    $it" } +
                "\n  default: {name: Other, tone: formal}\n---\n{{name}} {{tone}}"
            val mapped = map(source)
            assertEquals(listOf("name", "tone"), mapped.document.frontMatter.fields.map { it.name })
            assertEquals(listOf("Ada", "formal"), mapped.document.frontMatter.fields.map { it.defaultValue })
            assertFalse(mapped.document.frontMatter.fields[0].optional)
            assertEquals(optional, mapped.document.frontMatter.fields[1].optional)
            assertPreserved(source, mapped.document)
        }
    }

    @Test fun promptyKeyedAndListInputsRespectExplicitDefaultsAndLocalSamples() {
        for (inputs in listOf(
            "inputs:\n  name: {type: string, default: Ada, description: Person}\n  tone: {type: string, enum: [formal, casual], required: true}\n  hint: {type: string, sample: local, required: false}",
            "inputs:\n- {name: name, type: string, default: Ada, description: Person}\n- {name: tone, type: string, enum: [formal, casual], required: true}\n- {name: hint, type: string, sample: local, required: false}")) {
            val source = "---\n$inputs\nsample: {name: Other, tone: casual, hint: root}\nauthors: [Author]\nmodel: {api: chat}\n---\nsystem:\r\n{{name}} {{tone}} {{hint}}\n"
            val mapped = map(source, "Example.prompty")
            val fields = mapped.document.frontMatter.fields
            assertEquals(listOf("Ada", "casual", "local"), fields.map { it.defaultValue })
            assertEquals(listOf(false, false, true), fields.map { it.optional })
            assertEquals("Person", fields[0].description)
            assertTrue(mapped.report.mappings[0].defaultSource!!.endsWith(".default"))
            assertEquals("sample.tone", mapped.report.mappings[1].defaultSource)
            assertTrue(mapped.report.mappings[2].defaultSource!!.endsWith(".sample"))
            assertPreserved(source, mapped.document)
        }
    }

    @Test fun invalidExplicitDefaultsUseOnlyValidatedFallbacksAndKeepEmptyDefaults() {
        val declarations = listOf("name: {type: string, default: false}",
            "tone: {type: string, enum: [formal, casual], default: loud}", "blank: {type: string, default: ''}",
            "badFallback: {type: string, enum: [a, b], default: c}", "noFallback: {type: string, default: 7}")
        for (format in listOf(ImportFormat.DOTPROMPT, ImportFormat.PROMPTY)) {
            val dotprompt = format == ImportFormat.DOTPROMPT
            val heading = if (dotprompt) "input:\n  schema:\n" else "inputs:\n"
            val fallback = if (dotprompt) "\n  default:" else "\nsample:"
            val source = "---\n$heading" + declarations.joinToString("\n") { (if (dotprompt) "    " else "  ") + it } +
                "$fallback {name: Ada, tone: casual, blank: other, badFallback: c}\n---\n{{name}} {{tone}} {{blank}}"
            val mapped = map(source, if (dotprompt) "Example.prompt" else "Example.prompty")
            val sourcePrefix = if (dotprompt) "input.schema." else "inputs."
            val defaultPrefix = if (dotprompt) "input.default." else "sample."
            assertEquals(listOf("name", "tone", "blank"), mapped.document.frontMatter.fields.map { it.name })
            assertEquals(listOf("Ada", "casual", ""), mapped.document.frontMatter.fields.map { it.defaultValue })
            assertEquals(listOf(defaultPrefix + "name", defaultPrefix + "tone", sourcePrefix + "blank.default"),
                mapped.report.mappings.map { it.defaultSource })
            assertEquals(listOf("name", "tone", "badFallback", "noFallback").map { ImportWarning.InvalidDefault(sourcePrefix + it) },
                mapped.report.warnings)
            assertPreserved(source, mapped.document)
        }
        val local = map("---\ninputs:\n  name: {type: string, default: false, sample: local}\nsample: {name: root}\n---\n{{name}}", "Example.prompty")
        assertEquals("local", local.document.frontMatter.fields.single().defaultValue)
        assertEquals("inputs.name.sample", local.report.mappings.single().defaultSource)
        assertEquals(listOf(ImportWarning.InvalidDefault("inputs.name")), local.report.warnings)
        val invalidLocal = map("---\ninputs: {name: {type: string, sample: 7}}\nsample: {name: root}\n---\n{{name}}", "Example.prompty")
        assertTrue(invalidLocal.report.mappings.isEmpty())
        assertEquals(listOf(ImportWarning.InvalidDefault("inputs.name")), invalidLocal.report.warnings)
    }

    @Test fun unusableDefaultsPreserveDeclarationsWithoutMappingFieldsAsInSwift() {
        for (filename in listOf("Example.prompt", "Example.prompty")) {
            val dotprompt = filename.endsWith(".prompt")
            val heading = if (dotprompt) "input:\n  schema:\n    " else "inputs:\n  "
            val sourceKey = if (dotprompt) "input.schema.name" else "inputs.name"
            for (declaration in listOf("{type: string, enum: [formal, casual], default: loud, description: Voice, required: false}",
                "{type: string, default: 7, description: Person, required: false}")) {
                val source = "---\n${heading}name: $declaration\n---\n{{name}}"
                val mapped = map(source, filename)
                assertTrue(mapped.document.frontMatter.fields.isEmpty())
                assertTrue(mapped.document.effectiveFields.single().isImplicit)
                assertTrue(mapped.report.mappings.isEmpty())
                assertEquals(listOf(ImportWarning.InvalidDefault(sourceKey)), mapped.report.warnings)
                assertPreserved(source, mapped.document)
                assertUtf8("{{name}}", mapped.document.body)
            }
            val withoutDefault = map("---\n${heading}name: {type: string, description: Person, required: false}\n---\n{{name}}", filename)
            assertEquals("name", withoutDefault.document.frontMatter.fields.single().name)
            assertTrue(withoutDefault.document.frontMatter.fields.single().optional)
            assertNull(withoutDefault.report.mappings.single().defaultSource)
            assertTrue(withoutDefault.report.warnings.isEmpty())
        }
    }

    @Test fun unusableLocalPromptySamplesDoNotSelectGlobalSamplesAsInSwift() {
        for (sample in listOf("7", "null", "false", "[local]")) {
            for (global in listOf("", "sample: {name: usable}\n")) {
                val source = "---\ninputs: {name: {type: string, sample: $sample, description: Person}}\n${global}---\n{{name}}"
                val mapped = map(source, "Example.prompty")
                assertTrue(mapped.document.frontMatter.fields.isEmpty())
                assertTrue(mapped.document.effectiveFields.single().isImplicit)
                assertTrue(mapped.report.mappings.isEmpty())
                assertEquals(listOf(ImportWarning.InvalidDefault("inputs.name")), mapped.report.warnings)
                assertPreserved(source, mapped.document)
            }
        }
    }

    @Test fun enumDefaultMembershipUsesSwiftCanonicalEqualityButRetainsBytesAndOrder() {
        val source = "---\ninputs:\n  tone: {type: string, enum: ['é', 'a', 'é'], default: 'e\u0301'}\n" +
            "  blank: {type: string, enum: ['', value], default: ''}\n---\n{{tone}} {{blank}}"
        val mapped = map(source, "Example.prompty")
        assertUtf8("e\u0301", mapped.document.frontMatter.fields[0].defaultValue)
        assertEquals(listOf("é", "a", "é"), mapped.document.frontMatter.fields[0].options.map { it.value })
        assertEquals("", mapped.document.frontMatter.fields[1].defaultValue)
        assertTrue(mapped.report.warnings.isEmpty())
        assertPreserved(source, mapped.document)
    }

    @Test fun unsupportedNamesTypesOptionsAndDescriptionsAreReportedInDeclarationOrder() {
        val declarations = listOf("okay: {type: string}", "count: {type: integer}", "list: {type: array}",
            "object: {type: object}", "date: {type: string}", "cursor: {type: string}", "datetime: {type: string}",
            "bad.name: {type: string}", "badEnum: {type: string, enum: [a, 3]}", "emptyEnum: {type: string, enum: []}",
            "badDefault: {type: string, default: false}", "badDescription: {type: string, default: false, sample: value, description: 7}")
        val source = "---\ninputs:\n" + declarations.joinToString("\n") { "  $it" } + "\n---\n{{okay}} {{date}}"
        val mapped = map(source, "Example.prompty")
        assertEquals(listOf("okay"), mapped.document.frontMatter.fields.map { it.name })
        assertEquals(listOf(ImportWarning.UnsupportedInput("inputs.count"), ImportWarning.UnsupportedInput("inputs.list"),
            ImportWarning.UnsupportedInput("inputs.object"), ImportWarning.ReservedName("date"), ImportWarning.ReservedName("cursor"),
            ImportWarning.ReservedName("datetime"), ImportWarning.InvalidName("inputs.bad.name"), ImportWarning.InvalidOptions("inputs.badEnum"),
            ImportWarning.InvalidOptions("inputs.emptyEnum"), ImportWarning.InvalidDefault("inputs.badDefault"),
            ImportWarning.InvalidDefault("inputs.badDescription"), ImportWarning.InvalidDescription("inputs.badDescription")), mapped.report.warnings)
        assertPreserved(source, mapped.document)
    }

    @Test fun normalizedPicoNamesAndExistingNativeFieldsCannotBeOverwritten() {
        val source = "---\nfields:\n  name: {type: multiline, default: Original, custom: retained}\ninput:\n  schema:\n" +
            "    tags(array): string\n    name: string\n    extra: string\n    extra?: string\n    date?: string\n---\n{{name}} {{extra}}"
        val mapped = map(source)
        assertEquals(listOf(FieldKind.MULTILINE, FieldKind.TEXT), mapped.document.frontMatter.fields.map { it.kind })
        assertEquals("Original", mapped.document.frontMatter.fields[0].defaultValue)
        assertEquals(listOf(ImportWarning.UnsupportedInput("input.schema.tags(array)"), ImportWarning.FieldCollision("name"),
            ImportWarning.FieldCollision("extra"), ImportWarning.ReservedName("date")), mapped.report.warnings)
        assertTrue(mapped.document.source.contains("custom: retained"))
        assertPreserved(source, mapped.document)
    }

    @Test fun mappingValuedPicoKeysRemainLiteralAsInSwift() {
        val source = "---\ninput:\n  schema:\n    tone?(enum): [formal, casual]\n" +
            "    color?(enum): {type: string, enum: [red, blue]}\n---\n{{tone}} {{color}}"
        val mapped = map(source)
        assertEquals(listOf("tone"), mapped.report.mappings.map { it.fieldName })
        assertTrue(mapped.document.frontMatter.fields.single().optional)
        assertEquals(listOf(ImportWarning.InvalidName("input.schema.color?(enum)")), mapped.report.warnings)
        assertPreserved(source, mapped.document)
    }

    @Test fun promptySamplesRefineUsedImplicitFieldsWithoutOverridingExplicitInputs() {
        val source = "---\ninputs:\n  count: {type: integer}\nsample: {name: Ada, count: '3', clipboard: value, unused: retained}\n---\n{{name}} {{count}} {{clipboard}}"
        val mapped = map(source, "Example.prompty")
        assertEquals(listOf("name"), mapped.document.frontMatter.fields.map { it.name })
        assertEquals("Ada", mapped.document.frontMatter.fields.single().defaultValue)
        assertEquals(listOf("sample.name"), mapped.report.mappings.map { it.sourceKey })
        assertEquals(listOf("sample.name"), mapped.report.mappings.map { it.defaultSource })
        assertEquals(listOf(ImportWarning.UnsupportedInput("inputs.count"), ImportWarning.ReservedName("clipboard")), mapped.report.warnings)
        assertPreserved(source, mapped.document)
        val scalarInputs = map("---\ninputs: invalid\nsample: {name: Ada}\n---\n{{name}}", "Example.prompty")
        assertTrue(scalarInputs.report.mappings.isEmpty())
        assertEquals(listOf(ImportWarning.UnsupportedInput("inputs")), scalarInputs.report.warnings)
    }

    @Test fun promptyMalformedListEntriesAndDuplicatesRetainTypedWarningOrder() {
        val source = "---\ninputs:\n- scalar\n- {name: 7, type: string}\n- {name: name, type: string}\n" +
            "- {name: name, type: string}\n- {name: count, kind: string}\nsample: {count: retained}\n---\n{{name}} {{count}}"
        val mapped = map(source, "Example.prompty")
        assertEquals(listOf("name"), mapped.report.mappings.map { it.fieldName })
        assertEquals(listOf(ImportWarning.UnsupportedInput("inputs[0]"), ImportWarning.UnsupportedInput("inputs[1]"),
            ImportWarning.FieldCollision("name"), ImportWarning.UnsupportedInput("inputs[4]")), mapped.report.warnings)
        assertPreserved(source, mapped.document)
    }

    @Test fun nonStringKeysRemainMetadataWithFormatSpecificSchemaWarnings() {
        for ((schema, warnings) in listOf("7: string\nname: string" to listOf(ImportWarning.UnsupportedInput("input.schema")),
            "type: object\nproperties: {7: {type: string}, name: {type: string}}" to emptyList())) {
            val source = "---\ninput:\n  schema:\n" + schema.lines().joinToString("\n") { "    $it" } +
                "\n? [a, b]\n: {nested: [true, 7, null]}\n---\n{{name}}"
            val mapped = map(source)
            assertEquals(listOf("name"), mapped.report.mappings.map { it.fieldName })
            assertEquals(listOf("input"), mapped.report.preservedKeys)
            assertEquals(warnings, mapped.report.warnings)
            assertPreserved(source, mapped.document)
        }
    }

    @Test fun supportedPlaceholdersStillCountAsUsedBesideLiteralForeignConstructs() {
        for ((filename, body) in listOf("Example.prompt" to "{{name}} {{#if name}}x{{/if}}",
            "Example.prompty" to "{% if name %}{{name}}{% endif %}")) {
            val header = if (filename.endsWith(".prompt")) "input:\n  schema:\n    name: string" else "inputs:\n  name: {type: string}"
            val mapped = map("---\n$header\n---\n$body", filename)
            assertEquals(listOf("name"), mapped.document.template.names)
            assertFalse(mapped.report.warnings.contains(ImportWarning.Validation(PromptIssueCode.UNUSED_FIELD)))
            assertEquals(2, mapped.report.warnings.filterIsInstance<ImportWarning.UnsupportedTemplate>().size)
            assertUtf8(body, mapped.document.body)
        }
        val unsupported = map("---\ninputs: {name: {type: string}}\n---\né {{name | upper}}", "Example.prompty")
        assertEquals(listOf(ImportWarning.Validation(PromptIssueCode.UNUSED_FIELD),
            ImportWarning.UnsupportedTemplate(ImportFormat.PROMPTY, 3)), unsupported.report.warnings)
    }

    @Test fun foreignTemplateWarningsAreSortedUniqueBodyRelativeUtf8Offsets() {
        val body = "é {% if x %}{{x | upper}}{# comment #}{% endif %}"
        val mapped = map("---\nmodel: example\n---\n$body", "Example.prompty")
        assertEquals(listOf(3, 13, 26, 39), mapped.report.warnings.map { (it as ImportWarning.UnsupportedTemplate).byteOffset })
        assertUtf8(body, mapped.document.body)
        val repeated = map("---\nmodel: example\n---\n$body {% if x %}", "Example.prompty")
        assertEquals(listOf(3, 13, 26, 39, 51), repeated.report.warnings.map { (it as ImportWarning.UnsupportedTemplate).byteOffset })
        assertUtf8("$body {% if x %}", repeated.document.body)
        val escaped = map("\\{{bad.helper}} {% unclosed {# comment", "Example.prompty")
        assertEquals(listOf(ImportWarning.UnsupportedTemplate(ImportFormat.PROMPTY, 16),
            ImportWarning.UnsupportedTemplate(ImportFormat.PROMPTY, 28)), escaped.report.warnings)
        assertUtf8("\\{{bad.helper}} {% unclosed {# comment", escaped.document.body)
    }

    @Test fun conversionHasAnIndependentByteCapWithExactBoundaryAcceptance() {
        val header = "---\ninput:\n  schema:\n    name: string\n---\n"
        val emptySize = map(header).document.source.toByteArray(Charsets.UTF_8).size
        val body = "a".repeat(Limits.maxPromptBytes - emptySize)
        assertEquals(Limits.maxPromptBytes, map(header + body).document.source.toByteArray(Charsets.UTF_8).size)
        assertEquals(ImportSkipReason.ConvertedTooLarge, assertFailsWith<ImportSkipReason> { map(header + body + "a") })
        assertEquals(ImportSkipReason.ConvertedTooLarge, assertFailsWith<ImportSkipReason> {
            map(header + "a".repeat(Limits.importFileCapBytes - header.toByteArray(Charsets.UTF_8).size))
        })
    }

    @Test fun importNeverExecutesToolsTemplatesEnvironmentOrFileReferencesAndIsDeterministic() {
        val marker = temporary.root.resolve("not-created")
        val fixture = temporary.newFile("reference.txt").also { it.writeText("contents must not be expanded") }
        val body = "{{name}} é {{exec 'touch ${marker.path}'}} {% include '${fixture.path}' %} {# literal #}\r\n" +
            "{{env.API_KEY}} {{uuid()}}"
        val source = "---\nmodel: {configuration: {api_key: '\${env:API_KEY}'}}\n" +
            "input: {schema: {name: string}, default: {name: '\${env:API_KEY}'}}\n" +
            "tools: [{command: 'touch ${marker.path}'}]\nsample: {name: '\${file:${fixture.path}}'}\n" +
            "vendor: {include: '${fixture.path}'}\n---\n$body"
        for (filename in listOf("Example.prompt", "Example.prompty")) {
            val first = map(source, filename)
            val second = map(source, filename)
            assertUtf8(body, first.document.body)
            assertUtf8(first.document.source, second.document.source)
            assertEquals(first.report, second.report)
            assertNull(first.document.frontMatter.id)
            assertPreserved(source, first.document)
            assertFalse(marker.exists())
            assertEquals("contents must not be expanded", fixture.readText())
            assertTrue(first.document.source.contains("\${env:API_KEY}"))
            assertTrue(first.document.source.contains("\${file:${fixture.path}}"))
            assertEquals(if (filename.endsWith(".prompt")) "\${env:API_KEY}" else "\${file:${fixture.path}}",
                first.document.frontMatter.fields.single().defaultValue)
        }
    }

    private fun map(source: String, filename: String = "Example.prompt") =
        ImportMapper.map(source.toByteArray(Charsets.UTF_8), filename)

    private fun assertUtf8(expected: String, actual: String) =
        assertContentEquals(expected.toByteArray(Charsets.UTF_8), actual.toByteArray(Charsets.UTF_8))

    private fun assertPreserved(source: String, imported: PromptDocument) {
        val original = PromptCodec.parse(source, "Example.prompt").preservedHeader!!
        val actual = imported.preservedHeader!!
        for ((key, value) in original.entries.filter { PortableYaml.string(it.key) != "fields" }) {
            val entry = actual.entries.single { semantic(it.key) == semantic(key) }
            assertEquals(semantic(value), semantic(entry.value), "Original metadata value must remain intact")
        }
    }

    private fun semantic(node: YamlNode): Any = when (node) {
        is YamlNode.Scalar -> node.tag to PortableYaml.canonicalScalar(node).value
        is YamlNode.Sequence -> YamlTag.SEQ to node.values.map(::semantic)
        is YamlNode.Mapping -> YamlTag.MAP to node.entries.map { semantic(it.key) to semantic(it.value) }
        is YamlNode.Rejected -> error("Rejected nodes cannot reach the mapper")
    }

    private val filenames = listOf("Example.md", "Example.prompt", "Example.prompty")
}
