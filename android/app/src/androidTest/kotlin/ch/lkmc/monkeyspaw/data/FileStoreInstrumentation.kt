package ch.lkmc.monkeyspaw.data

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.ports.SyncFileExpectation
import ch.lkmc.monkeyspaw.core.ports.SyncFileMode
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions

/** Runs inside the Android sandbox, whose link policy is absent from host JVM tests. */
class FileStoreInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val cases = listOf("exclusiveCreate" to ::exclusiveCreate, "exclusiveMove" to ::exclusiveMove,
            "checkedPublication" to ::checkedPublication)
        var failures = 0
        for ((index, case) in cases.withIndex()) {
            val status = Bundle().apply {
                putString("class", this@FileStoreInstrumentation.javaClass.name)
                putString("test", case.first)
                putInt("numtests", cases.size)
                putInt("current", index + 1)
            }
            sendStatus(statusStarted, status)
            try {
                case.second()
                sendStatus(statusPassed, status)
            } catch (error: Throwable) {
                failures++
                // Native exception messages can contain paths or file data.
                status.putString("stack", error.javaClass.name)
                sendStatus(statusFailed, status)
            }
        }
        finish(if (failures == 0) Activity.RESULT_OK else Activity.RESULT_CANCELED, Bundle().apply {
            putInt("tests", cases.size)
            putInt("failures", failures)
        })
    }

    private fun exclusiveCreate() = withStore { store, root ->
        val original = "Native café 👩🏽\r\n".encodeToByteArray()
        store.create(original, "created.md")
        check(store.read("created.md").contentEquals(original))
        check(store.stamp("created.md") != null)
        check(Files.getPosixFilePermissions(root.resolve("created.md")) == PosixFilePermissions.fromString("rw-------"))
        occupied { store.create(byteArrayOf(0), "created.md") }
        check(store.read("created.md").contentEquals(original))
        Files.newDirectoryStream(root).use { check(it.toList().size == 1) }
    }

    private fun exclusiveMove() = withStore { store, _ ->
        val original = byteArrayOf(1, 2, 3)
        val other = byteArrayOf(4, 5)
        store.create(original, "source.md")
        store.create(other, "occupied.md")
        occupied { store.move("source.md", "occupied.md") }
        check(store.read("source.md").contentEquals(original))
        check(store.read("occupied.md").contentEquals(other))
        store.move("source.md", "nested/moved.md")
        check(store.stamp("source.md") == null)
        check(store.read("nested/moved.md").contentEquals(original))
    }

    private fun checkedPublication() = withStore { store, root ->
        val operations = store.syncOperations
        val original = byteArrayOf(1, 2, 3)
        val replacement = byteArrayOf(4, 5)
        operations.listFiles()
        operations.publish(original, "group/p.md", SyncFileExpectation.Absent, SyncFileMode.READ_ONLY)
        check(store.read("group/p.md").contentEquals(original))
        check(Files.getPosixFilePermissions(root.resolve("group/p.md")) == PosixFilePermissions.fromString("r--r--r--"))
        operations.publish(replacement, "group/p.md",
            SyncFileExpectation.Matching(checkNotNull(store.stamp("group/p.md")), original), SyncFileMode.NORMAL)
        check(store.read("group/p.md").contentEquals(replacement))
        operations.renameDirectory("group", "renamed")
        check(store.stamp("group/p.md") == null)
        check(store.read("renamed/p.md").contentEquals(replacement))
    }

    private fun occupied(action: () -> Unit) {
        try {
            action()
            error("Occupied destination was accepted")
        } catch (_: StoreError.AlreadyExists) { }
    }

    private fun withStore(action: (AndroidPromptStore, Path) -> Unit) {
        val root = Files.createTempDirectory(targetContext.cacheDir.toPath(), "native-store-")
        try {
            val store = AndroidPromptStore(root.toFile())
            store.prepareRoot()
            action(store, root)
        } finally {
            check(root.toFile().deleteRecursively())
        }
    }

    private companion object {
        // Instrumentation test-runner status protocol.
        private const val statusStarted = 1
        private const val statusPassed = 0
        private const val statusFailed = -2
    }
}
