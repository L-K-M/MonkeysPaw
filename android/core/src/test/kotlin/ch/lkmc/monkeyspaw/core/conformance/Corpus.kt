package ch.lkmc.monkeyspaw.core.conformance

import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import kotlinx.serialization.json.JsonObject

internal enum class Category(val directory: String) {
    FORMAT("format"), GRAMMAR("grammar"), RENDER("render"), VALIDATION("validation"),
    RANKING("ranking"), IMPORT("import"), PATHS("paths"), CANONICAL("canonical"), DTO("dto"), LLM("llm");
}

internal class CorpusException(message: String) : IllegalArgumentException(message)

internal fun corpusRequire(condition: Boolean, message: String) {
    if (!condition) throw CorpusException(message)
}

internal data class FixtureFile(val relativePath: String, val path: Path) {
    fun bytes(): ByteArray = Files.readAllBytes(path)
    fun utf8(): String = strictUtf8(bytes())
}

internal data class FixtureCase(
    val category: Category,
    val name: String,
    val envelopeFile: FixtureFile,
    val envelope: JsonObject,
    val sources: Map<String, FixtureFile>,
) {
    val expected: JsonObject get() = envelope["expected"].objectValue()
    val files: List<FixtureFile> get() = listOf(envelopeFile) + sources.values

    fun source(name: String = sources.keys.single()): FixtureFile =
        sources[name] ?: throw CorpusException("Missing source $name in ${envelopeFile.relativePath}")
}

