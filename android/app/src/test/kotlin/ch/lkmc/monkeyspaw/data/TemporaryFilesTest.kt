package ch.lkmc.monkeyspaw.data

import java.nio.file.Files
import kotlin.test.*

internal class TemporaryFilesTest : TemporaryFiles() {
    @Test
    fun `cleanup is idempotent when a test has already removed its temporary root`() {
        removeTemporaryFiles()
        assertFalse(Files.exists(temporary))
        removeTemporaryFiles()
    }
}
