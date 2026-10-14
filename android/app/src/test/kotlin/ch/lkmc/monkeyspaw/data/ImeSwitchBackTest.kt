package ch.lkmc.monkeyspaw.data

import kotlin.test.*

internal class ImeSwitchBackTest {
    @Test fun `API 26 and 27 use the IME window token for the legacy call`() {
        for (api in listOf(26, 27)) {
            val gateway = Gateway(api)
            assertEquals(ImeSwitchBack.Result.PREVIOUS, ImeSwitchBack(gateway).switch { true })
            assertEquals(listOf("token", "last"), gateway.calls)
            assertTrue(gateway.usedToken === gateway.token)
        }
    }

    @Test fun `missing legacy token never calls last and falls back to picker`() {
        for (api in listOf(26, 27)) {
            val gateway = Gateway(api).apply { token = null }
            assertEquals(ImeSwitchBack.Result.PICKER, ImeSwitchBack(gateway).switch { true })
            assertEquals(listOf("token", "picker"), gateway.calls)
        }
    }

    @Test fun `API 28 and newer use service previous without reading a token`() {
        for (api in listOf(28, 34, 37)) {
            val gateway = Gateway(api).apply { token = null }
            assertEquals(ImeSwitchBack.Result.PREVIOUS, ImeSwitchBack(gateway).switch { true })
            assertEquals(listOf("previous"), gateway.calls)
        }
    }

    @Test fun `false or throwing previous call falls back once on every API`() {
        for (api in listOf(26, 27, 28, 37)) for (throws in listOf(false, true)) {
            val gateway = Gateway(api).apply { switchResult = false; switchThrows = throws }
            assertEquals(ImeSwitchBack.Result.PICKER, ImeSwitchBack(gateway).switch { true })
            assertEquals(if (api < 28) listOf("token", "last", "picker") else listOf("previous", "picker"), gateway.calls)
        }
    }

    @Test fun `token exception also falls back and an unavailable or throwing picker is explicit`() {
        val failedToken = Gateway(26).apply { tokenThrows = true }
        assertEquals(ImeSwitchBack.Result.PICKER, ImeSwitchBack(failedToken).switch { true })
        assertEquals(listOf("token", "picker"), failedToken.calls)
        for (api in listOf(26, 28)) for (throws in listOf(false, true)) {
            val gateway = Gateway(api).apply { switchResult = false; pickerResult = false; pickerThrows = throws }
            assertEquals(ImeSwitchBack.Result.UNAVAILABLE, ImeSwitchBack(gateway).switch { true })
            assertEquals(1, gateway.calls.count { it == "picker" })
        }
    }

    @Test fun `retired request never invokes any platform method`() {
        for (api in listOf(26, 28)) {
            val gateway = Gateway(api)
            assertEquals(ImeSwitchBack.Result.STALE, ImeSwitchBack(gateway).switch { false })
            assertTrue(gateway.calls.isEmpty())
        }
    }

    @Test fun `new input during token lookup cancels before the legacy effect`() {
        var active = true
        val gateway = Gateway(27).apply { onToken = { active = false } }
        assertEquals(ImeSwitchBack.Result.STALE, ImeSwitchBack(gateway).switch { active })
        assertEquals(listOf("token"), gateway.calls)
    }

    @Test fun `false or exception from a retired switch never opens a picker in the new input session`() {
        for (api in listOf(26, 28)) for (throws in listOf(false, true)) {
            var active = true
            val gateway = Gateway(api).apply {
                switchResult = false; switchThrows = throws; onSwitch = { active = false }
            }
            assertEquals(ImeSwitchBack.Result.STALE, ImeSwitchBack(gateway).switch { active })
            assertFalse(gateway.calls.contains("picker"))
        }
    }

    @Test fun `a successful departure needs no fallback after service teardown`() {
        var active = true
        val gateway = Gateway(28).apply { onSwitch = { active = false } }
        assertEquals(ImeSwitchBack.Result.PREVIOUS, ImeSwitchBack(gateway).switch { active })
        assertEquals(listOf("previous"), gateway.calls)
    }

    private class Gateway(override val api: Int) : ImeSwitchGateway {
        val calls = mutableListOf<String>()
        var token: Any? = Any()
        var usedToken: Any? = null
        var switchResult = true
        var switchThrows = false
        var tokenThrows = false
        var pickerResult = true
        var pickerThrows = false
        var onSwitch: () -> Unit = {}
        var onToken: () -> Unit = {}
        override fun previous(): Boolean { calls += "previous"; return switch() }
        override fun windowToken(): Any? {
            calls += "token"
            onToken()
            if (tokenThrows) throw IllegalStateException("Unavailable")
            return token
        }
        override fun last(token: Any): Boolean { calls += "last"; usedToken = token; return switch() }
        private fun switch(): Boolean {
            onSwitch()
            if (switchThrows) throw IllegalStateException("Unavailable")
            return switchResult
        }
        override fun picker(): Boolean {
            calls += "picker"
            if (pickerThrows) throw IllegalStateException("Unavailable")
            return pickerResult
        }
    }
}
