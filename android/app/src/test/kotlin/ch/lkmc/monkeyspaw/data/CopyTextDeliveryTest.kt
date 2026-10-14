package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.*
import kotlin.test.*

internal class CopyTextDeliveryTest {
    @Test fun `Copy accepts raw text once without reads and refuses insertion modes without writes`() {
        val writes = mutableListOf<String>()
        val endpoint = CopyTextDelivery(object : Clipboard {
            override fun readText(completion: (String?) -> Unit) = fail("Delivery must not read the clipboard")
            override fun writeText(text: String) { writes.add(text) }
        })
        for (mode in listOf(DeliveryMode.IME_COMMIT, DeliveryMode.SELECTION_RESULT)) {
            assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(mode, "unpublished"))
        }
        assertTrue(writes.isEmpty())
        assertEquals(TextDeliveryResult.ACCEPTED, endpoint.deliver(DeliveryMode.COPY, "{{literal}}\n"))
        assertTrue(writes == listOf("{{literal}}\n"))
    }

    @Test fun `failed clipboard write never reports acceptance`() {
        val endpoint = CopyTextDelivery(object : Clipboard {
            override fun readText(completion: (String?) -> Unit) = fail("Unused read")
            override fun writeText(text: String) { throw StoreError.IOFailure }
        })
        assertFailsWith<StoreError.IOFailure> { endpoint.deliver(DeliveryMode.COPY, "unpublished") }
    }
}
