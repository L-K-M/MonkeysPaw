package ch.lkmc.monkeyspaw.entry

import kotlin.test.*

internal class FillLauncherTest {
    @Test
    fun `repeated activations launch one form before the library resumes`() {
        var launches = 0
        var path: String? = null
        val launcher = FillLauncher { launches++; path = it }
        launcher.open("first.md")
        launcher.open("first.md")
        launcher.open("other.md")
        assertEquals(1, launches)
        assertTrue(path == "first.md")
    }

    @Test
    fun `returning to the library allows the next deliberate activation`() {
        var launches = 0
        val launcher = FillLauncher { launches++ }
        launcher.resumed()
        launcher.open("first.md")
        launcher.open("first.md")
        launcher.resumed()
        launcher.open("second.md")
        launcher.open("second.md")
        assertEquals(2, launches)
    }

    @Test
    fun `reentrant activation cannot start another form`() {
        var launches = 0
        lateinit var launcher: FillLauncher
        launcher = FillLauncher {
            launches++
            if (launches == 1) launcher.open("reentrant.md")
        }
        launcher.open("first.md")
        assertEquals(1, launches)
    }

    @Test
    fun `failed navigation retains its failure and allows retry`() {
        var launches = 0
        val failure = IllegalStateException()
        val launcher = FillLauncher {
            launches++
            if (launches == 1) throw failure
        }
        assertSame(failure, assertFailsWith<IllegalStateException> { launcher.open("first.md") })
        launcher.open("first.md")
        launcher.open("first.md")
        assertEquals(2, launches)
    }
}
