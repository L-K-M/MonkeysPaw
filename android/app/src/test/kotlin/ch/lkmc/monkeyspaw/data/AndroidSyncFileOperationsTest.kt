package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.ports.*
import java.io.IOException
import java.nio.file.*
import java.nio.file.attribute.PosixFilePermissions
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.*

internal class AndroidSyncFileOperationsTest : TemporaryFiles() {
    private val io = JvmCheckedSyncIO()
    private val store by lazy { AndroidPromptStore(libraryDir.toFile(), io = io).also { it.prepareRoot() } }
    private val sync get() = store.syncOperations
    private val original = byteArrayOf(0, -1, 13, 10)
    private val replacement = byteArrayOf(-2, 0, 10, 13, 42)

    @Test
    fun `full inventory includes every regular occupant while the index stays filtered`() {
        val paths = listOf("README.md", "p.md", ".visible.md", "_scratch/p.md", ".git/p.md", "a/_p.md",
            "a/.hidden/p.md", "p.MD", "notes.txt", ".monkeyspaw-orphan.tmp", "Groups/Team/.unknown", "Conflicts/raw")
        paths.forEach { put(libraryDir.resolve(it), original) }
        listOf("empty", ".hidden-empty", "_empty", "Groups/Unowned").forEach { Files.createDirectories(libraryDir.resolve(it)) }
        assertEquals(paths.sorted(), sync.listFiles().map { it.relativePath }.sorted())
        assertEquals(listOf(".visible.md", "p.md"), store.listFiles().map { it.relativePath })
        assertEquals(listOf(".git", ".hidden-empty", "Conflicts", "Groups", "_empty", "_scratch", "a", "empty"), sync.directories(null))
        assertEquals(listOf("Groups/Team", "Groups/Unowned"), sync.directories("Groups"))
        assertContentEquals(original, store.read("Conflicts/raw"))
        assertTrue(Files.exists(libraryDir.resolve(".monkeyspaw-orphan.tmp")))
    }

    @Test
    fun `inventory keeps exact Unicode spelling and unsigned UTF8 order`() {
        val paths = listOf("é.md", "e\u0301.md", "\uE000.md", "\uD800\uDC00.md", "_a", ".hidden/file")
        paths.forEach { put(libraryDir.resolve(it), original) }
        assertEquals(listOf(".hidden/file", "_a", "e\u0301.md", "é.md", "\uE000.md", "\uD800\uDC00.md"),
            sync.listFiles().map { it.relativePath })
        sync.listFiles().forEach { assertEquals(store.stamp(it.relativePath), it.stamp) }
    }

    @Test
    fun `state checked capability uses the same root and includes staged orphans`() {
        val state = AndroidStateStore(stateDir.toFile(), io = io)
        state.writePrivate(original, "sync/state.json")
        put(stateDir.resolve(".monkeyspaw-orphan.tmp"))
        put(libraryDir.resolve("private.md"))
        state.syncOperations.flushFile("sync/state.json")
        state.syncOperations.flushDirectory("sync")
        state.syncOperations.flushDirectory(null)
        assertEquals(listOf("sync/state.json"), state.listFiles().map { it.relativePath })
        assertEquals(listOf(".monkeyspaw-orphan.tmp", "sync/state.json"), state.syncOperations.listFiles().map { it.relativePath })
        val expected = matching(state, "sync/state.json")
        state.syncOperations.publish(replacement, "sync/state.json", expected, SyncFileMode.NORMAL)
        assertContentEquals(replacement, state.read("sync/state.json"))
        mode(stateDir.resolve("sync/state.json"), "rw-------")
        failure(SyncFileFailureCode.NOT_FOUND) { state.syncOperations.flushFile("private.md") }
    }

    @Test
    fun `fresh root establishment checks every newly created ancestor and its parent`() {
        sync.listFiles()
        assertTrue(io.flushedDirectories.containsAll(listOf(libraryDir, filesDir, temporary)))
        val state = AndroidStateStore(stateDir.toFile(), io = io)
        state.writePrivate(original, "sync/state.json")
        io.onFlush = { path -> if (path == filesDir) throw IOException("new state root parent") }
        failure(SyncFileFailureCode.DURABILITY_FAILED, SyncFileMutationEffect.APPLIED) {
            state.syncOperations.flushFile("sync/state.json")
        }
        assertContentEquals(original, state.read("sync/state.json"))
        io.onFlush = { }
        state.syncOperations.flushFile("sync/state.json")
        state.syncOperations.flushDirectory("sync")
        state.syncOperations.flushDirectory(null)
    }

    @Test
    fun `complete group wrapper is accepted by checked publication and plus one fails before mutation`() {
        val wire = listOf("a".repeat(255), "b".repeat(255), "c".repeat(255), "x", "d".repeat(251) + ".md").joinToString("/")
        val path = "Groups/" + "f".repeat(255) + "/" + wire
        assertEquals(Limits.maxRootedPathBytes, path.encodeToByteArray().size)
        sync.publish(original, path, SyncFileExpectation.Absent, SyncFileMode.READ_ONLY)
        assertContentEquals(original, store.read(path))
        failure(SyncFileFailureCode.INVALID_PATH) { sync.publish(replacement, path + "x", SyncFileExpectation.Absent, SyncFileMode.NORMAL) }
        assertOnlyFiles(path)
    }

