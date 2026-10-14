package ch.lkmc.monkeyspaw.core.llm

import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AssistantPromptCatalogTest {
    @Test fun catalogMatchesEverySourceIdAndUtf8Byte() {
        val directory = Path.of(requireNotNull(System.getProperty("monkeyspaw.assistantPrompts")))
        val catalog = mapOf("write.md" to AssistantPrompts.write, "review.md" to AssistantPrompts.review,
            "improve.md" to AssistantPrompts.improve)
        val names = Files.list(directory).use { entries -> entries.map { it.fileName.toString() }.toList().toSet() }
        assertEquals(catalog.keys, names)
        for ((name, prompt) in catalog) {
            val path = directory.resolve(name)
            assertTrue(Files.isRegularFile(path, NOFOLLOW_LINKS))
            assertFalse(Files.isSymbolicLink(path))
            assertContentEquals(Files.readAllBytes(path), prompt.toByteArray(Charsets.UTF_8),
                "Run scripts/generate-assistant-prompts.py after changing $name.")
        }
    }
}
