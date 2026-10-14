package ch.lkmc.monkeyspaw.data

import android.text.InputType.*
import android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
import android.view.inputmethod.InputConnection
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.ime.ImeEditor
import java.lang.reflect.Proxy
import kotlin.test.*

internal class ImeTextDeliveryTest {
    @Test fun `accepted commit is exactly one literal write with cursor one and no clipboard or other connection calls`() {
        val text = "literal {{value}}\n\r\u000b\u000c\u0085\u2028\u2029"
        val gateway = Gateway(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE)
        val copy = Copy()
        val endpoint = ImeTextDelivery(gateway, { true }, copy)
        assertEquals(TextDeliveryResult.ACCEPTED, endpoint.deliver(DeliveryMode.IME_COMMIT, text))
        assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.IME_COMMIT, text))
        assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.COPY, text))
        assertEquals(listOf("commitText"), gateway.calls)
        assertTrue(gateway.text == text)
        assertEquals(1, gateway.cursor)
        assertEquals(0, copy.writes)
    }

    @Test fun `single-line terminal and text accept one commit while every multiline separator offers explicit Copy`() {
        for (type in listOf(TYPE_NULL, 0x00080090, TYPE_CLASS_TEXT, TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_IME_MULTI_LINE)) {
            val single = Gateway(type)
            assertEquals(TextDeliveryResult.ACCEPTED,
                ImeTextDelivery(single, { true }, Copy()).deliver(DeliveryMode.IME_COMMIT, "ready"))
            assertEquals(listOf("commitText"), single.calls)
            for (separator in listOf("\n", "\r", "\r\n", "\u000b", "\u000c", "\u0085", "\u2028", "\u2029")) {
                val gateway = Gateway(type)
                val copy = Copy()
                val endpoint = ImeTextDelivery(gateway, { true }, copy)
                val text = "first${separator}second"
                assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.IME_COMMIT, text))
                assertTrue(gateway.calls.isEmpty())
                assertEquals(0, copy.writes)
                assertEquals(TextDeliveryResult.ACCEPTED, endpoint.deliver(DeliveryMode.COPY, text))
                assertTrue(copy.text == text)
            }
        }
    }

    @Test fun `missing metadata null connection and other classes never guess an insertion target`() {
        for (type in listOf(null, TYPE_CLASS_NUMBER, TYPE_CLASS_PHONE, TYPE_CLASS_DATETIME, 15)) {
            val gateway = Gateway(type)
            val copy = Copy()
            val endpoint = ImeTextDelivery(gateway, { true }, copy)
            assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.IME_COMMIT, "ready"))
            assertEquals(TextDeliveryResult.ACCEPTED, endpoint.deliver(DeliveryMode.COPY, "ready"))
            assertTrue(gateway.calls.isEmpty())
            assertEquals(1, copy.writes)
        }
        val gateway = Gateway(TYPE_CLASS_TEXT).apply { connection = null }
        val copy = Copy()
        val endpoint = ImeTextDelivery(gateway, { true }, copy)
        assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.IME_COMMIT, "ready"))
        assertEquals(TextDeliveryResult.ACCEPTED, endpoint.deliver(DeliveryMode.COPY, "ready"))
        assertTrue(gateway.calls.isEmpty())
        assertEquals(1, copy.writes)
    }

    @Test fun `false null and exception commit outcomes allow explicit Copy without any commit replay`() {
        for (outcome in listOf<Boolean?>(false, null, true)) {
            val gateway = Gateway(TYPE_CLASS_TEXT).apply {
                result = outcome
                throws = outcome == true
            }
            val copy = Copy()
            val endpoint = ImeTextDelivery(gateway, { true }, copy)
            assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.IME_COMMIT, "ready"))
            assertEquals(0, copy.writes)
            assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.IME_COMMIT, "ready"))
            assertEquals(1, gateway.attempts)
            assertEquals(TextDeliveryResult.ACCEPTED, endpoint.deliver(DeliveryMode.COPY, "ready"))
            assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.COPY, "ready"))
            assertEquals(1, copy.writes)
            assertEquals(1, gateway.attempts)
        }
    }

    @Test fun `latest password metadata blocks Insert and Copy before effects`() {
        for (type in listOf(TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_PASSWORD,
            TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            TYPE_CLASS_TEXT or TYPE_TEXT_VARIATION_WEB_PASSWORD,
            TYPE_CLASS_NUMBER or TYPE_NUMBER_VARIATION_PASSWORD)) {
            val gateway = Gateway(TYPE_CLASS_TEXT)
            val copy = Copy()
            val endpoint = ImeTextDelivery(gateway, { true }, copy)
            gateway.inputType = type
            assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.IME_COMMIT, "ready"))
            assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.COPY, "ready"))
            assertTrue(gateway.calls.isEmpty())
            assertEquals(0, copy.writes)
        }
    }

    @Test fun `our foreground Fill editor cannot receive commits or Copy through the old IME endpoint`() {
        val gateway = Gateway(TYPE_CLASS_TEXT).apply { inFillActivity = true }
        val copy = Copy()
        val endpoint = ImeTextDelivery(gateway, { true }, copy)
        assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.IME_COMMIT, "ready"))
        assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.COPY, "ready"))
        assertTrue(gateway.calls.isEmpty())
        assertEquals(0, copy.writes)
    }

    @Test fun `latest multiline flags are checked and learning flag alone never changes permission`() {
        val gateway = Gateway(TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_MULTI_LINE)
        val endpoint = ImeTextDelivery(gateway, { true }, Copy())
        gateway.inputType = TYPE_CLASS_TEXT or TYPE_TEXT_FLAG_IME_MULTI_LINE
        gateway.options = IME_FLAG_NO_PERSONALIZED_LEARNING
        assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.IME_COMMIT, "a\nb"))
        assertTrue(gateway.calls.isEmpty())
        assertEquals(TextDeliveryResult.ACCEPTED, endpoint.deliver(DeliveryMode.IME_COMMIT, "ready"))
    }

    @Test fun `retired generation and changes between metadata snapshot and effect return stale`() {
        for (check in listOf(1, 2)) {
            val gateway = Gateway(TYPE_CLASS_TEXT)
            val copy = Copy()
            var checks = 0
            val endpoint = ImeTextDelivery(gateway, { ++checks < check }, copy)
            assertEquals(TextDeliveryResult.STALE, endpoint.deliver(DeliveryMode.IME_COMMIT, "ready"))
            assertTrue(gateway.calls.isEmpty())
            assertEquals(0, copy.writes)
        }
        val gateway = Gateway(TYPE_CLASS_TEXT)
        val opened = gateway.editor()
        val copy = Copy()
        val endpoint = ImeTextDelivery(gateway, { opened.matches(gateway.editor()) }, copy)
        gateway.connection = connection { _, _ -> true }
        assertEquals(TextDeliveryResult.STALE, endpoint.deliver(DeliveryMode.COPY, "ready"))
        assertTrue(gateway.calls.isEmpty())
        assertEquals(0, copy.writes)
    }

    @Test fun `accepted commit stays accepted through teardown but a failed retired call is stale`() {
        for (accepted in listOf(true, false)) {
            var active = true
            val gateway = Gateway(TYPE_CLASS_TEXT).apply { result = accepted; onCommit = { active = false } }
            val copy = Copy()
            val endpoint = ImeTextDelivery(gateway, { active }, copy)
            assertEquals(if (accepted) TextDeliveryResult.ACCEPTED else TextDeliveryResult.STALE,
                endpoint.deliver(DeliveryMode.IME_COMMIT, "ready"))
            assertEquals(TextDeliveryResult.STALE, endpoint.deliver(DeliveryMode.COPY, "ready"))
            assertEquals(listOf("commitText"), gateway.calls)
            assertEquals(0, copy.writes)
        }
    }

    @Test fun `reentrant Insert and Copy during commit are refused and unsupported mode has no effects`() {
        val gateway = Gateway(TYPE_CLASS_TEXT)
        val copy = Copy()
        val endpoint = ImeTextDelivery(gateway, { true }, copy)
        assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.SELECTION_RESULT, "ready"))
        gateway.onCommit = {
            assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.IME_COMMIT, "ready"))
            assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.COPY, "ready"))
        }
        assertEquals(TextDeliveryResult.ACCEPTED, endpoint.deliver(DeliveryMode.IME_COMMIT, "ready"))
        assertEquals(listOf("commitText"), gateway.calls)
        assertEquals(0, copy.writes)
    }

    @Test fun `failed Copy retains a manual retry and never enables another commit`() {
        val gateway = Gateway(TYPE_CLASS_TEXT).apply { result = false }
        val copy = Copy().apply { refuses = true }
        val endpoint = ImeTextDelivery(gateway, { true }, copy)
        assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.IME_COMMIT, "ready"))
        assertEquals(TextDeliveryResult.REFUSED, endpoint.deliver(DeliveryMode.COPY, "ready"))
        copy.refuses = false
        assertEquals(TextDeliveryResult.ACCEPTED, endpoint.deliver(DeliveryMode.COPY, "ready"))
        assertEquals(1, gateway.attempts)
        assertEquals(1, copy.writes)
    }

    private class Copy : TextDelivery {
        var writes = 0
        var text: String? = null
        var refuses = false
        override fun deliver(mode: DeliveryMode, text: String): TextDeliveryResult {
            assertEquals(DeliveryMode.COPY, mode)
            if (refuses) throw IllegalStateException("Unavailable")
            writes++
            this.text = text
            return TextDeliveryResult.ACCEPTED
        }
    }

    private class Gateway(var inputType: Int?) : ImeDeliveryGateway {
        var options = 0
        var inFillActivity = false
        var result: Boolean? = true
        var throws = false
        var onCommit: () -> Unit = {}
        val calls = mutableListOf<String>()
        var attempts = 0
        var text: String? = null
        var cursor = 0
        var connection: InputConnection? = connection { method, arguments ->
            calls += method
            assertEquals("commitText", method)
            assertEquals(2, arguments.size)
            text = arguments[0] as String
            cursor = arguments[1] as Int
            onCommit()
            if (throws) throw IllegalStateException("Unavailable")
            result
        }
        override fun editor() = ImeEditor(inputType, options, connection, inFillActivity)
        override fun commitText(editor: ImeEditor, text: String, newCursorPosition: Int): Boolean? {
            attempts++
            assertTrue(editor.matches(editor()))
            if (result == null) return null
            return connection?.commitText(text, newCursorPosition)
        }
    }

    companion object {
        private fun connection(call: (String, Array<out Any>) -> Any?): InputConnection =
            Proxy.newProxyInstance(InputConnection::class.java.classLoader, arrayOf(InputConnection::class.java)) {
                _, method, arguments -> call(method.name, arguments ?: emptyArray())
            } as InputConnection
    }
}
