package ch.lkmc.monkeyspaw.data

import androidx.datastore.core.DataStoreFactory
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import kotlinx.coroutines.*
import java.io.File
import java.io.IOException
import java.nio.file.Files
import kotlin.test.*

internal class SeedInstallerTest : TemporaryFiles() {
    private val assets = File(checkNotNull(System.getProperty("monkeyspaw.seedAssets")))
    private val catalog = AndroidSeedCatalog { assets.resolve(it).readBytes() }

    @Test
    fun `empty library offers until a decision and decline survives new settings and graph`() = runBlocking {
        withInstaller { installer, _, settings ->
            assertTrue(installer.shouldOffer())
            assertTrue(installer.shouldOffer())
            assertEquals(SeedProgress.NOT_OFFERED, settings.read().seedProgress)
        }
        withInstaller { installer, _, settings ->
            assertTrue(installer.shouldOffer())
            installer.decline()
            assertEquals(SeedProgress.DECLINED, settings.read().seedProgress)
            assertFalse(installer.shouldOffer())
            assertEquals(SeedInstallResult(SeedSummary()), installer.install())
        }
        withInstaller { installer, repository, _ ->
            assertFalse(installer.shouldOffer())
            assertEquals(SeedInstallResult(SeedSummary()), installer.install())
            assertTrue(repository.refresh().snapshot.prompts.isEmpty())
        }
    }

    @Test
    fun `real first saves have unique fresh ids exact bodies and no history and never repeat`() = runBlocking {
        var saved: Map<String, List<Byte>> = emptyMap()
        var stamps: List<FileStamp> = emptyList()
        withInstaller { installer, repository, settings ->
            assertTrue(installer.shouldOffer())
            assertEquals(SeedInstallResult(SeedSummary(10)), installer.install())
            assertEquals(SeedProgress.COMPLETE, settings.read().seedProgress)
            repository.withLibrary { library, _ ->
                val entries = library.entries()
                assertEquals(catalog.prompts().map { it.relativePath }, entries.map { it.relativePath })
                assertEquals(10, entries.map { it.identity }.toSet().size)
                for ((seed, entry) in catalog.prompts().zip(entries)) {
                    val source = PromptCodec.parseFile(seed.bytes, seed.relativePath.substringAfterLast('/'))
                    assertNull(source.frontMatter.id)
                    assertNotNull(entry.document.frontMatter.id)
                    assertContentEquals(source.body.encodeToByteArray(), entry.document.body.encodeToByteArray())
                    assertEquals(source.frontMatter.fields, entry.document.frontMatter.fields)
                    assertTrue(entry.issues.isEmpty())
                    assertTrue(library.history.revisions(entry.identity).isEmpty())
                    assertContentEquals(PromptCodec.write(entry.document).encodeToByteArray(), Files.readAllBytes(libraryDir.resolve(entry.relativePath)))
                }
                saved = entries.associate { it.relativePath to Files.readAllBytes(libraryDir.resolve(it.relativePath)).toList() }
                stamps = entries.map { it.stamp }
            }
            assertFalse(installer.shouldOffer())
            assertEquals(SeedInstallResult(SeedSummary()), installer.install())
            installer.decline()
            assertEquals(SeedProgress.COMPLETE, settings.read().seedProgress)
        }
        withInstaller { installer, repository, _ ->
            assertFalse(installer.shouldOffer())
            assertEquals(SeedInstallResult(SeedSummary()), installer.install())
            repository.withLibrary { library, _ ->
                assertEquals(stamps, library.entries().map { it.stamp })
                assertEquals(saved, library.entries().associate { it.relativePath to Files.readAllBytes(libraryDir.resolve(it.relativePath)).toList() })
            }
        }
    }

    @Test
    fun `invalid existing prompt consumes the offer without changing bytes even after deletion`() = runBlocking {
        val invalid = byteArrayOf(-1, -2, 13, 10)
        put(libraryDir.resolve("broken.md"), invalid)
        withInstaller { installer, repository, settings ->
            assertFalse(installer.shouldOffer())
            assertEquals(SeedProgress.COMPLETE, settings.read().seedProgress)
            assertEquals(SeedInstallResult(SeedSummary()), installer.install())
            assertContentEquals(invalid, Files.readAllBytes(libraryDir.resolve("broken.md")))
            assertEquals(1, repository.refresh().snapshot.prompts.size)
        }
        Files.delete(libraryDir.resolve("broken.md"))
        withInstaller { installer, _, _ -> assertFalse(installer.shouldOffer()) }
    }

