package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.ports.PromptStore
import ch.lkmc.monkeyspaw.core.ports.StoredFile
import kotlinx.coroutines.*
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.*

internal class LibraryRepositoryTest : TemporaryFiles() {
    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun `a sync commit cannot join a foreground scan that already captured older files`() = runTest {
        val io = StandardTestDispatcher(testScheduler)
        val callerScheduler = TestCoroutineScheduler()
        val caller = StandardTestDispatcher(callerScheduler)
        val callerScope = CoroutineScope(SupervisorJob() + caller)
        val repository = repository(io)
        repository.withLibrary { _, editing -> editing.create("old", "old.md") }
        try {
            val foreground = callerScope.async { repository.refresh() }
            callerScheduler.runCurrent()
            runCurrent()
            assertFalse(foreground.isCompleted, "The scan finished but its caller has not resumed")
            put(libraryDir.resolve("new.md"))
            val committed = async { repository.refreshAfterCommit() }
            runCurrent()
            callerScheduler.runCurrent()
            runCurrent()
            foreground.await()
            assertEquals(listOf("new.md", "old.md"), committed.await().snapshot.prompts.map { it.entry.relativePath })
            assertEquals(listOf("new.md", "old.md"), repository.state.value.snapshot.prompts.map { it.entry.relativePath })
        } finally { callerScope.cancel() }
    }

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
    fun `startup and entry refreshes queued on one worker share one scan and result`() = runTest {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        var scans = 0
        val counted = object : PromptStore by prompts {
            override fun listFiles(): List<StoredFile> {
                scans++
                return prompts.listFiles()
            }
        }
        val library = library(prompts = counted)
        val repository = LibraryRepository(library, EditingService(library), prompts, StandardTestDispatcher(testScheduler))
        val startup = async(start = CoroutineStart.UNDISPATCHED) { repository.refresh() }
        val entry = async(start = CoroutineStart.UNDISPATCHED) { repository.refresh() }
        assertSame(startup.await(), entry.await())
        assertEquals(1, scans)

        put(libraryDir.resolve("new.md"))
        assertEquals(listOf("new.md"), repository.refresh().snapshot.prompts.map { it.entry.relativePath })
        assertEquals(2, scans, "A later foreground refresh must still rescan disk")
    }

    @Test
    fun `queued refreshes share a sanitized failure and a later retry scans again`() = runTest {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        var scans = 0
        var fail = true
        val counted = object : PromptStore by prompts {
            override fun listFiles(): List<StoredFile> {
                scans++
                if (fail) error("SECRET prompt body")
                return prompts.listFiles()
            }
        }
        val library = library(prompts = counted)
        val repository = LibraryRepository(library, EditingService(library), prompts, StandardTestDispatcher(testScheduler))
        val startup = async(start = CoroutineStart.UNDISPATCHED) { repository.refresh() }
        val entry = async(start = CoroutineStart.UNDISPATCHED) { repository.refresh() }
        val failed = startup.await()
        assertSame(failed, entry.await())
        assertEquals(1, scans)
        assertSame(LibraryError.OperationFailed, failed.error)
        assertFalse(failed.refreshing)
        fail = false
        assertNull(repository.refresh().error)
        assertEquals(2, scans)
    }

    @Test
    fun `cancelling a joined entry refresh leaves the startup scan and other callers running`() = runBlocking {
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { worker ->
            val prompts = AndroidPromptStore(libraryDir.toFile())
            val started = CountDownLatch(1)
            val release = CountDownLatch(1)
            val scans = AtomicInteger()
            val counted = object : PromptStore by prompts {
                override fun listFiles(): List<StoredFile> {
                    scans.incrementAndGet()
                    started.countDown()
                    check(release.await(5, TimeUnit.SECONDS))
                    return prompts.listFiles()
                }
            }
            val library = library(prompts = counted)
            val repository = LibraryRepository(library, EditingService(library), prompts, worker)
            val startup = async(start = CoroutineStart.UNDISPATCHED) { repository.refresh() }
            try {
                assertTrue(started.await(5, TimeUnit.SECONDS))
                val cancelled = async(start = CoroutineStart.UNDISPATCHED) { repository.refresh() }
                val entry = async(start = CoroutineStart.UNDISPATCHED) { repository.refresh() }
                cancelled.cancelAndJoin()
                release.countDown()
                assertSame(startup.await(), entry.await())
                assertEquals(1, scans.get())
                assertFalse(repository.state.value.refreshing)
            } finally { release.countDown() }
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
            put(stateDir.resolve("usage/${identity.storageKey}"), "{\"version\":9,\"events\":[]}".encodeToByteArray())
            put(libraryDir.resolve("new.md"))
            val failed = repository.refresh()
            assertNotNull(failed.error)
            assertEquals(snapshot, failed.snapshot)
            assertFalse(failed.refreshing)
        }
    }

    @Test
    fun `cancelled refresh clears its flag preserves the index and allows another refresh`() = runBlocking {
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { worker ->
            val prompts = AndroidPromptStore(libraryDir.toFile())
            var cancelNextScan = false
            val cancellable = object : PromptStore by prompts {
                override fun listFiles(): List<StoredFile> {
                    if (cancelNextScan) throw CancellationException("Cancelled scan")
                    return prompts.listFiles()
                }
            }
            val library = library(prompts = cancellable)
            val repository = LibraryRepository(library, EditingService(library), prompts, worker)
            repository.withLibrary { _, editing -> editing.create("Body", "p.md") }
            val snapshot = repository.state.value.snapshot
            cancelNextScan = true
            assertFailsWith<CancellationException> { repository.refresh() }
            assertFalse(repository.state.value.refreshing)
            assertNull(repository.state.value.error)
            assertEquals(snapshot, repository.state.value.snapshot)
            assertEquals(snapshot, library.index.snapshot())
            cancelNextScan = false
            assertFalse(repository.refresh().refreshing)
            assertEquals(listOf("p.md"), repository.state.value.snapshot.prompts.map { it.entry.relativePath })
        }
    }

    @Test
    fun `cancellation before IO starts cannot leave a refresh flag set`() = runTest {
        val repository = repository(StandardTestDispatcher(testScheduler))
        val refresh = launch(start = CoroutineStart.UNDISPATCHED) { repository.refresh() }
        refresh.cancelAndJoin()
        assertFalse(repository.state.value.refreshing)
        assertEquals(0L, repository.state.value.snapshot.version)
        assertFalse(Files.exists(filesDir))
    }

    @Test
    fun `an unexpected failure escaping refresh still clears its flag and preserves the index`() = runBlocking {
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { worker ->
            val prompts = AndroidPromptStore(libraryDir.toFile())
            var failNextScan = false
            val failing = object : PromptStore by prompts {
                override fun listFiles(): List<StoredFile> {
                    if (failNextScan) throw AssertionError("Unexpected scan failure")
                    return prompts.listFiles()
                }
            }
            val library = library(prompts = failing)
            val repository = LibraryRepository(library, EditingService(library), prompts, worker)
            repository.withLibrary { _, editing -> editing.create("Body", "p.md") }
            val snapshot = repository.state.value.snapshot
            failNextScan = true
            assertFailsWith<AssertionError> { repository.refresh() }
            assertFalse(repository.state.value.refreshing)
            assertEquals(snapshot, repository.state.value.snapshot)
            assertEquals(snapshot, library.index.snapshot())
            failNextScan = false
            assertFalse(repository.refresh().refreshing)
        }
    }

    private fun repository(worker: CoroutineDispatcher): LibraryRepository {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        val library = library(prompts = prompts)
        return LibraryRepository(library, EditingService(library), prompts, worker)
    }
}
