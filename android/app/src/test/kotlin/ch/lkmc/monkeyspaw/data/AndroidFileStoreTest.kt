package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.ports.StoreError
import java.io.File
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import kotlin.test.*

internal class AndroidFileStoreTest : TemporaryFiles() {
    @Test
    fun `missing roots read as empty without creating them`() {
        val store = AndroidPromptStore(libraryDir.toFile())
        assertTrue(store.listFiles().isEmpty())
        assertNull(store.stamp("p.md"))
        assertFailsWith<StoreError.NotFound> { store.read("p.md") }
        assertFalse(Files.exists(filesDir))
        store.create("new".encodeToByteArray(), "folder/p.md")
        assertEquals("new", Files.readString(libraryDir.resolve("folder/p.md")))
    }

    @Test
    fun `library rules are exact and state enumeration keeps sidecars`() {
        val paths = listOf("README.md", "readme.md", "nested/README.md", "_scratch/p.md", "a/_p.md",
            ".git/p.md", "a/.hidden/p.md", ".visible.md", "p.MD", "notes.txt", "Groups/p.md", "Conflicts/p.md",
            "\uE000.md", "\uD800\uDC00.md")
        paths.forEach { put(libraryDir.resolve(it)) }
        val store = AndroidPromptStore(libraryDir.toFile())
        // §5.1 reserves exact-case root README.md; nested README.md remains a prompt.
        assertEquals(listOf(".visible.md", "Conflicts/p.md", "Groups/p.md", "nested/README.md", "readme.md",
            "\uE000.md", "\uD800\uDC00.md"), store.listFiles().map { it.relativePath })
        val state = AndroidStateStore(stateDir.toFile())
        state.create(byteArrayOf(1), "history/key/_unknown")
        state.create(byteArrayOf(2), "history/key/.unknown")
        assertTrue(state.listFiles().map { it.relativePath }.containsAll(listOf("history/key/_unknown", "history/key/.unknown")))
    }

    @Test
    fun `state and library scans never include files from sibling storage trees`() {
        val prompts = AndroidPromptStore(libraryDir.toFile())
        val state = AndroidStateStore(stateDir.toFile())
        prompts.create(byteArrayOf(1), "p.md")
        state.create(byteArrayOf(2), "history/key/revision.md")
        state.create(byteArrayOf(3), "history/key/.sidecar")
        state.create(byteArrayOf(4), "usage/key")
        state.writePrivate(byteArrayOf(5), "values.json")
        put(filesDir.resolve("datastore/settings.json"))
        put(filesDir.resolve("datastore/foreign.md"))
        assertEquals(listOf("p.md"), prompts.listFiles().map { it.relativePath })
        assertEquals(listOf("history/key/.sidecar", "history/key/revision.md", "usage/key", "values.json"),
            state.listFiles().map { it.relativePath })
        assertContentEquals(byteArrayOf(5), state.read("values.json"))
    }

    @Test
    fun `crash orphaned staging files never become state entries or hide valid names`() {
        val state = AndroidStateStore(stateDir.toFile())
        for (path in listOf(".monkeyspaw-orphan.tmp", "history/key/.monkeyspaw-orphan.tmp",
            "history/key/.sidecar", ".monkeyspaw-prompt.md", ".monkeyspaw-folder.tmp/sidecar")) {
            put(stateDir.resolve(path))
        }
        val outside = temporary.resolve("outside")
        put(outside)
        Files.createSymbolicLink(stateDir.resolve(".monkeyspaw-link.tmp"), outside)
        assertEquals(listOf(".monkeyspaw-folder.tmp/sidecar", ".monkeyspaw-prompt.md", "history/key/.sidecar"),
            state.listFiles().map { it.relativePath })
        assertEquals("body", Files.readString(outside))

        put(libraryDir.resolve(".monkeyspaw-prompt.md"))
        put(libraryDir.resolve(".monkeyspaw-orphan.tmp"))
        assertEquals(listOf(".monkeyspaw-prompt.md"),
            AndroidPromptStore(libraryDir.toFile()).listFiles().map { it.relativePath })
    }