    @Test
    fun `unsafe lexical paths fail on every entry point before creating any root`() {
        val operations = AndroidPromptStore(libraryDir.toFile(), io = io).syncOperations
        for (path in listOf("", "/absolute", "../escape", "a/../p", "a//p", "a/./p", "a\\p", "a/\u0000p",
            "a/\u202Ep", "\uD800", "a".repeat(Limits.maxRootedPathBytes + 1))) {
            val actions = listOf<() -> Any?>(
                { operations.publish(original, path, SyncFileExpectation.Absent, SyncFileMode.NORMAL) },
                { operations.flushFile(path) }, { operations.flushDirectory(path) },
                { operations.setMode(SyncFileMode.READ_ONLY, path) }, { operations.trash(path, SyncFileExpectation.Absent) },
                { operations.createDirectory(path) }, { operations.renameDirectory(path, "valid") },
                { operations.renameDirectory("valid", path) }, { operations.directories(path) },
                { operations.directoryIdentity(path) }, { operations.removeEmptyDirectory(path, FileStamp("unused")) })
            actions.forEach { failure(SyncFileFailureCode.INVALID_PATH, work = it) }
        }
        assertFalse(Files.exists(filesDir))
    }

    @Test
    fun `sync never treats an unavailable root as an empty inventory or prepares it implicitly`() {
        val missing = AndroidPromptStore(libraryDir.toFile(), io = io)
        failure(SyncFileFailureCode.NOT_FOUND) { missing.syncOperations.listFiles() }
        failure(SyncFileFailureCode.NOT_FOUND) { missing.syncOperations.directories(null) }
        failure(SyncFileFailureCode.NOT_FOUND) { missing.syncOperations.publish(original, "p.md", SyncFileExpectation.Absent, SyncFileMode.NORMAL) }
        assertFalse(Files.exists(filesDir))
        missing.prepareRoot()
        missing.syncOperations.listFiles()
        Files.delete(libraryDir)
        failure(SyncFileFailureCode.NOT_FOUND) { missing.syncOperations.listFiles() }
        assertFailsWith<StoreError.NotFound> { missing.prepareRoot() }
        assertFailsWith<StoreError.NotFound> { missing.create(original, "p.md") }
        assertFalse(Files.exists(libraryDir))
    }

    @Test
    fun `runtime root replacement blocks existing graph and ordinary writes`() {
        sync.listFiles()
        Files.move(libraryDir, filesDir.resolve("old-library"))
        Files.createDirectory(libraryDir)
        failure(SyncFileFailureCode.INVALID_PATH) { sync.listFiles() }
        failure(SyncFileFailureCode.INVALID_PATH) { sync.publish(original, "p.md", SyncFileExpectation.Absent, SyncFileMode.NORMAL) }
        assertFailsWith<StoreError.InvalidRoot> { store.prepareRoot() }
        assertFailsWith<StoreError.InvalidRoot> { store.write(original, "p.md") }
        assertFalse(Files.exists(libraryDir.resolve("p.md")))
        assertTrue(AndroidPromptStore(libraryDir.toFile(), io = JvmCheckedSyncIO()).syncOperations.listFiles().isEmpty())
    }

    @Test
    fun `root and canonical ancestor links cannot redirect checked work`() {
        val outside = temporary.resolve("outside")
        put(outside.resolve("p.md"), original)
        Files.createDirectories(filesDir)
        Files.createSymbolicLink(libraryDir, outside)
        val linked = AndroidPromptStore(libraryDir.toFile(), io = io).syncOperations
        failure(SyncFileFailureCode.INVALID_PATH) { linked.listFiles() }
        failure(SyncFileFailureCode.INVALID_PATH) { linked.flushFile("p.md") }
        Files.delete(libraryDir)
        val real = AndroidPromptStore(libraryDir.toFile(), io = io)
        real.prepareRoot()
        real.syncOperations.listFiles()
        Files.move(filesDir, temporary.resolve("old-files"))
        Files.createSymbolicLink(filesDir, outside)
        failure(SyncFileFailureCode.INVALID_PATH) { real.syncOperations.flushDirectory(null) }
        assertContentEquals(original, Files.readAllBytes(outside.resolve("p.md")))
    }