    @Test
    fun `nonempty library arriving after offer is rechecked and never overwritten`() = runBlocking {
        val original = "User prompt\r\n".encodeToByteArray()
        withInstaller { installer, repository, _ ->
            assertTrue(installer.shouldOffer())
            put(libraryDir.resolve(catalog.prompts().first().relativePath), original)
            assertEquals(SeedInstallResult(SeedSummary()), installer.install())
            assertContentEquals(original, Files.readAllBytes(libraryDir.resolve(catalog.prompts().first().relativePath)))
            assertEquals(1, repository.refresh().snapshot.prompts.size)
            assertFalse(installer.shouldOffer())
        }
        withInstaller { installer, _, _ -> assertFalse(installer.shouldOffer()) }
    }

    @Test
    fun `README and ignored files survive while a nested README blocks installation`() = runBlocking {
        val ignored = listOf("README.md", "notes.txt", "a.MD", "_drafts/prompt.md", ".git/prompt.md", "_private.md")
        for (path in ignored) put(libraryDir.resolve(path), "Keep\r\n".encodeToByteArray())
        withInstaller { installer, _, _ ->
            assertTrue(installer.shouldOffer())
            assertEquals(SeedInstallResult(SeedSummary(10)), installer.install())
        }
        for (path in ignored) assertEquals("Keep\r\n", Files.readString(libraryDir.resolve(path)))
        // A second private root represents a different first-run library.
        val nestedRoot = filesDir.resolve("nested-library")
        put(nestedRoot.resolve("notes/README.md"))
        withInstaller(AndroidPromptStore(nestedRoot.toFile()), settingsFile = filesDir.resolve("nested-settings.json").toFile()) { installer, _, _ ->
            assertFalse(installer.shouldOffer())
            assertEquals(SeedInstallResult(SeedSummary()), installer.install())
        }
        assertEquals("body", Files.readString(nestedRoot.resolve("notes/README.md")))
    }

    @Test
    fun `a destination race skips only that seed atomically with original stamp and bytes`() = runBlocking {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        val path = catalog.prompts().first().relativePath
        val original = "External\r\n".encodeToByteArray()
        var externalStamp: FileStamp? = null
        var createCount = 0
        val raced = object : PromptStore by prompts {
            override fun create(bytes: ByteArray, path: String) {
                if (createCount++ == 0) {
                    prompts.create(original, path)
                    externalStamp = prompts.stamp(path)
                }
                prompts.create(bytes, path)
            }
        }
        withInstaller(prompts, raced) { installer, repository, settings ->
            assertEquals(SeedInstallResult(SeedSummary(9, 1)), installer.install())
            assertEquals(SeedProgress.COMPLETE, settings.read().seedProgress)
            assertContentEquals(original, prompts.read(path))
            assertEquals(externalStamp, prompts.stamp(path))
            assertEquals(10, repository.refresh().snapshot.prompts.size)
        }
        withInstaller { installer, _, _ -> assertFalse(installer.shouldOffer()) }
    }

    @Test
    fun `partial failure reports progress keeps exact body and restart never fills missing seeds`() = runBlocking {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        var attempts = 0
        val failed = object : PromptStore by prompts {
            override fun create(bytes: ByteArray, path: String) {
                assertTrue(Files.readString(filesDir.resolve("datastore/settings.json")).contains("INSTALLING"))
                if (++attempts == 2) throw StoreError.IOFailure
                prompts.create(bytes, path)
            }
        }
        val firstPath = catalog.prompts().first().relativePath
        var saved: ByteArray = byteArrayOf()
        var stamp: FileStamp? = null
        withInstaller(prompts, failed) { installer, repository, settings ->
            val result = installer.install()
            assertEquals(SeedSummary(1), result.summary)
            assertSame(StoreError.IOFailure, result.error)
            assertEquals(SeedProgress.INSTALLING, settings.read().seedProgress)
            assertFalse(installer.shouldOffer())
            assertEquals(1, repository.state.value.snapshot.prompts.size)
            assertEquals(SeedInstallResult(SeedSummary()), installer.install())
            repository.withLibrary { library, _ ->
                val entry = library.entries().single()
                assertContentEquals(PromptCodec.parseFile(catalog.prompts().first().bytes, firstPath.substringAfterLast('/')).body.encodeToByteArray(),
                    entry.document.body.encodeToByteArray())
                assertNotNull(entry.document.frontMatter.id)
                stamp = entry.stamp
            }
            saved = prompts.read(firstPath)
        }
        withInstaller { installer, repository, _ ->
            assertFalse(installer.shouldOffer())
            assertEquals(SeedInstallResult(SeedSummary()), installer.install())
            assertEquals(1, repository.refresh().snapshot.prompts.size)
            assertContentEquals(saved, prompts.read(firstPath))
            assertEquals(stamp, prompts.stamp(firstPath))
        }
        assertEquals(2, attempts)
    }