    @Test
    fun `a state staging cleanup failure cannot expose an orphan or fail the commit`() {
        val state = AndroidStateStore(stateDir.toFile(), object : AtomicPublication() {
            override fun removeTemporary(temporary: Path) { throw IOException("cleanup failed") }
        })
        state.create("committed".encodeToByteArray(), "history/key/revision")
        assertEquals("committed", state.read("history/key/revision").decodeToString())
        assertEquals(listOf("history/key/revision"), state.listFiles().map { it.relativePath })
    }

    @Test
    fun `delete syncs only its parent directory after removing a prompt or state file`() {
        for (scan in RootedFileStore.Scan.entries) {
            val root = temporary.resolve(scan.name)
            val leaf = root.resolve("nested/p.md")
            put(leaf)
            val synced = mutableListOf<Path>()
            val publication = object : AtomicPublication() {
                override fun syncDirectory(directory: Path) {
                    assertFalse(Files.exists(leaf), "Directory sync must follow unlink")
                    synced.add(directory)
                    super.syncDirectory(directory)
                }
            }
            val store = RootedFileStore(root.toFile(), scan, publication)
            store.delete("nested/p.md")
            assertEquals(listOf(leaf.parent), synced)
            assertNull(store.stamp("nested/p.md"))
        }
    }

    @Test
    fun `unsupported directory sync cannot misreport a completed delete`() {
        put(stateDir.resolve("history/key/revision"))
        val state = AndroidStateStore(stateDir.toFile(), object : AtomicPublication() {
            override fun syncDirectory(directory: Path) { throw IOException("unsupported directory fsync") }
        })
        state.delete("history/key/revision")
        assertNull(state.stamp("history/key/revision"))
    }

    @Test
    fun `bytes are owned and invalid UTF8 is never decoded by drivers`() {
        val store = AndroidPromptStore(libraryDir.toFile())
        val bytes = byteArrayOf(0, -1, -64, -81, 13, 10)
        store.create(bytes, "invalid.md")
        assertContentEquals(bytes, store.read("invalid.md"))
        val read = store.read("invalid.md")
        read[0] = 10
        assertContentEquals(bytes, store.read("invalid.md"))
        assertEquals(listOf("invalid.md"), store.listFiles().map { it.relativePath })
    }

    @Test
    fun `raw invalid paths cannot create parents or escape`() {
        val store = AndroidPromptStore(libraryDir.toFile())
        for (path in listOf("", "/outside.md", "../outside.md", "a/../p.md", "a//p.md", "a/./p.md",
            "a\\p.md", "a/\u0000.md", "a/\u202E.md", "\uD800.md", "a".repeat(Limits.maxRootedPathBytes + 1))) {
            assertFailsWith<StoreError.InvalidPath> { store.create(byteArrayOf(1), path) }
            assertFailsWith<StoreError.InvalidPath> { store.read(path) }
        }
        assertFalse(Files.exists(filesDir))
    }

    @Test
    fun `full group wrapper fits the rooted cap and preserves exact bytes`() {
        val store = AndroidPromptStore(libraryDir.toFile())
        val wire = listOf("a".repeat(255), "b".repeat(255), "c".repeat(255), "x", "d".repeat(251) + ".md").joinToString("/")
        val path = "Groups/" + "f".repeat(255) + "/" + wire
        assertEquals(Limits.maxPathBytes, wire.encodeToByteArray().size)
        assertEquals(Limits.maxRootedPathBytes, path.encodeToByteArray().size)
        val bytes = byteArrayOf(0, -1, 13, 10)
        store.create(bytes, path)
        assertContentEquals(bytes, store.read(path))
        assertEquals(listOf(path), store.listFiles().map { it.relativePath })
        assertFailsWith<StoreError.InvalidPath> { store.create(bytes, path + "x") }
        assertContentEquals(bytes, store.read(path))
    }

    @Test
    fun `both move paths validate before any directories are created`() {
        val store = AndroidPromptStore(libraryDir.toFile())
        assertFailsWith<StoreError.InvalidPath> { store.move("p.md", "../outside.md") }
        assertFalse(Files.exists(filesDir))
    }

