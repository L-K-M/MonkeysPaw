package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.services.*
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.*

internal class AndroidStateIntegrationTest : TemporaryFiles() {
    @Test
    fun `private layout and state survive a new graph without byte changes`() {
        val library = library()
        val created = library.create(document("Hello {{name}}\r\n"), "folder/p.md").entry
        val original = Files.readAllBytes(libraryDir.resolve("folder/p.md"))
        library.values.record(created.identity, mapOf("name" to "", "extra" to "雪\nline"))
        library.index.recordUse(created.identity)
        val saved = library.save(document("Edited body\n"), created.relativePath, created.stamp).entry
        val identity = saved.identity.storageKey
        assertTrue(Files.exists(stateDir.resolve("values.json")))
        assertTrue(Files.exists(stateDir.resolve("usage/$identity")))
        assertTrue(Files.isDirectory(stateDir.resolve("history/$identity")))
        assertFalse(Files.exists(libraryDir.resolve("values.json")))
        val restarted = library()
        assertEquals(created.identity, restarted.load(created.relativePath).identity)
        assertEquals(mapOf("name" to "", "extra" to "雪\nline"), restarted.values.rememberedValues(created.identity))
        assertEquals(library.usage.useEvents(created.identity), restarted.usage.useEvents(created.identity))
        val revisions = restarted.history.revisions(created.identity)
        assertEquals(1, revisions.size)
        assertContentEquals(original, restarted.history.read(revisions.single()))
        val history = restarted.history.read(revisions.single())
        history[0] = 0
        assertContentEquals(original, restarted.history.read(revisions.single()))
    }

    @Test
    fun `invalid bytes stay listed as forensic read only files`() {
        put(libraryDir.resolve("invalid.md"), byteArrayOf(-1, 13, 10))
        val library = library()
        val loaded = library.loadForEditing("invalid.md")
        assertEquals(SourceReadOnlyReason.INVALID_UTF8, loaded.readOnlyReason)
        assertNull(loaded.source)
        assertContentEquals(byteArrayOf(-1, 13, 10), loaded.sourceBytes)
        assertEquals(listOf("invalid.md"), library.index.rebuild().prompts.map { it.entry.relativePath })
    }

    @Test
    fun `a stale save preserves the external replacement without taking history`() {
        put(libraryDir.resolve("p.md"), "original".encodeToByteArray())
        val library = library()
        val loaded = library.loadForEditing("p.md")
        val path = libraryDir.resolve("p.md")
        val modified = Files.getLastModifiedTime(path)
        Files.delete(path)
        put(path, "external".encodeToByteArray())
        Files.setLastModifiedTime(path, modified)
        val result = EditingService(library).save("my draft", "p.md", loaded.entry.stamp)
        assertIs<EditResult.Conflict>(result)
        assertEquals("external", Files.readString(path))
        assertTrue(library.history.revisions(loaded.entry.identity).isEmpty())
    }

    @Test
    fun `failed history flush prevents prompt replacement`() {
        put(libraryDir.resolve("p.md"))
        val state = AndroidStateStore(stateDir.toFile(), object : AtomicPublication() {
            override fun flush(channel: FileChannel) { throw IOException("disk failure") }
        })
        val library = library(state)
        val loaded = library.loadForEditing("p.md")
        val result = EditingService(library).save("new body", "p.md", loaded.entry.stamp)
        assertIs<EditResult.Failed>(result)
        assertEquals("body", Files.readString(libraryDir.resolve("p.md")))
        assertEquals(loaded.entry.stamp, library.load("p.md").stamp)
        assertTrue(library.history.revisions(loaded.entry.identity).isEmpty())
    }

    @Test
    fun `failed values publication keeps prior state readable after restart`() {
        val initial = library()
        val identity = initial.create(document("Body"), "p.md").entry.identity
        initial.values.record(identity, mapOf("name" to "old"))
        val original = Files.readAllBytes(stateDir.resolve("values.json"))
        val state = AndroidStateStore(stateDir.toFile(), object : AtomicPublication() {
            override fun replace(temporary: Path, destination: Path) { throw IOException("disk failure") }
        })
        assertFailsWith<StoreError.IOFailure> { library(state).values.record(identity, mapOf("name" to "new")) }
        assertContentEquals(original, Files.readAllBytes(stateDir.resolve("values.json")))
        assertEquals(mapOf("name" to "old"), library().values.rememberedValues(identity))
        initial.values.record(identity, mapOf("name" to "new"))
        assertEquals(mapOf("name" to "new"), library().values.rememberedValues(identity))
    }