/** Structural accounting only. Category adapters must separately prove semantic consumption. */
internal class Corpus private constructor(
    val fixtureRoot: Path,
    val schemaRoot: Path,
    val schemas: Map<String, Path>,
    val cases: List<FixtureCase>,
    val enumeratedFiles: Set<String>,
    val accountedFiles: Set<String>,
) {
    fun cases(category: Category): List<FixtureCase> = cases.filter { it.category == category }

    companion object {
        fun load(
            fixtureRoot: Path = testDirectory("monkeyspaw.fixtures"),
            schemaRoot: Path = testDirectory("monkeyspaw.schema"),
        ): Corpus {
            val root = fixtureRoot.toAbsolutePath().normalize()
            val schema = schemaRoot.toAbsolutePath().normalize()
            requireDirectory(root)
            requireDirectory(schema)
            val schemas = visibleChildren(schema).filter { it.fileName.toString().endsWith(".json") }
                .associate { file ->
                    requireFile(file)
                    file.fileName.toString().removeSuffix(".json") to file
                }
            corpusRequire(schemas.isNotEmpty(), "Empty schema catalog")

            val directories = visibleChildren(root)
            corpusRequire(directories.map { it.fileName.toString() }.toSet() ==
                Category.entries.map { it.directory }.toSet() + "sync", "Unknown or missing category")
            // E34: sync-engine scenarios execute in the server suite until M10.
            val sync = root.resolve("sync")
            requireDirectory(sync)
            val syncFiles = visibleChildren(sync)
            corpusRequire(syncFiles.isNotEmpty(), "Empty delegated sync corpus")
            syncFiles.forEach { file ->
                requireFile(file)
                corpusRequire(file.fileName.toString().endsWith(".json"), "Unknown delegated sync file")
            }
            val enumerated = linkedSetOf<String>()
            val accounted = linkedSetOf<String>()
            val cases = mutableListOf<FixtureCase>()

            fun file(path: Path): FixtureFile = FixtureFile(root.relativize(path).toString(), path)

            fun addCase(category: Category, name: String, json: Path, files: List<Path>) {
                val envelope = parseFixtureJson(Files.readAllBytes(json)).objectValue()
                val references = FixtureContracts.read(category, envelope, schemas.keys, json.fileName.toString())
                val sources = linkedMapOf<String, FixtureFile>()
                for (source in references) {
                    val path = files.singleOrNull { it.fileName.toString() == source }
                        ?: throw CorpusException("Missing source $source in $json")
                    corpusRequire(sources.put(source, file(path)) == null, "Duplicate source $source in $json")
                }
                val fixture = FixtureCase(category, name, file(json), envelope, sources)
                for (input in fixture.files) {
                    corpusRequire(accounted.add(input.relativePath), "Duplicate accounting of ${input.relativePath}")
                }
                // DTO/canonical refusals and LLM recovery samples may contain malformed bytes.
                if (category !in setOf(Category.DTO, Category.CANONICAL, Category.LLM)) sources.values.forEach { it.utf8() }
                if (category == Category.LLM) sources.values.filter { it.path.toString().endsWith(".txt") ||
                    it.path.toString().endsWith(".md") }.forEach { it.utf8() }
                if (category == Category.IMPORT) {
                    val count = envelope["repeat"]?.integerValue() ?: java.math.BigInteger.ONE
                    val size = java.math.BigInteger.valueOf(fixture.source().bytes().size.toLong()) * count
                    corpusRequire(size <= java.math.BigInteger.valueOf(262_145), "Expanded import source is too large")
                }
                cases.add(fixture)
            }

            for (category in Category.entries) {
                val directory = root.resolve(category.directory)
                requireDirectory(directory)
                val children = visibleChildren(directory)
                corpusRequire(children.isNotEmpty(), "Empty category ${category.directory}")
                val before = cases.size

                when (category) {
                    Category.FORMAT, Category.GRAMMAR, Category.RENDER, Category.VALIDATION -> {
                        for (child in children) {
                            requireFile(child)
                            val name = child.fileName.toString()
                            corpusRequire(name.endsWith(".json") || name.endsWith(".md"), "Unknown file $child")
                            enumerated.add(file(child).relativePath)
                        }
                        for (json in children.filter { it.fileName.toString().endsWith(".json") }) {
                            addCase(category, json.fileName.toString().removeSuffix(".json"), json, children)
                        }
                    }
                    else -> for (caseDirectory in children) {
                        requireDirectory(caseDirectory)
                        val files = visibleChildren(caseDirectory)
                        corpusRequire(files.isNotEmpty(), "Empty case $caseDirectory")
                        for (child in files) {
                            requireFile(child)
                            val name = child.fileName.toString()
                            val allowed = name == "case.json" || when (category) {
                                Category.RANKING, Category.CANONICAL -> name.endsWith(".md")
                                Category.IMPORT -> listOf(".md", ".prompt", ".prompty").any { name.endsWith(it) }
                                Category.PATHS -> name == "path.txt"
                                Category.DTO -> name.endsWith(".json")
                                Category.LLM -> listOf(".txt", ".bin", ".json", ".md").any { name.endsWith(it) }
                            }
                            corpusRequire(allowed, "Unknown file $child")
                            enumerated.add(file(child).relativePath)
                        }
                        val json = files.singleOrNull { it.fileName.toString() == "case.json" }
                            ?: throw CorpusException("Missing case.json in $caseDirectory")
                        addCase(category, caseDirectory.fileName.toString(), json, files)
                    }
                }
                corpusRequire(cases.size > before, "Empty case set in ${category.directory}")
            }
            corpusRequire(accounted == enumerated, "Unaccounted files: ${enumerated - accounted}")
            return Corpus(root, schema, schemas, cases, enumerated, accounted)
        }

        private fun testDirectory(property: String): Path {
            val value = System.getProperty(property)
                ?: throw CorpusException("Missing test system property $property")
            val path = Path.of(value)
            corpusRequire(path.isAbsolute, "Test directory must be absolute: $property")
            return path
        }
    }
}

// Filter metadata before checking its type, so even hidden links/directories are ignored.
internal fun visibleChildren(directory: Path): List<Path> = Files.list(directory).use { entries ->
    entries.filter { !it.fileName.toString().startsWith(".") }.sorted().toList()
}

private fun requireDirectory(path: Path) {
    corpusRequire(Files.isDirectory(path, NOFOLLOW_LINKS), "Expected a directory, without symlinks: $path")
}

private fun requireFile(path: Path) {
    corpusRequire(Files.isRegularFile(path, NOFOLLOW_LINKS), "Expected a regular file, without symlinks: $path")
}