    @Test
    fun `relative and filesystem roots are invalid`() {
        assertFailsWith<StoreError.InvalidRoot> { AndroidPromptStore(File("relative")).listFiles() }
        assertFailsWith<StoreError.InvalidRoot> { AndroidStateStore(File("/")).listFiles() }
    }

    @Test
    fun `a symlink root is refused but trusted ancestor aliases resolve once`() {
        Files.createDirectories(libraryDir)
        val alias = temporary.resolve("alias")
        Files.createSymbolicLink(alias, filesDir)
        assertTrue(AndroidPromptStore(alias.resolve("library").toFile()).listFiles().isEmpty())
        val rootLink = temporary.resolve("root-link")
        Files.createSymbolicLink(rootLink, libraryDir)
        assertFailsWith<StoreError.OutsideRoot> { AndroidPromptStore(rootLink.toFile()).listFiles() }
    }

    @Test
    fun `replacing a canonical ancestor with a symlink cannot redirect the store`() {
        val store = AndroidPromptStore(libraryDir.toFile())
        store.create(byteArrayOf(1), "p.md")
        Files.move(filesDir, temporary.resolve("old-files"))
        val outside = temporary.resolve("outside")
        put(outside.resolve("library/p.md"), byteArrayOf(2))
        Files.createSymbolicLink(filesDir, outside)
        assertFailsWith<StoreError.OutsideRoot> { store.read("p.md") }
        assertFailsWith<StoreError.OutsideRoot> { store.write(byteArrayOf(3), "p.md") }
        assertContentEquals(byteArrayOf(2), Files.readAllBytes(outside.resolve("library/p.md")))
    }

    @Test
    fun `symlink parents are refused by every path operation and skipped in scans`() {
        Files.createDirectories(libraryDir)
        val outside = temporary.resolve("outside")
        put(outside.resolve("p.md"))
        Files.createSymbolicLink(libraryDir.resolve("link"), outside)
        val store = AndroidPromptStore(libraryDir.toFile())
        assertTrue(store.listFiles().isEmpty())
        assertFailsWith<StoreError.OutsideRoot> { store.read("link/p.md") }
        assertFailsWith<StoreError.OutsideRoot> { store.stamp("link/p.md") }
        assertFailsWith<StoreError.OutsideRoot> { store.write(byteArrayOf(1), "link/p.md") }
        assertFailsWith<StoreError.OutsideRoot> { store.create(byteArrayOf(1), "link/new.md") }
        assertFailsWith<StoreError.OutsideRoot> { store.delete("link/p.md") }
        assertFailsWith<StoreError.OutsideRoot> { store.move("link/p.md", "new.md") }
        store.create(byteArrayOf(1), "real.md")
        assertFailsWith<StoreError.OutsideRoot> { store.move("real.md", "link/new.md") }
        assertEquals("body", Files.readString(outside.resolve("p.md")))
    }

    @Test
    fun `leaf links are refused except that occupied creates report collision`() {
        Files.createDirectories(libraryDir)
        val outside = temporary.resolve("outside.md")
        put(outside)
        Files.createSymbolicLink(libraryDir.resolve("link.md"), outside)
        Files.createSymbolicLink(libraryDir.resolve("dangling.md"), temporary.resolve("absent"))
        val store = AndroidPromptStore(libraryDir.toFile())
        for (path in listOf("link.md", "dangling.md")) {
            assertFailsWith<StoreError.OutsideRoot> { store.read(path) }
            assertFailsWith<StoreError.OutsideRoot> { store.stamp(path) }
            assertFailsWith<StoreError.OutsideRoot> { store.write(byteArrayOf(1), path) }
            assertFailsWith<StoreError.OutsideRoot> { store.delete(path) }
            assertFailsWith<StoreError.AlreadyExists> { store.create(byteArrayOf(1), path) }
        }
        assertTrue(store.listFiles().isEmpty())
        assertEquals("body", Files.readString(outside))
    }

