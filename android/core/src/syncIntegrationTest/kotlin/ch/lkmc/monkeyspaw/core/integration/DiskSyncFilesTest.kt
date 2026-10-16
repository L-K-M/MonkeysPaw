package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.ports.*
import kotlinx.coroutines.runBlocking
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import kotlin.test.*

class DiskSyncFilesTest {
    @Test fun checkedPublicationKeepsRawBytesModesAndStaleSource(): Unit = withPrivateTestRoot { root ->
        val files = DiskSyncFiles(root.resolve("library"), library = true)
        val bytes = byteArrayOf(-1, 0, 13, 10)
        files.operations.publish(bytes, "nested/a.md", SyncFileExpectation.Absent, SyncFileMode.READ_ONLY)
        assertContentEquals(bytes, files.read("nested/a.md"))
        assertEquals(PosixFilePermissions.fromString("r--r--r--"), files.mode("nested/a.md"))
        val expected = SyncFileExpectation.Matching(files.stamp("nested/a.md")!!, bytes)
        files.externalWrite("newer".encodeToByteArray(), "nested/a.md")
        assertEquals(SyncFileFailureCode.CHANGED, assertFailsWith<SyncFileOperationError> {
            files.operations.publish(bytes, "nested/a.md", expected, SyncFileMode.NORMAL)
        }.code)
        assertContentEquals("newer".encodeToByteArray(), files.read("nested/a.md"))
        assertEquals(SyncFileFailureCode.CHANGED, assertFailsWith<SyncFileOperationError> { files.operations.trash("nested/a.md", expected) }.code)
        val current = SyncFileExpectation.Matching(files.stamp("nested/a.md")!!, files.read("nested/a.md"))
        val publication = files.operations.publish(bytes, "nested/a.md", current, SyncFileMode.NORMAL)
        assertContentEquals("newer".encodeToByteArray(), publication.displacedBytes)
        assertEquals(PosixFilePermissions.fromString("rw-------"), files.mode("nested/a.md"))
    }

    @Test fun fullInventoryAndDirectoriesRefuseContainmentViolations(): Unit = withPrivateTestRoot { root ->
        val files = DiskSyncFiles(root.resolve("library"), library = true)
        for (path in listOf("p.md", "README.md", ".hidden/raw", "_scratch/a", "notes.txt")) files.externalWrite(byteArrayOf(1), path)
        assertEquals(5, files.operations.listFiles().size)
        assertEquals(listOf("p.md"), files.listFiles().map { it.relativePath })
        for (path in listOf("../outside", "/absolute", "a/../b", "a//b", "a\\b")) {
            assertFailsWith<SyncFileOperationError> { files.operations.publish(byteArrayOf(1), path, SyncFileExpectation.Absent, SyncFileMode.NORMAL) }
        }
        val outside = root.resolve("outside")
        privateDirectory(outside)
        Files.createSymbolicLink(files.root.resolve("link"), outside)
        assertFailsWith<SyncFileOperationError> { files.operations.publish(byteArrayOf(1), "link/p.md", SyncFileExpectation.Absent, SyncFileMode.NORMAL) }
        assertFailsWith<SyncFileOperationError> { files.operations.listFiles() }
        assertFailsWith<SyncFileOperationError> { files.operations.directories(null) }
        assertFalse(Files.exists(outside.resolve("p.md")))
    }

    @Test fun directoryIncarnationsSurviveRenameAndRejectRemovalOfReplacements(): Unit = withPrivateTestRoot { root ->
        val files = DiskSyncFiles(root.resolve("library"))
        files.operations.createDirectory("a")
        val first = files.operations.directoryIdentity("a")!!
        files.operations.renameDirectory("a", "b")
        assertEquals(first, files.operations.directoryIdentity("b"))
        files.operations.removeEmptyDirectory("b", first)
        files.operations.createDirectory("b")
        assertNotEquals(first, files.operations.directoryIdentity("b"))
        assertEquals(SyncFileFailureCode.CHANGED, assertFailsWith<SyncFileOperationError> { files.operations.removeEmptyDirectory("b", first) }.code)
        files.operations.createDirectory("occupied")
        assertEquals(SyncFileFailureCode.OCCUPIED, assertFailsWith<SyncFileOperationError> { files.operations.renameDirectory("b", "occupied") }.code)
        files.externalWrite(byteArrayOf(1), "b/p.md")
        assertEquals(SyncFileFailureCode.OCCUPIED, assertFailsWith<SyncFileOperationError> { files.operations.removeEmptyDirectory("b", files.operations.directoryIdentity("b")!!) }.code)
    }

    @Test fun reconstructedPortsKeepSecretsPrivateAndIsolateNamespaces(): Unit = withPrivateTestRoot { root -> runBlocking {
        val secretRoot = root.resolve("secrets")
        val secrets = FixtureSecretStore(DiskSyncFiles(secretRoot))
        val one = SecretAccount("a-b", "c")
        val two = SecretAccount("a", "b-c")
        secrets.write(SecretValue("fixture-one"), one)
        secrets.write(SecretValue("fixture-two"), two)
        val reopened = FixtureSecretStore(DiskSyncFiles(secretRoot))
        assertTrue(reopened.read(one, SecretReadSource.EFFECTIVE)?.value == SecretValue("fixture-one"))
        assertTrue(reopened.read(two, SecretReadSource.PERSISTED)?.value == SecretValue("fixture-two"))
        Files.list(secretRoot).use { stream -> stream.forEach(::privateRegularFile) }
        assertEquals(PosixFilePermissions.fromString("rwx------"), Files.getPosixFilePermissions(secretRoot))
        reopened.delete(one); reopened.delete(one)
        assertNull(reopened.read(one, SecretReadSource.PERSISTED))
        assertNotNull(reopened.read(two, SecretReadSource.PERSISTED))
    } }

    @Test fun aMissingOrReplacedRuntimeRootCannotBecomeAnEmptyLibrary(): Unit = withPrivateTestRoot { root ->
        val files = DiskSyncFiles(root.resolve("library"))
        Files.move(files.root, root.resolve("retired"))
        assertFailsWith<SyncFileOperationError> { files.operations.listFiles() }
        assertFalse(Files.exists(files.root))
        privateDirectory(files.root)
        assertFailsWith<SyncFileOperationError> { files.operations.listFiles() }
    }
}
