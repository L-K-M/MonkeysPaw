package ch.lkmc.monkeyspaw.core.conformance

import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.security.MessageDigest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Rule
import org.junit.rules.TemporaryFolder

class CorpusInventoryTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun `inventory accounts for every visible fixture exactly once`() {
        val corpus = Corpus.load()
        assertEquals(Category.entries.toSet(), corpus.cases.map { it.category }.toSet())
        Category.entries.forEach { assertTrue(corpus.cases(it).isNotEmpty(), it.directory) }
        val files = corpus.cases.flatMap { it.files }.map { it.relativePath }
        assertEquals(files.size, files.toSet().size)
        val visible = visibleFiles(corpus.fixtureRoot)
        assertEquals(visible, corpus.enumeratedFiles)
        assertEquals(visible, corpus.accountedFiles)

        val digest = MessageDigest.getInstance("SHA-256")
        for (path in visible.sorted()) {
            digest.update(path.toByteArray(Charsets.UTF_8))
            digest.update(0.toByte())
            digest.update(Files.readAllBytes(corpus.fixtureRoot.resolve(path)))
        }
        val hash = digest.digest().joinToString("") { "%02x".format(it) }
        println("Structural inventory: ${corpus.cases.size} cases, ${visible.size} files; SHA-256=$hash")
        println("Fixtures: ${corpus.fixtureRoot}; schemas: ${corpus.schemaRoot} (${corpus.schemas.size})")
    }

    @Test
    fun `hidden metadata is ignored before checking file types at every level`() = withSynthetic { root, schema ->
        val baseline = Corpus.load(root, schema)
        val directories = Files.walk(root).use { paths -> paths.filter { Files.isDirectory(it) }.toList() }
        for (directory in directories) {
            Files.write(directory.resolve(".DS_Store"), byteArrayOf(0xff.toByte()))
            Files.writeString(directory.resolve(".gitattributes"), "metadata")
            Files.createDirectory(directory.resolve("._metadata"))
            Files.writeString(directory.resolve("._metadata/visible-junk"), "ignored")
            Files.createSymbolicLink(directory.resolve(".hidden-link"), Path.of("missing-target"))
        }
        val actual = Corpus.load(root, schema)
        assertEquals(baseline.enumeratedFiles, actual.enumeratedFiles)
        assertEquals(baseline.accountedFiles, actual.accountedFiles)
        assertEquals(baseline.cases.size, actual.cases.size)
    }

    @Test
    fun `unknown and missing categories cannot pass`() {
        rejects("unknown category") { root -> Files.createDirectory(root.resolve("future")) }
        Category.entries.forEach { category ->
            rejects("missing ${category.directory}") { root -> deleteTree(root.resolve(category.directory)) }
        }
        rejects("visible file at root") { root -> Files.writeString(root.resolve("README.md"), "orphan") }
    }

    @Test
    fun `empty categories and cases cannot pass`() {
        Category.entries.forEach { category ->
            rejects("empty ${category.directory}") { root ->
                visibleChildren(root.resolve(category.directory)).forEach(::deleteTree)
            }
        }
        directoryCategories.forEach { category ->
            rejects("empty case ${category.directory}") { root ->
                visibleChildren(root.resolve("${category.directory}/tiny")).forEach(::deleteTree)
            }
            rejects("missing case.json ${category.directory}") { root ->
                Files.delete(root.resolve("${category.directory}/tiny/case.json"))
            }
        }
        rejects("flat category without an expectation") { root -> Files.delete(root.resolve("format/tiny.json")) }
    }

    @Test
    fun `unknown files orphans and missing sources cannot pass`() {
        Category.entries.forEach { category ->
            val parent = envelopePath(category).substringBeforeLast('/')
            rejects("unknown ${category.directory} file") { root -> Files.writeString(root.resolve("$parent/extra.txt"), "") }
            rejects("orphan ${category.directory} source") { root ->
                val orphan = if (category == Category.DTO) "orphan.json" else "orphan.md"
                Files.writeString(root.resolve("$parent/$orphan"), "")
            }
            rejects("missing ${category.directory} source") { root ->
                val fixture = Corpus.load(root, root.parent.resolve("schema")).cases(category).single()
                Files.delete(fixture.sources.values.first().path)
            }
        }
        rejects("extra ranking JSON") { root -> Files.writeString(root.resolve("ranking/tiny/extra.json"), "{}") }
        mutateRejects(Category.RANKING, "duplicate ranking source") {
            val prompts = this["prompts"].arrayValue().toMutableList()
            prompts[1] = changed(prompts[1]) { this["source"] = JsonPrimitive("one.md") }
            this["prompts"] = JsonArray(prompts)
        }
        mutateRejects(Category.CANONICAL, "duplicate canonical source") {
            this["comparison"] = changed(this["comparison"]) { this["source"] = JsonPrimitive("source.md") }
        }
        for (category in directoryCategories - Category.RANKING) {
            listOf("../outside.md", ".hidden.md", "wrong.extension").forEach { name ->
                mutateRejects(category, "invalid source $name") { this["source"] = JsonPrimitive(name) }
            }
        }
        mutateRejects(Category.DTO, "DTO envelope as source") { this["source"] = JsonPrimitive("case.json") }
    }

    @Test
    fun `visible symlinks and nesting are rejected at every corpus level`() {
        val paths = Category.entries.map { it.directory } + directoryCategories.map { "${it.directory}/tiny" } +
            syntheticFiles.keys
        for (path in paths) {
            rejects("visible symlink $path") { root ->
                val target = root.resolve(path)
                val saved = target.resolveSibling(".saved-${target.fileName}")
                Files.move(target, saved)
                Files.createSymbolicLink(target, saved.fileName)
            }
        }
        withSynthetic { root, schema ->
            val link = root.resolveSibling("fixture-link")
            Files.createSymbolicLink(link, root.fileName)
            assertFailsWith<CorpusException> { Corpus.load(link, schema) }
        }
        Category.entries.forEach { category ->
            val parent = envelopePath(category).substringBeforeLast('/')
            rejects("nested ${category.directory} directory") { root -> Files.createDirectory(root.resolve("$parent/nested.md")) }
        }
    }

    @Test
    fun `strict envelopes reject wrong schemas discriminators and member sets`() {
        Category.entries.forEach { category ->
            listOf(JsonPrimitive(true), JsonPrimitive(2), JsonPrimitive("1"), JsonNull).forEach { schema ->
                mutateRejects(category, "schema $schema") { this["schema"] = schema }
            }
            mutateRejects(category, "wrong category") { this["category"] = JsonPrimitive("unknown") }
            mutateRejects(category, "extra envelope member") { this["extra"] = JsonPrimitive(1) }
            val envelope = parseFixtureJson(syntheticFiles.getValue(envelopePath(category)).toByteArray()).objectValue()
            envelope.keys.forEach { key -> mutateRejects(category, "missing $key") { remove(key) } }
            mutateRejects(category, "extra expectation member") {
                this["expected"] = changed(this["expected"]) { this["extra"] = JsonPrimitive(1) }
            }
            envelope["expected"].objectValue().keys.forEach { key ->
                mutateRejects(category, "missing expectation $key") {
                    this["expected"] = changed(this["expected"]) { remove(key) }
                }
            }
        }
        mutateRejects(Category.DTO, "unknown DTO") { this["dto"] = JsonPrimitive("UnknownDTO") }
    }

    @Test
    fun `nested contracts reject extra members`() {
        val paths = mapOf(
            Category.FORMAT to listOf(listOf("expected", "metadata")),
            Category.GRAMMAR to listOf(listOf("expected", "tokens", "0"), listOf("expected", "fields", "0"),
                listOf("expected", "fields", "0", "options", "0"), listOf("expected", "issues", "0")),
            Category.RENDER to listOf(listOf("expected", "result")),
            Category.RANKING to listOf(listOf("prompts", "0"), listOf("expected", "results", "0")),
            Category.IMPORT to listOf(listOf("expected", "mappings", "0"), listOf("expected", "warnings", "0")),
            Category.CANONICAL to listOf(listOf("comparison")),
        )
        paths.forEach { (category, members) -> members.forEach { path ->
            mutateRejects(category, "extra nested member $path") {
                val altered = addExtra(JsonObject(this), path).objectValue()
                clear()
                putAll(altered)
            }
        } }
    }

    @Test
    fun `ranking types times and references stay strict`() {
        mutateRejects(Category.RANKING, "empty prompts") { this["prompts"] = JsonArray(emptyList()) }
        listOf("2026-10-11T12:00:00+00:00", "2026-02-30T12:00:00Z", "2026-10-11T12:00:00.000Z").forEach { time ->
            mutateRejects(Category.RANKING, "invalid now") { this["now"] = JsonPrimitive(time) }
        }
        mutateRejects(Category.RANKING, "duplicate prompt path") {
            val prompts = this["prompts"].arrayValue().toMutableList()
            prompts[1] = changed(prompts[1]) { this["path"] = JsonPrimitive("One.md") }
            this["prompts"] = JsonArray(prompts)
        }
        for (score in listOf(JsonPrimitive(true), JsonPrimitive("4"))) {
            mutateRejects(Category.RANKING, "invalid score") {
                this["expected"] = changed(this["expected"]) {
                    this["results"] = JsonArray(listOf(changed(this["results"].arrayValue()[0]) { this["score"] = score }))
                }
            }
        }
    }

    @Test
    fun `category unions and scalar types are checked without semantic execution`() {
        mutateRejects(Category.RENDER, "unknown builtin") { this["builtins"] = JsonObject(mapOf("random" to JsonPrimitive("x"))) }
        mutateRejects(Category.IMPORT, "zero repeat") { this["repeat"] = JsonPrimitive(0) }
        mutateRejects(Category.IMPORT, "import expansion over cap") { this["repeat"] = JsonPrimitive(262_146) }
        mutateRejects(Category.CANONICAL, "numeric favorite") {
            this["expected"] = changed(this["expected"]) { this["favorite"] = JsonPrimitive(1) }
        }
        mutateRejects(Category.DTO, "numeric validity") {
            this["expected"] = changed(this["expected"]) { this["valid"] = JsonPrimitive(1) }
        }
        mutateRejects(Category.PATHS, "unknown scope") { this["scope"] = JsonPrimitive("private") }
        withSynthetic { root, schema ->
            replaceExpected(root, Category.PATHS, """{"issue":{"code":"path.segment_dot","segment":0}}""")
            Corpus.load(root, schema)
            editEnvelope(root, Category.PATHS) { this["expected"] = changed(this["expected"]) {
                this["issue"] = changed(this["issue"]) { this["extra"] = JsonPrimitive(1) }
            } }
            assertFailsWith<CorpusException> { Corpus.load(root, schema) }
        }
        withSynthetic { root, schema ->
            replaceExpected(root, Category.CANONICAL, """{"error":{"code":"unsupported_format","version":"2"}}""")
            editEnvelope(root, Category.CANONICAL) { remove("comparison") }
            Files.delete(root.resolve("canonical/tiny/candidate.md"))
            Corpus.load(root, schema)
            editEnvelope(root, Category.CANONICAL) { this["expected"] = changed(this["expected"]) {
                this["error"] = changed(this["error"]) { this["extra"] = JsonPrimitive(1) }
            } }
            assertFailsWith<CorpusException> { Corpus.load(root, schema) }
        }
        withSynthetic { root, schema ->
            replaceExpected(root, Category.IMPORT, """{"refusal":{"code":"fileTooLarge","issues":[]}}""")
            Corpus.load(root, schema)
            editEnvelope(root, Category.IMPORT) { this["expected"] = changed(this["expected"]) {
                this["refusal"] = changed(this["refusal"]) { this["extra"] = JsonPrimitive(1) }
            } }
            assertFailsWith<CorpusException> { Corpus.load(root, schema) }
        }
        // A false DTO expectation does not ask the structural reader to decode its body.
        withSynthetic { root, schema ->
            replaceExpected(root, Category.DTO, """{"valid":false}""")
            Files.write(root.resolve("dto/tiny/body.json"), byteArrayOf(0xff.toByte()))
            assertBytesEqual(byteArrayOf(0xff.toByte()), Corpus.load(root, schema).cases(Category.DTO).single().source().bytes())
        }
    }

    @Test
    fun `numeric schema parity follows the Swift category readers`() {
        for (category in Category.entries - Category.PATHS) {
            for (token in listOf("1.0", "1e0")) withSynthetic { root, schema ->
                editEnvelope(root, category) { this["schema"] = parseFixtureJson(token.toByteArray()) }
                Corpus.load(root, schema)
            }
        }
        listOf("1.0", "1e0").forEach { token ->
            mutateRejects(Category.PATHS, "float schema") { this["schema"] = parseFixtureJson(token.toByteArray()) }
        }
    }

    private fun rejects(label: String, mutation: (Path) -> Unit) = withSynthetic { root, schema ->
        mutation(root)
        assertFailsWith<CorpusException>(label) { Corpus.load(root, schema) }
    }

    private fun mutateRejects(category: Category, label: String, mutation: MutableMap<String, JsonElement>.() -> Unit) =
        rejects("${category.directory}: $label") { root -> editEnvelope(root, category, mutation) }

    private fun editEnvelope(root: Path, category: Category, mutation: MutableMap<String, JsonElement>.() -> Unit) {
        val path = root.resolve(envelopePath(category))
        Files.writeString(path, changed(parseFixtureJson(Files.readAllBytes(path)), mutation).toString())
    }

    private fun replaceExpected(root: Path, category: Category, json: String) = editEnvelope(root, category) {
        this["expected"] = parseFixtureJson(json.toByteArray())
    }

    private fun changed(value: JsonElement?, mutation: MutableMap<String, JsonElement>.() -> Unit): JsonObject =
        JsonObject(value.objectValue().toMutableMap().apply(mutation))

    private fun addExtra(value: JsonElement, path: List<String>): JsonElement {
        if (path.isEmpty()) return changed(value) { this["extra"] = JsonPrimitive(1) }
        return when (value) {
            is JsonObject -> changed(value) { this[path.first()] = addExtra(getValue(path.first()), path.drop(1)) }
            is JsonArray -> JsonArray(value.toMutableList().apply {
                val index = path.first().toInt()
                this[index] = addExtra(this[index], path.drop(1))
            })
            else -> error("Synthetic mutation path does not select an object")
        }
    }

    private fun withSynthetic(work: (Path, Path) -> Unit) {
        val directory = temporary.newFolder().toPath()
        val root = Files.createDirectory(directory.resolve("fixtures"))
        val schema = Files.createDirectory(directory.resolve("schema"))
        Files.writeString(schema.resolve("HealthResponse.json"), "{}")
        syntheticFiles.forEach { (relative, text) ->
            val path = root.resolve(relative)
            Files.createDirectories(path.parent)
            Files.writeString(path, text)
        }
        Corpus.load(root, schema) // Every mutation starts from a proved valid tiny corpus.
        work(root, schema)
    }

    private fun visibleFiles(root: Path): Set<String> = Files.walk(root).use { paths ->
        paths.filter { Files.isRegularFile(it, NOFOLLOW_LINKS) &&
            root.relativize(it).none { segment -> segment.toString().startsWith(".") }
        }.map { root.relativize(it).toString() }.toList().toSet()
    }

    private fun deleteTree(path: Path) = Files.walk(path).use { paths ->
        paths.sorted(Comparator.reverseOrder()).forEach { Files.delete(it) }
    }

    private val directoryCategories = setOf(Category.RANKING, Category.IMPORT, Category.PATHS, Category.CANONICAL, Category.DTO)

    private fun envelopePath(category: Category): String = category.directory +
        if (category in directoryCategories) "/tiny/case.json" else "/tiny.json"

    private val fixtureField = """{"name":"x","type":"choice","label":"X","description":null,"default":"a","options":[{"label":"A","value":"a"}],"optional":false,"remember":true,"implicit":false}"""
    private val issue = """{"code":"field.unused","severity":"warning"}"""
    private val syntheticFiles: Map<String, String> = mapOf(
        "format/tiny.json" to """{"schema":1,"category":"format","filename":"Tiny.md","expected":{"metadata":{"id":null,"title":"Tiny","description":null,"tags":[],"favorite":false,"private":false,"format":"1","declarations":[]},"body":"x","issues":[],"canonical":"x"}}""",
        "grammar/tiny.json" to """{"schema":1,"category":"grammar","filename":"Tiny.md","expected":{"tokens":[{"kind":"literal","text":"x"}],"names":[],"fields":[$fixtureField],"issues":[$issue]}}""",
        "render/tiny.json" to """{"schema":1,"category":"render","filename":"Tiny.md","expected":{"fields":[],"builtins":[],"issues":[],"result":{"text":"x"}}}""",
        "validation/tiny.json" to """{"schema":1,"category":"validation","filename":"Tiny.md","expected":{"issues":[],"private":false,"fields":[],"canRender":true,"readOnly":false,"canWrite":true}}""",
        "ranking/tiny/case.json" to """{"schema":1,"category":"ranking","query":"x","now":"2026-10-11T12:00:00Z","prompts":[{"source":"one.md","path":"One.md","uses":[]},{"source":"two.md","path":"Two.md","uses":[]}],"expected":{"results":[{"path":"One.md","score":4,"matchedFields":["title"]}]}}""",
        "import/tiny/case.json" to """{"schema":1,"category":"import","source":"source.prompt","expected":{"source":"x","body":"x","mappings":[{"sourceKey":"input.x","fieldName":"x","kind":"text","defaultSource":null}],"preservedKeys":[],"dropped":["frontMatterPresentation"],"warnings":[{"code":"invalidName","key":"input.x"}]}}""",
        "paths/tiny/case.json" to """{"schema":1,"category":"paths","source":"path.txt","scope":"user","expected":{"path":"Tiny.md","path_key":"tiny.md"}}""",
        "canonical/tiny/case.json" to """{"schema":1,"category":"canonical","scope":"user","source":"source.md","expected":{"bytes":"x","body":"x","canonicalHash":"${"0".repeat(64)}","favorite":null,"warnings":[]},"comparison":{"source":"candidate.md","equivalent":false}}""",
        "dto/tiny/case.json" to """{"schema":1,"category":"dto","dto":"HealthResponse","source":"body.json","expected":{"valid":true}}""",
        "format/tiny.md" to "x", "grammar/tiny.md" to "x", "render/tiny.md" to "x", "validation/tiny.md" to "x",
        "ranking/tiny/one.md" to "x", "ranking/tiny/two.md" to "x", "import/tiny/source.prompt" to "x",
        "paths/tiny/path.txt" to "Tiny.md", "canonical/tiny/source.md" to "x", "canonical/tiny/candidate.md" to "y",
        "dto/tiny/body.json" to "{}",
    )
}