    @Test
    fun `full inventory refuses symlinks instead of reporting an incomplete absence`() {
        val outside = temporary.resolve("outside")
        put(outside.resolve("private.md"), original)
        store.prepareRoot()
        for (target in listOf(outside, outside.resolve("private.md"), outside.resolve("absent"))) {
            val link = libraryDir.resolve("link")
            Files.createSymbolicLink(link, target)
            assertTrue(store.listFiles().isEmpty())
            failure(SyncFileFailureCode.INVALID_PATH) { sync.listFiles() }
            failure(SyncFileFailureCode.INVALID_PATH) { sync.directories(null) }
            failure(SyncFileFailureCode.INVALID_PATH) { sync.directoryIdentity("link") }
            failure(SyncFileFailureCode.OCCUPIED) { sync.createDirectory("link") }
            failure(SyncFileFailureCode.OCCUPIED) { sync.publish(replacement, "link", SyncFileExpectation.Absent, SyncFileMode.NORMAL) }
            failure(SyncFileFailureCode.INVALID_PATH) { sync.flushFile("link") }
            failure(SyncFileFailureCode.INVALID_PATH) { sync.setMode(SyncFileMode.NORMAL, "link") }
            Files.delete(link)
        }
        assertContentEquals(original, Files.readAllBytes(outside.resolve("private.md")))
    }

    @Test
    fun `symlinked parent is refused for reads modes publication unlink and directory lifecycle`() {
        val outside = temporary.resolve("outside")
        put(outside.resolve("p.md"), original)
        store.prepareRoot()
        Files.createSymbolicLink(libraryDir.resolve("link"), outside)
        val expected = SyncFileExpectation.Matching(FileStamp("unused"), original)
        val actions = listOf<() -> Any?>(
            { sync.publish(replacement, "link/p.md", expected, SyncFileMode.NORMAL) },
            { sync.flushFile("link/p.md") }, { sync.flushDirectory("link") },
            { sync.setMode(SyncFileMode.READ_ONLY, "link/p.md") }, { sync.trash("link/p.md", expected) },
            { sync.createDirectory("link/new") }, { sync.renameDirectory("link/sub", "new") },
            { sync.directories("link") }, { sync.directoryIdentity("link/sub") },
            { sync.removeEmptyDirectory("link/sub", FileStamp("unused")) })
        actions.forEach { failure(SyncFileFailureCode.INVALID_PATH, work = it) }
        assertContentEquals(original, Files.readAllBytes(outside.resolve("p.md")))
        assertFalse(Files.exists(outside.resolve("new")))
    }

    @Test
    fun `complete exact bytes and requested modes are installed before exclusive publication`() {
        val publication = object : AtomicPublication() {
            override fun create(temporary: Path, destination: Path) {
                mode(temporary, "r--r--r--")
                assertContentEquals(original, Files.readAllBytes(temporary))
                super.create(temporary, destination)
            }
        }
        val custom = AndroidPromptStore(libraryDir.toFile(), publication, io).also { it.prepareRoot() }
        val result = custom.syncOperations.publish(original, "Groups/Team/p.md", SyncFileExpectation.Absent, SyncFileMode.READ_ONLY)
        assertNull(result.displacedBytes)
        assertContentEquals(original, custom.read("Groups/Team/p.md"))
        mode(libraryDir.resolve("Groups/Team/p.md"), "r--r--r--")
        assertTrue(io.flushedDirectories.containsAll(listOf(libraryDir.resolve("Groups/Team"), libraryDir.resolve("Groups"), libraryDir)))
        assertEquals(listOf("Groups/Team/p.md"), custom.syncOperations.listFiles().map { it.relativePath })
    }

    @Test
    fun `replacements and replays reapply read only or private normal mode and retain owned losing bytes`() {
        sync.publish(original, "p.md", SyncFileExpectation.Absent, SyncFileMode.READ_ONLY)
        val result = sync.publish(replacement, "p.md", matching(store, "p.md"), SyncFileMode.NORMAL)
        assertContentEquals(original, result.displacedBytes)
        result.displacedBytes!![0] = 90
        assertContentEquals(original, result.displacedBytes)
        mode(libraryDir.resolve("p.md"), "rw-------")
        sync.publish(replacement, "p.md", matching(store, "p.md"), SyncFileMode.READ_ONLY)
        mode(libraryDir.resolve("p.md"), "r--r--r--")
        sync.setMode(SyncFileMode.NORMAL, "p.md")
        mode(libraryDir.resolve("p.md"), "rw-------")
        sync.setMode(SyncFileMode.READ_ONLY, "p.md")
        sync.flushFile("p.md")
        mode(libraryDir.resolve("p.md"), "r--r--r--")
        assertContentEquals(replacement, store.read("p.md"))
    }

    @Test
    fun `publication rejects changed bytes and recreated incarnation with identical bytes`() {
        store.create(original, "p.md")
        val expected = matching(store, "p.md")
        failure(SyncFileFailureCode.CHANGED) {
            sync.publish(replacement, "p.md", SyncFileExpectation.Matching(expected.stamp, replacement), SyncFileMode.NORMAL)
        }
        store.write(original, "p.md")
        failure(SyncFileFailureCode.CHANGED) { sync.publish(replacement, "p.md", expected, SyncFileMode.NORMAL) }
        assertContentEquals(original, store.read("p.md"))
        assertOnlyFiles("p.md")
    }