    @Test
    fun `directories are not regular leaves and not valid parent files`() {
        Files.createDirectories(libraryDir.resolve("directory.md"))
        val store = AndroidPromptStore(libraryDir.toFile())
        assertFailsWith<StoreError.NotRegularFile> { store.read("directory.md") }
        assertFailsWith<StoreError.NotRegularFile> { store.write(byteArrayOf(1), "directory.md") }
        assertFailsWith<StoreError.NotRegularFile> { store.stamp("directory.md") }
        assertFailsWith<StoreError.NotRegularFile> { store.delete("directory.md") }
        assertFailsWith<StoreError.AlreadyExists> { store.create(byteArrayOf(1), "directory.md") }
        put(libraryDir.resolve("parent"))
        assertFailsWith<StoreError.InvalidRoot> { store.write(byteArrayOf(1), "parent/p.md") }
    }

    @Test
    fun `occupied create never starts staging and never overwrites`() {
        put(libraryDir.resolve("p.md"), byteArrayOf(-1))
        val publication = object : AtomicPublication() {
            override fun flush(channel: FileChannel) = error("Occupied create must not stage bytes")
        }
        val store = AndroidPromptStore(libraryDir.toFile(), publication)
        assertFailsWith<StoreError.AlreadyExists> { store.create(byteArrayOf(1), "p.md") }
        assertContentEquals(byteArrayOf(-1), Files.readAllBytes(libraryDir.resolve("p.md")))
    }

    @Test
    fun `racing create publication is exclusive and removes its temporary file`() {
        val publication = object : AtomicPublication() {
            override fun create(temporary: Path, destination: Path) {
                Files.write(destination, "winner".encodeToByteArray())
                super.create(temporary, destination)
            }
        }
        val store = AndroidPromptStore(libraryDir.toFile(), publication)
        assertFailsWith<StoreError.AlreadyExists> { store.create("loser".encodeToByteArray(), "p.md") }
        assertEquals("winner", Files.readString(libraryDir.resolve("p.md")))
        assertOnlyLeaf(libraryDir, "p.md")
    }

    @Test
    fun `an occupied publication is refused even when it names the staged inode`() {
        val publication = object : AtomicPublication() {
            override fun create(temporary: Path, destination: Path) {
                Files.createLink(destination, temporary)
                super.create(temporary, destination)
            }
        }
        val store = AndroidPromptStore(libraryDir.toFile(), publication)
        assertFailsWith<StoreError.AlreadyExists> { store.create("kept".encodeToByteArray(), "p.md") }
        assertEquals("kept", store.read("p.md").decodeToString())
        assertOnlyLeaf(libraryDir, "p.md")
    }

    @Test
    fun `move creates parents and collisions leave both files intact`() {
        val store = AndroidPromptStore(libraryDir.toFile())
        store.create("source".encodeToByteArray(), "p.md")
        store.create("destination".encodeToByteArray(), "other.md")
        assertFailsWith<StoreError.AlreadyExists> { store.move("p.md", "other.md") }
        assertEquals("source", store.read("p.md").decodeToString())
        assertEquals("destination", store.read("other.md").decodeToString())
        store.move("p.md", "nested/moved.md")
        assertNull(store.stamp("p.md"))
        assertEquals("source", store.read("nested/moved.md").decodeToString())
    }

    @Test
    fun `move publication race preserves the source and occupied destination`() {
        put(libraryDir.resolve("p.md"))
        val publication = object : AtomicPublication() {
            override fun move(source: Path, destination: Path) {
                Files.write(destination, byteArrayOf(3))
                super.move(source, destination)
            }
        }
        val store = AndroidPromptStore(libraryDir.toFile(), publication)
        assertFailsWith<StoreError.AlreadyExists> { store.move("p.md", "new.md") }
        assertEquals("body", store.read("p.md").decodeToString())
        assertContentEquals(byteArrayOf(3), store.read("new.md"))
    }

    @Test
    fun `failed exclusive move preserves the source and missing destination`() {
        put(libraryDir.resolve("p.md"))
        val store = AndroidPromptStore(libraryDir.toFile(), object : AtomicPublication() {
            override fun move(source: Path, destination: Path) {
                throw IOException("move failed")
            }
        })
        assertFailsWith<StoreError.IOFailure> { store.move("p.md", "new.md") }
        assertEquals("body", store.read("p.md").decodeToString())
        assertNull(store.stamp("new.md"))
    }

