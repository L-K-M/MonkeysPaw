package ch.lkmc.monkeyspaw.data

import java.security.ProviderException
import javax.crypto.KeyGenerator
import kotlin.test.*

/** Policy tests use JVM keys and a synthetic unavailability signal, never the native Keystore. */
internal class StrongBoxPolicyTest {
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    @Test
    fun `API 26 and 27 and devices without StrongBox use ordinary AndroidKeyStore`() {
        for ((api, feature) in listOf(26 to true, 27 to true, 28 to false, 37 to false)) {
            val requests = mutableListOf<KeystoreBacking>()
            assertSame(key, StrongBoxPolicy.generate(api, feature) { requests += it; key })
            assertEquals(listOf(KeystoreBacking.KEYSTORE), requests)
        }
    }

    @Test
    fun `supported API 28 and newer prefer StrongBox without a fallback on success`() {
        for (api in listOf(28, 37)) {
            val requests = mutableListOf<KeystoreBacking>()
            assertSame(key, StrongBoxPolicy.generate(api, true) { requests += it; key })
            assertEquals(listOf(KeystoreBacking.STRONGBOX), requests)
        }
    }

    @Test
    fun `only StrongBox unavailability permits one ordinary Keystore fallback`() {
        val requests = mutableListOf<KeystoreBacking>()
        assertSame(key, StrongBoxPolicy.generate(28, true) {
            requests += it
            if (it == KeystoreBacking.STRONGBOX) throw StrongBoxUnavailable()
            key
        })
        assertEquals(listOf(KeystoreBacking.STRONGBOX, KeystoreBacking.KEYSTORE), requests)
    }

    @Test
    fun `other generation failures propagate without downgrade or retry`() {
        for (failure in listOf(ProviderException("failed"), IllegalStateException("failed"))) {
            val requests = mutableListOf<KeystoreBacking>()
            val actual = assertFailsWith<Exception> {
                StrongBoxPolicy.generate(28, true) { requests += it; throw failure }
            }
            assertSame(failure, actual)
            assertEquals(listOf(KeystoreBacking.STRONGBOX), requests)
        }
    }

    @Test
    fun `failed fallback propagates and never attempts a third generation`() {
        val requests = mutableListOf<KeystoreBacking>()
        assertFailsWith<ProviderException> {
            StrongBoxPolicy.generate(28, true) {
                requests += it
                if (it == KeystoreBacking.STRONGBOX) throw StrongBoxUnavailable()
                throw ProviderException("failed")
            }
        }
        assertEquals(listOf(KeystoreBacking.STRONGBOX, KeystoreBacking.KEYSTORE), requests)
    }
}