    @Test
    fun `publication rechecks the final baseline after staging and preserves intervening edit`() {
        store.create(original, "p.md")
        val expected = matching(store, "p.md")
        io.before = { mutation, _ -> if (mutation == CheckedSyncIO.Mutation.PUBLISH) store.write("race".encodeToByteArray(), "p.md") }
        failure(SyncFileFailureCode.CHANGED) { sync.publish(replacement, "p.md", expected, SyncFileMode.READ_ONLY) }
        assertEquals("race", store.read("p.md").decodeToString())
        assertOnlyFiles("p.md")
    }

    @Test
    fun `exclusive publication refuses empty directory hidden unowned file and final syscall race`() {
        store.prepareRoot()
        Files.createDirectory(libraryDir.resolve("occupied"))
        put(libraryDir.resolve("_hidden"), original)
        for (path in listOf("occupied", "_hidden")) {
            failure(SyncFileFailureCode.OCCUPIED) { sync.publish(replacement, path, SyncFileExpectation.Absent, SyncFileMode.NORMAL) }
        }
        val raced = AndroidPromptStore(libraryDir.toFile(), object : AtomicPublication() {
            override fun create(temporary: Path, destination: Path) {
                Files.write(destination, original, StandardOpenOption.CREATE_NEW)
                super.create(temporary, destination)
            }
        }, io)
        failure(SyncFileFailureCode.OCCUPIED) { raced.syncOperations.publish(replacement, "new.md", SyncFileExpectation.Absent, SyncFileMode.NORMAL) }
        assertContentEquals(original, raced.read("new.md"))
    }

