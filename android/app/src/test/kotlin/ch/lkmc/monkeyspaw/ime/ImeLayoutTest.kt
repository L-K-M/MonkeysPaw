package ch.lkmc.monkeyspaw.ime

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

internal class ImeLayoutTest {
    @Test
    fun `picker height adapts without covering the target app`() {
        for ((width, height) in listOf(360 to 780, 780 to 360, 1280 to 800, 800 to 1280, 640 to 240)) {
            val normal = imePickerHeight(width, height, 1f)
            val large = imePickerHeight(width, height, 2f)
            assertTrue(normal in 1..(height * 0.7f).toInt())
            assertTrue(large >= normal)
            assertTrue(large <= (height * 0.7f).toInt())
            assertTrue(large <= if (width > height) 260 else 400)
        }
        assertEquals(400, imePickerHeight(800, 1280, 1f))
        assertEquals(168, imePickerHeight(640, 240, 2f))
    }
}
