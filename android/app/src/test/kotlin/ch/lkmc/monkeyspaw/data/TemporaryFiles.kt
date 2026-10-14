package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.Clock
import ch.lkmc.monkeyspaw.core.ports.Entropy
import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.services.LibraryService
import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant
import kotlin.test.AfterTest

internal open class TemporaryFiles {
    protected val temporary: Path = Files.createTempDirectory("monkeyspaw-k12-")
    protected val filesDir: Path = temporary.resolve("files")
    protected val libraryDir: Path = filesDir.resolve("library")

    protected fun library(state: StateStore = AndroidStateStore(filesDir.toFile()),
        prompts: AndroidPromptStore = AndroidPromptStore(libraryDir.toFile())): LibraryService {
        var draw = 0
        return LibraryService(prompts, state, Clock { Instant.parse("2026-10-14T00:00:00Z") },
            Entropy { count -> ByteArray(count) { (draw++).toByte() } })
    }

    protected fun put(path: Path, bytes: ByteArray = "body".encodeToByteArray()) {
        Files.createDirectories(path.parent)
        Files.write(path, bytes)
    }

    @AfterTest
    fun removeTemporaryFiles() {
        // Files.walk does not follow fixture symlinks.
        Files.walk(temporary).use { paths -> paths.sorted(Comparator.reverseOrder()).forEach(Files::delete) }
    }
}