    @Test
    fun `two concurrent exclusive publishers cannot overwrite each other`() {
        store.prepareRoot()
        sync.listFiles()
        val ready = CountDownLatch(2)
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val results = listOf(original, replacement).map { bytes -> executor.submit<Any> {
                val operations = AndroidPromptStore(libraryDir.toFile(), io = JvmCheckedSyncIO()).syncOperations
                ready.countDown()
                check(start.await(10, TimeUnit.SECONDS))
                try { operations.publish(bytes, "p.md", SyncFileExpectation.Absent, SyncFileMode.NORMAL) }
                catch (error: SyncFileOperationError) { error }
            } }
            assertTrue(ready.await(10, TimeUnit.SECONDS))
            start.countDown()
            val values = results.map { it.get(10, TimeUnit.SECONDS) }
            assertEquals(1, values.count { it is SyncFilePublication })
            assertEquals(SyncFileFailureCode.OCCUPIED, values.filterIsInstance<SyncFileOperationError>().single().code)
            assertTrue(listOf(original, replacement).any { it.contentEquals(store.read("p.md")) })
        } finally { start.countDown(); executor.shutdownNow() }
    }

    @Test
    fun `staging and prepublication flush failures preserve the original destination`() {
        store.create(original, "p.md")
        io.onFlush = { path -> if (path.fileName.toString().startsWith(".monkeyspaw-")) throw IOException("private sentinel") }
        failure(SyncFileFailureCode.DURABILITY_FAILED) {
            sync.publish(replacement, "p.md", matching(store, "p.md"), SyncFileMode.READ_ONLY)
        }
        assertContentEquals(original, store.read("p.md"))
        assertOnlyFiles("p.md")
    }

    @Test
    fun `native publication failure before mutation leaves original bytes unchanged`() {
        val prompts = AndroidPromptStore(libraryDir.toFile(), object : AtomicPublication() {
            override fun replace(temporary: Path, destination: Path) { throw IOException("private native failure") }
        }, io).also { it.prepareRoot() }
        prompts.create(original, "p.md")
        failure(SyncFileFailureCode.IO_FAILURE) {
            prompts.syncOperations.publish(replacement, "p.md", matching(prompts, "p.md"), SyncFileMode.NORMAL)
        }
        assertContentEquals(original, prompts.read("p.md"))
    }

    @Test
    fun `published bytes are verified before a successful durability acknowledgement`() {
        val prompts = AndroidPromptStore(libraryDir.toFile(), object : AtomicPublication() {
            override fun replace(temporary: Path, destination: Path) {
                super.replace(temporary, destination)
                Files.write(destination, "intervening external edit".encodeToByteArray())
            }
        }, io).also { it.prepareRoot() }
        prompts.create(original, "p.md")
        val error = failure(SyncFileFailureCode.CHANGED, SyncFileMutationEffect.APPLIED) {
            prompts.syncOperations.publish(replacement, "p.md", matching(prompts, "p.md"), SyncFileMode.NORMAL)
        }
        assertContentEquals(original, error.displacedBytes)
        assertEquals("intervening external edit", prompts.read("p.md").decodeToString())
    }

    @Test
    fun `creating parents then failing staging reports applied directories without a file`() {
        sync.listFiles()
        io.onFlush = { path -> if (path.fileName.toString().startsWith(".monkeyspaw-")) throw IOException("staging failed") }
        failure(SyncFileFailureCode.DURABILITY_FAILED, SyncFileMutationEffect.APPLIED) {
            sync.publish(original, "new/deep/p.md", SyncFileExpectation.Absent, SyncFileMode.NORMAL)
        }
        assertTrue(Files.isDirectory(libraryDir.resolve("new/deep")))
        assertFalse(Files.exists(libraryDir.resolve("new/deep/p.md")))
    }

    @Test
    fun `every postpublication flush failure reports applied and preserves displaced bytes`() {
        for (suffix in listOf("nested/deep/p.md", "nested/deep", "nested", "")) {
            val root = temporary.resolve("case-${suffix.replace('/', '-')}")
            val checked = JvmCheckedSyncIO()
            val prompts = AndroidPromptStore(root.toFile(), io = checked).also { it.prepareRoot() }
            prompts.create(original, "nested/deep/p.md")
            prompts.syncOperations.listFiles()
            checked.onFlush = { path ->
                if (path == (if (suffix.isEmpty()) root else root.resolve(suffix)) &&
                    Files.readAllBytes(root.resolve("nested/deep/p.md")).contentEquals(replacement)) throw IOException("private sentinel")
            }
            val error = failure(SyncFileFailureCode.DURABILITY_FAILED, SyncFileMutationEffect.APPLIED) {
                prompts.syncOperations.publish(replacement, "nested/deep/p.md", matching(prompts, "nested/deep/p.md"), SyncFileMode.READ_ONLY)
            }
            assertContentEquals(original, error.displacedBytes)
            assertContentEquals(replacement, prompts.read("nested/deep/p.md"))
            mode(root.resolve("nested/deep/p.md"), "r--r--r--")
            checked.onFlush = { }
            prompts.syncOperations.setMode(SyncFileMode.READ_ONLY, "nested/deep/p.md")
            prompts.syncOperations.flushDirectory("nested/deep")
            prompts.syncOperations.flushDirectory("nested")
            prompts.syncOperations.flushDirectory(null)
        }
    }

    @Test
    fun `new parent flush failure cannot be reported as an unchanged publication`() {
        sync.listFiles()
        io.onFlush = { path -> if (path == libraryDir.resolve("new") && Files.exists(libraryDir.resolve("new/deep/p.md"))) throw IOException("failed") }
        failure(SyncFileFailureCode.DURABILITY_FAILED, SyncFileMutationEffect.APPLIED) {
            sync.publish(original, "new/deep/p.md", SyncFileExpectation.Absent, SyncFileMode.NORMAL)
        }
        assertContentEquals(original, store.read("new/deep/p.md"))
    }

    @Test
    fun `a failure after native publication retains applied effect and losing bytes`() {
        val prompts = AndroidPromptStore(libraryDir.toFile(), object : AtomicPublication() {
            override fun replace(temporary: Path, destination: Path) {
                super.replace(temporary, destination)
                throw IOException("private native error")
            }
        }, io).also { it.prepareRoot() }
        prompts.create(original, "p.md")
        val error = failure(SyncFileFailureCode.IO_FAILURE, SyncFileMutationEffect.APPLIED) {
            prompts.syncOperations.publish(replacement, "p.md", matching(prompts, "p.md"), SyncFileMode.NORMAL)
        }
        assertContentEquals(original, error.displacedBytes)
        assertContentEquals(replacement, prompts.read("p.md"))
    }

    @Test
    fun `checked staging cleanup failure after exclusive publication is applied`() {
        val prompts = AndroidPromptStore(libraryDir.toFile(), object : AtomicPublication() {
            override fun removeTemporary(temporary: Path) { throw IOException("private cleanup error") }
        }, io).also { it.prepareRoot() }
        failure(SyncFileFailureCode.IO_FAILURE, SyncFileMutationEffect.APPLIED) {
            prompts.syncOperations.publish(original, "p.md", SyncFileExpectation.Absent, SyncFileMode.NORMAL)
        }
        assertContentEquals(original, prompts.read("p.md"))
        assertTrue(prompts.syncOperations.listFiles().any { it.relativePath.startsWith(".monkeyspaw-") })
    }

    @Test
    fun `mode and checked unlink propagate parent failures and never touch a changed baseline`() {
        store.create(original, "p.md")
        val expected = matching(store, "p.md")
        io.onFlush = { path -> if (path == libraryDir.resolve("p.md")) throw IOException("native mode error") }
        failure(SyncFileFailureCode.DURABILITY_FAILED, SyncFileMutationEffect.APPLIED) { sync.setMode(SyncFileMode.READ_ONLY, "p.md") }
        mode(libraryDir.resolve("p.md"), "r--r--r--")
        io.onFlush = { }
        failure(SyncFileFailureCode.CHANGED) { sync.trash("p.md", expected) }
        val current = matching(store, "p.md")
        io.before = { mutation, _ -> if (mutation == CheckedSyncIO.Mutation.TRASH) store.write(replacement, "p.md") }
        failure(SyncFileFailureCode.CHANGED) { sync.trash("p.md", current) }
        assertContentEquals(replacement, store.read("p.md"))
        io.before = { _, _ -> }
        io.onFlush = { path -> if (path == libraryDir && !Files.exists(libraryDir.resolve("p.md"))) throw IOException("parent flush") }
        val error = failure(SyncFileFailureCode.DURABILITY_FAILED, SyncFileMutationEffect.APPLIED) { sync.trash("p.md", matching(store, "p.md")) }
        assertContentEquals(replacement, error.displacedBytes)
        assertNull(store.stamp("p.md"))
        io.onFlush = { }
        sync.flushDirectory(null) // Replay flushes even though the deletion is already visible.
    }

    @Test
    fun `mode change refuses an incarnation replaced during admission`() {
        store.create(original, "p.md")
        io.before = { mutation, _ -> if (mutation == CheckedSyncIO.Mutation.MODE) store.write(replacement, "p.md") }
        failure(SyncFileFailureCode.CHANGED) { sync.setMode(SyncFileMode.READ_ONLY, "p.md") }
        assertContentEquals(replacement, store.read("p.md"))
        mode(libraryDir.resolve("p.md"), "rw-------")
    }

    @Test
    fun `directory identities survive child edits rename and graph reconstruction but not recreation`() {
        sync.createDirectory("Groups/Team")
        val identity = assertNotNull(sync.directoryIdentity("Groups/Team"))
        store.create(original, "Groups/Team/_unknown")
        store.write(replacement, "Groups/Team/_unknown")
        assertEquals(identity, sync.directoryIdentity("Groups/Team"))
        sync.renameDirectory("Groups/Team", "Groups/New")
        assertEquals(identity, sync.directoryIdentity("Groups/New"))
        val restarted = AndroidPromptStore(libraryDir.toFile(), io = JvmCheckedSyncIO()).syncOperations
        assertEquals(identity, restarted.directoryIdentity("Groups/New"))
        assertContentEquals(replacement, store.read("Groups/New/_unknown"))
        store.delete("Groups/New/_unknown")
        restarted.removeEmptyDirectory("Groups/New", identity)
        repeat(10) {
            restarted.createDirectory("Groups/New")
            val next = assertNotNull(restarted.directoryIdentity("Groups/New"))
            assertNotEquals(identity, next)
            failure(SyncFileFailureCode.CHANGED) { restarted.removeEmptyDirectory("Groups/New", identity) }
            restarted.removeEmptyDirectory("Groups/New", next)
        }
    }

    @Test
    fun `directory creation is exclusive for every occupant and flushes each new ancestor`() {
        sync.createDirectory("a/b/c")
        assertTrue(io.flushedDirectories.containsAll(listOf(libraryDir.resolve("a/b/c"), libraryDir.resolve("a/b"), libraryDir.resolve("a"), libraryDir)))
        failure(SyncFileFailureCode.OCCUPIED) { sync.createDirectory("a/b/c") }
        put(libraryDir.resolve("_unknown"), original)
        failure(SyncFileFailureCode.OCCUPIED) { sync.createDirectory("_unknown") }
        io.before = { mutation, path -> if (mutation == CheckedSyncIO.Mutation.CREATE_DIRECTORY) Files.createDirectory(libraryDir.resolve(path)) }
        failure(SyncFileFailureCode.OCCUPIED) { sync.createDirectory("raced") }
        assertNotNull(sync.directoryIdentity("raced"))
    }

    @Test
    fun `directory creation parent flush failure reports an applied incarnation`() {
        sync.listFiles()
        io.onFlush = { path -> if (path == libraryDir && Files.exists(libraryDir.resolve("new/deep"))) throw IOException("parent failed") }
        failure(SyncFileFailureCode.DURABILITY_FAILED, SyncFileMutationEffect.APPLIED) { sync.createDirectory("new/deep") }
        io.onFlush = { }
        assertNotNull(sync.directoryIdentity("new/deep"))
    }

    @Test
    fun `directory rename never merges empty hidden unowned or regular occupants`() {
        sync.createDirectory("Groups/Team")
        put(libraryDir.resolve("Groups/Team/.hidden/raw"), original)
        sync.createDirectory("Groups/Empty")
        sync.createDirectory("Groups/_unowned")
        put(libraryDir.resolve("Groups/file"), replacement)
        for (destination in listOf("Groups/Empty", "Groups/_unowned", "Groups/file", "Groups/Team")) {
            failure(SyncFileFailureCode.OCCUPIED) { sync.renameDirectory("Groups/Team", destination) }
            assertContentEquals(original, store.read("Groups/Team/.hidden/raw"))
        }
        failure(SyncFileFailureCode.NOT_FOUND) { sync.renameDirectory("Groups/Team", "Missing/New") }
        assertFalse(Files.exists(libraryDir.resolve("Missing")))
        failure(SyncFileFailureCode.INVALID_PATH) { sync.renameDirectory("Groups/Team", "Groups/Team/Child") }
    }

    @Test
    fun `directory rename rechecks source incarnation and final exclusive destination`() {
        sync.createDirectory("Source")
        val originalIdentity = sync.directoryIdentity("Source")
        io.before = { mutation, _ -> if (mutation == CheckedSyncIO.Mutation.RENAME_DIRECTORY) {
            Files.move(libraryDir.resolve("Source"), libraryDir.resolve("Old"))
            Files.createDirectory(libraryDir.resolve("Source"))
        } }
        failure(SyncFileFailureCode.CHANGED) { sync.renameDirectory("Source", "Destination") }
        assertEquals(originalIdentity, sync.directoryIdentity("Old"))
        io.before = { mutation, path -> if (mutation == CheckedSyncIO.Mutation.RENAME_DIRECTORY) Files.createDirectory(libraryDir.resolve(path)) }
        failure(SyncFileFailureCode.OCCUPIED) { sync.renameDirectory("Old", "Destination") }
        assertEquals(originalIdentity, sync.directoryIdentity("Old"))
    }

    @Test
    fun `native directory rename refuses an occupant appearing after the adapter check`() {
        val prompts = AndroidPromptStore(libraryDir.toFile(), object : AtomicPublication() {
            override fun renameDirectory(source: Path, destination: Path) {
                Files.createDirectory(destination)
                super.renameDirectory(source, destination)
            }
        }, io).also { it.prepareRoot() }
        prompts.syncOperations.createDirectory("Source")
        failure(SyncFileFailureCode.OCCUPIED) { prompts.syncOperations.renameDirectory("Source", "Destination") }
        assertNotNull(prompts.syncOperations.directoryIdentity("Source"))
        assertNotNull(prompts.syncOperations.directoryIdentity("Destination"))
    }

    @Test
    fun `two step case rename resumes after uncertain first publication without losing unknown files`() {
        sync.createDirectory("Groups/Team")
        store.create(original, "Groups/Team/.hidden/_raw")
        sync.createDirectory("Groups/Team/empty")
        sync.setMode(SyncFileMode.READ_ONLY, "Groups/Team/.hidden/_raw")
        val identity = assertNotNull(sync.directoryIdentity("Groups/Team"))
        io.onFlush = { path -> if (path == libraryDir.resolve("Groups") && Files.exists(libraryDir.resolve("Groups/_sync-fixed"))) throw IOException("uncertain rename") }
        failure(SyncFileFailureCode.DURABILITY_FAILED, SyncFileMutationEffect.APPLIED) {
            sync.renameDirectory("Groups/Team", "Groups/_sync-fixed")
        }
        val restarted = AndroidPromptStore(libraryDir.toFile(), io = JvmCheckedSyncIO()).syncOperations
        repeat(2) {
            assertNull(restarted.directoryIdentity("Groups/Team"))
            if (restarted.directoryIdentity("Groups/_sync-fixed") == identity) {
                restarted.flushDirectory("Groups")
                restarted.renameDirectory("Groups/_sync-fixed", "Groups/TEAM")
            }
            assertEquals(identity, restarted.directoryIdentity("Groups/TEAM"))
            restarted.flushDirectory("Groups")
            restarted.flushDirectory(null)
        }
        assertContentEquals(original, store.read("Groups/TEAM/.hidden/_raw"))
        assertNotNull(restarted.directoryIdentity("Groups/TEAM/empty"))
        mode(libraryDir.resolve("Groups/TEAM/.hidden/_raw"), "r--r--r--")
    }

    @Test
    fun `directory rename flushes both different parents and reports postnative applied errors`() {
        sync.createDirectory("a/Source")
        sync.createDirectory("b")
        val identity = sync.directoryIdentity("a/Source")
        io.onFlush = { path -> if (path == libraryDir.resolve("b") && Files.exists(libraryDir.resolve("b/Dest"))) throw IOException("dest parent") }
        failure(SyncFileFailureCode.DURABILITY_FAILED, SyncFileMutationEffect.APPLIED) { sync.renameDirectory("a/Source", "b/Dest") }
        io.onFlush = { }
        assertEquals(identity, sync.directoryIdentity("b/Dest"))
        assertTrue(io.flushedDirectories.contains(libraryDir.resolve("a")))
        val failing = AndroidPromptStore(libraryDir.toFile(), object : AtomicPublication() {
            override fun renameDirectory(source: Path, destination: Path) {
                super.renameDirectory(source, destination)
                throw IOException("rename returned after apply")
            }
        }, io).syncOperations
        failure(SyncFileFailureCode.IO_FAILURE, SyncFileMutationEffect.APPLIED) { failing.renameDirectory("b/Dest", "a/Final") }
        assertEquals(identity, sync.directoryIdentity("a/Final"))
    }

    @Test
    fun `empty removal never recursively deletes late hidden unowned files or subdirectories`() {
        sync.createDirectory("Group")
        val identity = assertNotNull(sync.directoryIdentity("Group"))
        put(libraryDir.resolve("Group/.hidden"), original)
        failure(SyncFileFailureCode.OCCUPIED) { sync.removeEmptyDirectory("Group", identity) }
        Files.delete(libraryDir.resolve("Group/.hidden"))
        sync.createDirectory("Group/_child")
        failure(SyncFileFailureCode.OCCUPIED) { sync.removeEmptyDirectory("Group", identity) }
        sync.removeEmptyDirectory("Group/_child", assertNotNull(sync.directoryIdentity("Group/_child")))
        io.before = { mutation, _ -> if (mutation == CheckedSyncIO.Mutation.REMOVE_DIRECTORY) put(libraryDir.resolve("Group/_late"), replacement) }
        failure(SyncFileFailureCode.OCCUPIED) { sync.removeEmptyDirectory("Group", identity) }
        assertContentEquals(replacement, store.read("Group/_late"))
    }

    @Test
    fun `empty removal rechecks incarnation and reports applied parent flush failure`() {
        sync.createDirectory("Group")
        val identity = assertNotNull(sync.directoryIdentity("Group"))
        io.before = { mutation, _ -> if (mutation == CheckedSyncIO.Mutation.REMOVE_DIRECTORY) {
            Files.move(libraryDir.resolve("Group"), libraryDir.resolve("Original"))
            Files.createDirectory(libraryDir.resolve("Group"))
        } }
        failure(SyncFileFailureCode.CHANGED) { sync.removeEmptyDirectory("Group", identity) }
        assertEquals(identity, sync.directoryIdentity("Original"))
        io.before = { _, _ -> }
        io.onFlush = { path -> if (path == libraryDir && !Files.exists(libraryDir.resolve("Original"))) throw IOException("parent failed") }
        failure(SyncFileFailureCode.DURABILITY_FAILED, SyncFileMutationEffect.APPLIED) { sync.removeEmptyDirectory("Original", identity) }
        io.onFlush = { }
        assertNull(sync.directoryIdentity("Original"))
        sync.flushDirectory(null)
    }

    @Test
    fun `checked errors are fixed diagnostics with no native cause or displaced byte exposure`() {
        store.create(original, "p.md")
        sync.listFiles()
        io.onFlush = { throw IOException("private sentinel path and body") }
        val error = failure(SyncFileFailureCode.DURABILITY_FAILED) { sync.flushFile("p.md") }
        assertNull(error.cause)
        assertFalse(error.toString().contains("sentinel"))
        assertFalse(error.message.orEmpty().contains("p.md"))
        assertEquals("<file stamp>", store.stamp("p.md").toString())
    }

    @Test
    fun `full inventory fails closed on an unrepresentable file instead of dropping it`() {
        store.prepareRoot()
        put(libraryDir.resolve("unrepresentable\nname"), original)
        failure(SyncFileFailureCode.INVALID_PATH) { sync.listFiles() }
        failure(SyncFileFailureCode.INVALID_PATH) { sync.directories(null) }
        assertContentEquals(original, Files.readAllBytes(libraryDir.resolve("unrepresentable\nname")))
    }

    @Test
    fun `corrupt or unsupported directory marker fails closed without diagnostic leakage`() {
        store.prepareRoot()
        val operations = AndroidPromptStore(libraryDir.toFile(), io = object : JvmCheckedSyncIO() {
            override fun directoryToken(path: Path) = DirectoryToken("private invalid marker", false)
        }).syncOperations
        failure(SyncFileFailureCode.INVALID_STATE) { operations.listFiles() }
        val unsupported = AndroidPromptStore(libraryDir.toFile(), io = object : JvmCheckedSyncIO() {
            override fun directoryToken(path: Path): DirectoryToken { throw UnsupportedOperationException("private filesystem details") }
        }).syncOperations
        failure(SyncFileFailureCode.IO_FAILURE) { unsupported.listFiles() }
        assertTrue(store.listFiles().isEmpty())
    }

    private fun matching(prompts: PromptStore, path: String): SyncFileExpectation.Matching =
        SyncFileExpectation.Matching(assertNotNull(prompts.stamp(path)), prompts.read(path))

    private fun failure(code: SyncFileFailureCode, effect: SyncFileMutationEffect = SyncFileMutationEffect.UNCHANGED,
                        work: () -> Any?): SyncFileOperationError {
        val error = assertFailsWith<SyncFileOperationError> { work() }
        assertEquals(code, error.code)
        assertEquals(effect, error.effect)
        assertNull(error.cause)
        return error
    }

    private fun mode(path: Path, expected: String) {
        assertEquals(PosixFilePermissions.fromString(expected), Files.getPosixFilePermissions(path, LinkOption.NOFOLLOW_LINKS))
    }

    private fun assertOnlyFiles(vararg expected: String) {
        assertEquals(expected.sorted(), sync.listFiles().map { it.relativePath }.sorted())
    }
}
