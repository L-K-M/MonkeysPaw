package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.ports.StoreError
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import kotlin.test.*

internal class AndroidSeedCatalogTest {
    private val source = File(checkNotNull(System.getProperty("monkeyspaw.seedSources")))
    private val assets = File(checkNotNull(System.getProperty("monkeyspaw.seedAssets")))

    @Test
    fun `all ten source paths and raw bytes match generated assets without documentation`() {
        val expected = listOf("code/explain-an-error.md", "code/review-a-diff.md", "code/write-a-commit-message.md",
            "code/write-tests.md", "draft-a-prompt.md", "writing/critique-a-plan.md", "writing/extract-action-items.md",
            "writing/rewrite-for-tone.md", "writing/summarise.md", "writing/translate.md")
        val sourcePaths = Files.walk(source.toPath()).use { paths ->
            paths.filter { Files.isRegularFile(it, NOFOLLOW_LINKS) }.map { source.toPath().relativize(it).toString() }
                .filter { it.endsWith(".md") && it != "README.md" }.toList().sorted()
        }
        assertEquals(expected, sourcePaths)
        val seeds = AndroidSeedCatalog { assets.resolve(it).readBytes() }.prompts()
        assertEquals(expected, seeds.map { it.relativePath })
        assertEquals((expected + "catalog.json").sorted(), assets.resolve("seeds").walkTopDown()
            .filter { it.isFile }.map { it.relativeTo(assets.resolve("seeds")).invariantSeparatorsPath }.toList().sorted())
        assertFalse(assets.resolve("seeds/README.md").exists())
        for (seed in seeds) {
            assertContentEquals(source.resolve(seed.relativePath).readBytes(), seed.bytes)
            val document = PromptCodec.parseFile(seed.bytes, seed.relativePath.substringAfterLast('/'))
            assertNull(document.frontMatter.id)
            assertTrue(document.issues.isEmpty())
        }
        assertEquals("{\"version\":1,\"paths\":[" + expected.joinToString(",") { "\"$it\"" } + "]}\n",
            assets.resolve("seeds/catalog.json").readText())
    }

    @Test
    fun `dot files nested README and unsigned UTF8 ordered Unicode paths remain eligible`() {
        val paths = listOf(".prompt.md", "notes/README.md", "\ue000.md", "😀.md")
        val catalog = "{\"version\":1,\"paths\":[" + paths.joinToString(",") { "\"$it\"" } + "]}"
        val body = "Body\r\n雪\n".encodeToByteArray()
        val seeds = AndroidSeedCatalog { if (it == "seeds/catalog.json") catalog.encodeToByteArray() else body }.prompts()
        assertEquals(paths, seeds.map { it.relativePath })
        seeds.forEach { assertContentEquals(body, it.bytes) }
    }

    @Test
    fun `catalog refuses invalid paths ordering duplicates versions and unreadable bytes`() {
        for (catalog in listOf("{}", "{\"version\":2,\"paths\":[\"a.md\"]}",
            "{\"version\":1,\"paths\":[]}", "{\"version\":1,\"paths\":[\"../a.md\"]}",
            "{\"version\":1,\"paths\":[\"README.md\"]}", "{\"version\":1,\"paths\":[\"_a.md\"]}",
            "{\"version\":1,\"paths\":[\".git/a.md\"]}", "{\"version\":1,\"paths\":[\"a.MD\"]}",
            "{\"version\":1,\"paths\":[\"b.md\",\"a.md\"]}", "{\"version\":1,\"paths\":[\"a.md\",\"a.md\"]}")) {
            assertFailsWith<StoreError.IOFailure> { AndroidSeedCatalog { catalog.encodeToByteArray() }.prompts() }
        }
        assertFailsWith<StoreError.IOFailure> { AndroidSeedCatalog { byteArrayOf(-1) }.prompts() }
        val error = assertFailsWith<StoreError.IOFailure> { AndroidSeedCatalog { error("SECRET asset body") }.prompts() }
        assertNull(error.cause)
        assertFalse(error.toString().contains("SECRET"))
    }
}
