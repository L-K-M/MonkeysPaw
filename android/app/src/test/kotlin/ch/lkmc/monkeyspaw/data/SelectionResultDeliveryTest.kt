package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.*
import kotlin.test.*

internal class SelectionResultDeliveryTest {
    @Test fun `editable Insert returns once with no clipboard effect including reentrant taps`() {
        var results = 0
        var copies = 0
        lateinit var endpoint: SelectionResultDelivery
        endpoint = SelectionResultDelivery(DeliveryMode.SELECTION_RESULT,
            TextDelivery { _, _ -> copies++; TextDeliveryResult.ACCEPTED }, { true }) { text ->
            assertTrue(text == "rendered")
            results++
            assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.SELECTION_RESULT, "duplicate"))
        }
        assertEquals(TextDeliveryResult.ACCEPTED, endpoint.deliver(DeliveryMode.SELECTION_RESULT, "rendered"))
        assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.COPY, "duplicate"))
        assertEquals(1, results)
        assertEquals(0, copies)
    }

    @Test fun `read-only refuses replacement and IME mode but permits one explicit Copy`() {
        var copies = 0
        val endpoint = SelectionResultDelivery(DeliveryMode.COPY,
            TextDelivery { mode, _ -> assertEquals(DeliveryMode.COPY, mode); copies++; TextDeliveryResult.ACCEPTED },
            { true }) { error("Read-only must not return text") }
        assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.SELECTION_RESULT, "rendered"))
        assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.IME_COMMIT, "rendered"))
        assertEquals(0, copies)
        assertEquals(TextDeliveryResult.ACCEPTED, endpoint.deliver(DeliveryMode.COPY, "rendered"))
        assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.COPY, "duplicate"))
        assertEquals(1, copies)
    }

    @Test fun `stale and failed returns have no automatic Copy fallback`() {
        var active = false
        var attempts = 0
        var copies = 0
        val endpoint = SelectionResultDelivery(DeliveryMode.SELECTION_RESULT,
            TextDelivery { _, _ -> copies++; TextDeliveryResult.ACCEPTED }, { active }) {
            attempts++
            error("Untrusted platform diagnostic")
        }
        assertEquals(TextDeliveryResult.STALE, endpoint.deliver(DeliveryMode.SELECTION_RESULT, "rendered"))
        assertEquals(TextDeliveryResult.STALE, endpoint.deliver(DeliveryMode.COPY, "rendered"))
        assertEquals(0, attempts)
        active = true
        assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.SELECTION_RESULT, "rendered"))
        assertEquals(1, attempts)
        assertEquals(0, copies)
        assertEquals(TextDeliveryResult.ACCEPTED, endpoint.deliver(DeliveryMode.COPY, "rendered"))
        assertEquals(1, copies)
    }
}