    @Test
    fun `failed prompt replacement reverses real keyed migrations and removes staged history`() {
        put(libraryDir.resolve("p.md"))
        val prompts = AndroidPromptStore(libraryDir.toFile(), object : AtomicPublication() {
            override fun replace(temporary: Path, destination: Path) { throw IOException("publish failed") }
        })
        val library = library(prompts = prompts)
        val local = library.load("p.md").identity
        library.values.record(local, mapOf("name" to "old"))
        library.usage.recordUse(local)
        val state = AndroidStateStore(stateDir.toFile())
        state.create(byteArrayOf(1), "history/${local.storageKey}/_sidecar")
        val before = state.listFiles().associate { it.relativePath to state.read(it.relativePath).toList() }
        val promptBefore = Files.readAllBytes(libraryDir.resolve("p.md"))
        val result = EditingService(library).save("new body", "p.md", library.load("p.md").stamp)
        assertIs<EditResult.Failed>(result)
        val after = state.listFiles().associate { it.relativePath to state.read(it.relativePath).toList() }
        assertEquals(before, after)
        assertContentEquals(promptBefore, Files.readAllBytes(libraryDir.resolve("p.md")))
        assertEquals(local, library().load("p.md").identity)
        assertTrue(library().history.revisions(local).isEmpty())
        assertEquals(mapOf("name" to "old"), library().values.rememberedValues(local))
    }

    @Test
    fun `uncertain native move explicitly requires recovery`() {
        put(libraryDir.resolve("p.md"))
        val prompts = AndroidPromptStore(libraryDir.toFile(), object : AtomicPublication() {
            override fun move(source: Path, destination: Path) {
                super.move(source, destination)
                throw IOException("postmove failure")
            }
        })
        val library = library(prompts = prompts)
        val loaded = library.load("p.md")
        val result = assertIs<EditResult.Failed>(EditingService(library).move("p.md", "nested", loaded.stamp))
        assertFalse(Files.exists(libraryDir.resolve("p.md")))
        assertEquals("body", Files.readString(libraryDir.resolve("nested/p.md")))
        assertSame(LibraryError.RecoveryRequired, result.error)
    }

    @Test
    fun `corrupt and future state never silently resets or overwrites`() {
        val identity = PromptIdentity.at("p.md")
        for (bytes in listOf("broken".encodeToByteArray(), byteArrayOf(-1),
            "{\"version\":2,\"values\":{}}".encodeToByteArray(),
            "{\"version\":1,\"values\":[]}".encodeToByteArray())) {
            put(stateDir.resolve("values.json"), bytes)
            val library = library()
            assertFailsWith<LibraryError.OperationFailed> { library.values.rememberedValues(identity) }
            assertFailsWith<LibraryError.OperationFailed> { library.values.record(identity, mapOf("x" to "new")) }
            assertContentEquals(bytes, Files.readAllBytes(stateDir.resolve("values.json")))
            assertFailsWith<LibraryError.OperationFailed> { library().values.rememberedValues(identity) }
        }
        for (source in listOf("broken", "{\"version\":2,\"events\":[]}", "{\"version\":1,\"events\":[\"bad\"]}")) {
            val path = stateDir.resolve("usage/${identity.storageKey}")
            put(path, source.encodeToByteArray())
            assertFailsWith<LibraryError.OperationFailed> { library().usage.recordUse(identity) }
            assertEquals(source, Files.readString(path))
        }
    }

    @Test
    fun `explicit Forget all is the only reset of rejected remembered values`() {
        val identity = PromptIdentity.at("p.md")
        put(stateDir.resolve("values.json"), "{\"version\":9,\"values\":{}}".encodeToByteArray())
        val library = library()
        assertFailsWith<LibraryError.OperationFailed> { library.values.remove(identity) }
        library.values.removeAll()
        assertEquals("{\"values\":{},\"version\":1}", Files.readString(stateDir.resolve("values.json")))
        assertTrue(library().values.rememberedValues(identity).isEmpty())
    }

    @Test
    fun `first identity assignment migrates history sidecars usage and values on disk`() {
        put(libraryDir.resolve("p.md"), "raw body\r\n".encodeToByteArray())
        val library = library()
        val local = library.load("p.md").identity
        val state = AndroidStateStore(stateDir.toFile())
        state.create(byteArrayOf(1, -1), "history/${local.storageKey}/_sidecar")
        state.create(byteArrayOf(2), "history/${local.storageKey}/.sidecar")
        library.values.record(local, mapOf("name" to "remembered"))
        library.usage.recordUse(local)
        val assigned = library.assignIdentity("p.md").entry.identity
        assertIs<PromptIdentity.Assigned>(assigned)
        assertContentEquals(byteArrayOf(1, -1), state.read("history/${assigned.storageKey}/_sidecar"))
        assertContentEquals(byteArrayOf(2), state.read("history/${assigned.storageKey}/.sidecar"))
        assertTrue(state.listFiles().none { it.relativePath.startsWith("history/${local.storageKey}/") })
        assertNull(state.stamp("usage/${local.storageKey}"))
        assertEquals(1, library().usage.useEvents(assigned).size)
        assertEquals(mapOf("name" to "remembered"), library().values.rememberedValues(assigned))
        assertTrue(library.loadForEditing("p.md").source!!.endsWith("raw body\r\n"))
    }

    private fun document(source: String) = PromptCodec.parseFile(source.encodeToByteArray(), "p.md")
}