    @Test
    fun `failed flush preserves old bytes and leaves no new or temporary file`() {
        put(libraryDir.resolve("p.md"))
        val publication = object : AtomicPublication() {
            override fun flush(channel: FileChannel) { throw IOException("SECRET filesystem details") }
        }
        val store = AndroidPromptStore(libraryDir.toFile(), publication)
        val error = assertFailsWith<StoreError.IOFailure> { store.write(byteArrayOf(1), "p.md") }
        assertNull(error.cause)
        assertFalse(error.toString().contains("SECRET"))
        assertFailsWith<StoreError.IOFailure> { store.create(byteArrayOf(1), "new.md") }
        assertEquals("body", Files.readString(libraryDir.resolve("p.md")))
        assertOnlyLeaf(libraryDir, "p.md")
    }

    @Test
    fun `failed atomic publication preserves the old destination and its stamp`() {
        put(libraryDir.resolve("p.md"))
        val publication = object : AtomicPublication() {
            override fun replace(temporary: Path, destination: Path) { throw IOException("rename failed") }
        }
        val store = AndroidPromptStore(libraryDir.toFile(), publication)
        val stamp = store.stamp("p.md")
        assertFailsWith<StoreError.IOFailure> { store.write(byteArrayOf(1), "p.md") }
        assertEquals(stamp, store.stamp("p.md"))
        assertEquals("body", store.read("p.md").decodeToString())
        assertOnlyLeaf(libraryDir, "p.md")
    }

    @Test
    fun `temporary cleanup failure cannot misreport a committed publication`() {
        val store = AndroidPromptStore(libraryDir.toFile(), object : AtomicPublication() {
            override fun removeTemporary(temporary: Path) { throw IOException("cleanup failed") }
        })
        store.create("committed".encodeToByteArray(), "p.md")
        assertEquals("committed", store.read("p.md").decodeToString())
        assertEquals(listOf("p.md"), store.listFiles().map { it.relativePath })
        store.write("replaced".encodeToByteArray(), "p.md")
        assertEquals("replaced", store.read("p.md").decodeToString())
    }

    @Test
    fun `private replacements have mode 0600 before publication`() {
        val publication = object : AtomicPublication() {
            override fun replace(temporary: Path, destination: Path) {
                assertEquals(PosixFilePermissions.fromString("rw-------"), Files.getPosixFilePermissions(temporary))
                assertEquals(destination.parent, temporary.parent)
                super.replace(temporary, destination)
            }
        }
        val state = AndroidStateStore(stateDir.toFile(), publication)
        state.writePrivate("private".encodeToByteArray(), "values.json")
        assertEquals(PosixFilePermissions.fromString("rw-------"), Files.getPosixFilePermissions(stateDir.resolve("values.json")))
        assertEquals("private", state.read("values.json").decodeToString())
        assertOnlyLeaf(stateDir, "values.json")
    }

    @Test
    fun `deletion recreation changes incarnation even with identical size and mtime`() {
        val store = AndroidPromptStore(libraryDir.toFile())
        store.create(byteArrayOf(1), "p.md")
        val path = libraryDir.resolve("p.md")
        val modified = Files.getLastModifiedTime(path)
        val original = store.stamp("p.md")
        assertEquals(original, AndroidPromptStore(libraryDir.toFile()).stamp("p.md"))
        // The stamp includes nanosecond ctime as well as inode, so inode reuse does not skip coverage.
        repeat(20) {
            store.delete("p.md")
            store.create(byteArrayOf(1), "p.md")
            Files.setLastModifiedTime(path, modified)
            assertNotEquals(original, store.stamp("p.md"))
        }
    }

    private fun assertOnlyLeaf(directory: Path, expected: String) {
        Files.list(directory).use { assertEquals(listOf(expected), it.map { path -> path.fileName.toString() }.toList()) }
    }
}
