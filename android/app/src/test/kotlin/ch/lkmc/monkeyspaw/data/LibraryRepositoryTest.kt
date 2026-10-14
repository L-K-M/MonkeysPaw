package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.ports.PromptStore
import ch.lkmc.monkeyspaw.core.ports.StoredFile
import kotlinx.coroutines.*
import java.nio.file.Files
import java.util.concurrent.Executors
import kotlin.test.*

internal class LibraryRepositoryTest : TemporaryFiles() {
    @Test
    fun `startup and own mutations refresh on a worker and share the same graph`() = runBlocking {
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { worker ->
            val repository = repository(worker)
            val caller = Thread.currentThread()
            assertFalse(repository.refresh().refreshing)
            val graph = repository.withLibrary { library, editing ->
                assertNotEquals(caller, Thread.currentThread())
                assertIs<EditResult.Saved>(editing.create("Body", "p.md"))
                library
            }
            assertEquals(listOf("p.md"), repository.state.value.snapshot.prompts.map { it.entry.relativePath })
            repository.withLibrary { library, _ ->
                assertSame(graph, library)
                library.index.recordUse(library.load("p.md").identity)
            }
            assertEquals(1, repository.state.value.snapshot.prompts.single().useEvents.size)
            assertEquals(1, graph.index.snapshot().prompts.single().useEvents.size)
        }
    }

    @Test
    fun `concurrent clients serialize complete IO and snapshot publication`() = runBlocking {
        Executors.newFixedThreadPool(2).asCoroutineDispatcher().use { worker ->
            val repository = repository(worker)
            repository.withLibrary { _, editing -> assertIs<EditResult.Saved>(editing.create("Body", "p.md")) }
            val versions = coroutineScope {
                (1..30).map { async(Dispatchers.Default) {
                    repository.withLibrary { library, _ ->
                        library.index.recordUse(library.load("p.md").identity)
                        library.index.snapshot().version
                    }
                } }.awaitAll()
            }
            assertEquals(30, versions.toSet().size)
            assertEquals(30, repository.state.value.snapshot.prompts.single().useEvents.size)
            assertNull(repository.state.value.error)
            assertEquals(versions.max(), repository.state.value.snapshot.version)
            val restarted = repository(worker)
            assertEquals(30, restarted.refresh().snapshot.prompts.single().useEvents.size)
        }
    }

    @Test
    fun `foreground discovers external changes and ignores library metadata`() = runBlocking {
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { worker ->
            val repository = repository(worker)
            repository.refresh()
            put(libraryDir.resolve("new.md"))
            put(libraryDir.resolve("_scratch/ignored.md"))
            assertEquals(listOf("new.md"), repository.refresh().snapshot.prompts.map { it.entry.relativePath })
            Files.delete(libraryDir.resolve("new.md"))
            assertTrue(repository.refresh().snapshot.prompts.isEmpty())
        }
    }

    @Test
    fun `a vanished root preserves the warm index and is not silently recreated`() = runBlocking {
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { worker ->
            val repository = repository(worker)
            repository.withLibrary { _, editing -> editing.create("Body", "p.md") }
            val snapshot = repository.state.value.snapshot
            Files.move(libraryDir, filesDir.resolve("old-library"))
            val failed = repository.refresh()
            assertNotNull(failed.error)
            assertEquals(snapshot, failed.snapshot)
            assertFalse(Files.exists(libraryDir))
        }
    }

    @Test
    fun `a root removed between readiness check and scan cannot erase either index publication`() = runBlocking {
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { worker ->
            val prompts = AndroidPromptStore(libraryDir.toFile())
            var removeOnScan = false
            val disappearing = object : PromptStore by prompts {
                override fun listFiles(): List<StoredFile> {
                    if (removeOnScan) Files.move(libraryDir, filesDir.resolve("old-library"))
                    return prompts.listFiles()
                }
            }
            val library = library(prompts = disappearing)
            val repository = LibraryRepository(library, EditingService(library), prompts, worker)
            repository.withLibrary { _, editing -> editing.create("Body", "p.md") }
            val snapshot = repository.state.value.snapshot
            removeOnScan = true
            val failed = repository.refresh()
            assertNotNull(failed.error)
            assertEquals(snapshot, failed.snapshot)
            assertEquals(snapshot, library.index.snapshot())
            assertFalse(Files.exists(libraryDir))
        }
    }

    @Test
    fun `a failed complete rescan keeps the last index rather than publishing partial reads`() = runBlocking {
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { worker ->
            val repository = repository(worker)
            val identity = repository.withLibrary { _, editing ->
                assertIs<EditResult.Saved>(editing.create("Body", "p.md")).commit.entry.identity
            }
            val snapshot = repository.state.value.snapshot
            put(filesDir.resolve("usage/${identity.storageKey}"), "{\"version\":9,\"events\":[]}".encodeToByteArray())
            put(libraryDir.resolve("new.md"))
            val failed = repository.refresh()
            assertNotNull(failed.error)
            assertEquals(snapshot, failed.snapshot)
            assertFalse(failed.refreshing)
        }
    }

    private fun repository(worker: CoroutineDispatcher): LibraryRepository {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        val library = library(prompts = prompts)
        return LibraryRepository(library, EditingService(library), prompts, worker)
    }
}