    @Test
    fun `failure or cancellation before first publication consumes the durable decision`() = runBlocking {
        for (cancel in listOf(false, true)) {
            val prompts = AndroidPromptStore(libraryDir.toFile())
            val failed = object : PromptStore by prompts {
                override fun create(bytes: ByteArray, path: String) {
                    if (cancel) throw CancellationException("Cancelled")
                    throw IOException("SECRET path and body")
                }
            }
            val settingsFile = filesDir.resolve("settings-$cancel.json").toFile()
            withInstaller(prompts, failed, settingsFile) { installer, repository, settings ->
                if (cancel) assertFailsWith<CancellationException> { installer.install() }
                else {
                    val result = installer.install()
                    assertEquals(SeedSummary(), result.summary)
                    assertSame(LibraryError.OperationFailed, result.error)
                    assertFalse(result.error.toString().contains("SECRET"))
                }
                assertTrue(repository.refresh().snapshot.prompts.isEmpty())
                assertEquals(SeedProgress.INSTALLING, settings.read().seedProgress)
                assertFalse(installer.shouldOffer())
            }
            withInstaller(settingsFile = settingsFile) { installer, _, _ ->
                assertFalse(installer.shouldOffer())
                assertEquals(SeedInstallResult(SeedSummary()), installer.install())
            }
        }
    }

    @Test
    fun `concurrent accepts and stale declines cannot seed twice or rewind progress`() = runBlocking {
        withInstaller { installer, repository, settings ->
            assertTrue(installer.shouldOffer())
            val results = coroutineScope { (1..6).map { async { installer.install() } }.awaitAll() }
            assertEquals(10, results.sumOf { it.summary.seededCount })
            assertTrue(results.all { it.error == null })
            installer.decline()
            assertEquals(SeedProgress.COMPLETE, settings.read().seedProgress)
            assertEquals(10, repository.refresh().snapshot.prompts.size)
        }
    }

    @Test
    fun `unwritable progress prevents every create and unreadable settings never offer`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val settings = AndroidSettingsStore(DataStoreFactory.create(serializer = SettingsSerializer, scope = scope,
                produceFile = { throw IOException("SECRET path") }))
            val prompts = AndroidPromptStore(libraryDir.toFile())
            val library = library(prompts = prompts)
            val repository = LibraryRepository(library, EditingService(library), prompts, Dispatchers.IO)
            val installer = SeedInstaller(repository, settings, catalog, Dispatchers.IO)
            assertFailsWith<StoreError.IOFailure> { installer.shouldOffer() }
            val result = installer.install()
            assertEquals(SeedSummary(), result.summary)
            assertNotNull(result.error)
            assertFalse(Files.exists(libraryDir))
        } finally { scope.coroutineContext.job.cancelAndJoin() }
    }

    private suspend fun withInstaller(
        prompts: AndroidPromptStore = AndroidPromptStore(libraryDir.toFile()),
        store: PromptStore = prompts,
        settingsFile: File = filesDir.resolve("datastore/settings.json").toFile(),
        work: suspend (SeedInstaller, LibraryRepository, AndroidSettingsStore) -> Unit,
    ) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val settings = AndroidSettingsStore(DataStoreFactory.create(serializer = SettingsSerializer, scope = scope,
                produceFile = { settingsFile }))
            val library = library(prompts = store)
            val repository = LibraryRepository(library, EditingService(library), prompts, Dispatchers.IO)
            work(SeedInstaller(repository, settings, catalog, Dispatchers.IO), repository, settings)
        } finally { scope.coroutineContext.job.cancelAndJoin() }
    }
}
