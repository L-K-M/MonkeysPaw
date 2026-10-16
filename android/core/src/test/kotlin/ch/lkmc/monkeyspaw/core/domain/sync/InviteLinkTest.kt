package ch.lkmc.monkeyspaw.core.domain.sync

import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.sync.SyncServerURL
import kotlin.test.*

class InviteLinkTest {
    private val token = "A".repeat(43)
    private val server = "https://example.test/paw"
    private val original get() = link(server)

    @Test fun bareTokenRequiresExplicitServerWithoutTrimming() {
        assertSame(InviteLinkError.ServerRequired, assertFailsWith<InviteLinkError> { InviteLink(token) })
        assertSame(InviteLinkError.ServerRequired, assertFailsWith<InviteLinkError> { InviteLink(token, "") })
        assertEquals(server, InviteLink(token, "HTTPS://EXAMPLE.test:443/paw/api/v1/").server.baseURL)
        assertTrue(InviteLink(token, server).token == SecretValue(token), "Token changed")
        for (input in listOf("", " $token", "$token ", "$token\n")) invalid(input, server)
        for (destination in listOf(" ", "example.test", "http://public.test", "https://user:password@example.test")) {
            invalid(token, destination)
        }
    }

    @Test fun fullLinkUsesEmbeddedDestinationAndNormalizesOnlyThatServer() {
        val parsed = InviteLink(link("HTTPS://EXAMPLE.test:443/paw/api/v1/"), "https://other.test")
        assertEquals(server, parsed.server.baseURL)
        assertEquals(server, InviteLink(original.replace("monkeyspaw://join", "MONKEYSPAW://JOIN")).server.baseURL)
        assertEquals(server, InviteLink("monkeyspaw://join?token=$token&server=${percent(server)}").server.baseURL)
    }

    @Test fun nestedEscapesAndLiteralPlusDecodeExactlyOnce() {
        for (destination in listOf("https://example.test/paw%20space/a+b", "https://example.test/Caf%C3%A9", "http://[fd00::1]:8080/paw")) {
            assertTrue(InviteLink(link(destination)).server == SyncServerURL(destination), "Destination changed")
        }
        assertEquals("https://example.test/a+b", InviteLink(link("https://example.test/a+b")).server.baseURL)
        assertTrue(InviteLink("monkeyspaw://join?token=${"%41".repeat(43)}&server=${percent(server)}").token == SecretValue(token), "Token changed")
        invalid("monkeyspaw://join?server=${percent(percent(server))}&token=$token")
        invalid("monkeyspaw://join?server=${percent(server)}&token=%2541${token.drop(1)}")
    }

    @Test fun queryNamesAreLiteralUniqueCompleteAndClosed() {
        for (suffix in listOf("&server=${percent(server)}", "&token=$token", "&unknown=x", "&", "&&",
            "&%74oken=$token", "&TOKEN=$token")) invalid(original + suffix)
        for (query in listOf("", "server=", "token=$token", "server=${percent(server)}&token=", "server&token=$token",
            "server=${percent(server)}&token", "server=${percent(server)}&Token=$token", "server=${percent(server)}&%74oken=$token",
            "Server=${percent(server)}&token=$token", "server=${percent(server)};token=$token", "server==&token=$token")) {
            invalid("monkeyspaw://join?$query")
        }
    }

    @Test fun authorityHasNoAlternateSchemeUserinfoPortPathOrFragment() {
        val query = original.substringAfter('?')
        for (prefix in listOf("https://join", "monkeyspaw:join", "monkeyspaw:/join", "monkeyspaw:///join", "monkeyspaw://other",
            "monkeyspaw://join.evil.test", "monkeyspaw://user@join", "monkeyspaw://@join", "monkeyspaw://join:80", "monkeyspaw://join:",
            "monkeyspaw://%6Aoin", "monkeyspaw://jo\u0131n", "monkeyspaw://jo\u0130n", "monkeyspaw://join/", "monkeyspaw://join/path", "monkeyspaw://join\\", "monkeyspaw://join.")) {
            invalid("$prefix?$query")
        }
        for (suffix in listOf("#", "#fragment", "\n", "\r", "\t", "\u0000", "\u0085", "\u200b", "\u00a0")) invalid(original + suffix)
        invalid(" $original")
    }

    @Test fun malformedEscapesAndNonUTF8AreRejectedWithoutRepair() {
        for (value in listOf("%", "%0", "%Q0", "%0Q", "%FF", "%C0%AF", "%ED%A0%80", "%F4%90%80%80", "\uD800")) {
            invalid("monkeyspaw://join?server=$value&token=$token")
            invalid("monkeyspaw://join?server=${percent(server)}&token=$value")
        }
    }

    @Test fun decodedValuesKeepServerNormalizationWithoutForwardingControls() {
        for (control in listOf("%0A", "%09", "%00")) {
            invalid("monkeyspaw://join?server=${percent(server)}/a${control}b&token=$token")
            invalid("monkeyspaw://join?server=${percent(server)}&token=${token.dropLast(1)}$control")
        }
        invalid("monkeyspaw://join?server=${percent(server)}%00&token=$token")
        // P5 uses SyncServerURL's Swift-compatible surrounding-whitespace normalization.
        for (suffix in listOf("%0A", "%09", "%20")) {
            assertEquals(server, InviteLink("monkeyspaw://join?server=${percent(server)}$suffix&token=$token").server.baseURL)
        }
        assertEquals(server, InviteLink("monkeyspaw://join?server=$server&token=$token").server.baseURL)
    }

    @Test fun tokenGrammarRequiresCanonicalUnpadded32Bytes() {
        for (value in listOf(token.drop(1), token + "A", token + "=", token + "+", token.dropLast(1) + "B",
            token.dropLast(1) + "/", token.dropLast(1) + "%", token.dropLast(1) + "é", token.dropLast(1) + "\u0000")) {
            invalid(value, server)
            invalid(link(server, value))
        }
        for (tail in "AEIMQUYcgkosw048") {
            val valid = "_-".repeat(21) + tail
            assertTrue(InviteLink(valid, server).token == SecretValue(valid), "Canonical token changed")
        }
    }

    @Test fun nestedServerAppliesFullDeploymentSecurityMatrix() {
        for (destination in listOf("https://user:password@example.test", "https://@example.test", "https://example.test?", "https://example.test?x=1&y=2",
            "https://example.test#x", "https://%65xample.test", "https://example.test:0", "https://[::1]evil", "https://example.test/../paw",
            "https://example.test/a//b", "https://example.test/a%2Fb", "https://example.test/a%5Cb", "https://example.test/%252e%252e",
            "https://example.test/%FF", "http://public.test", "http://server.local", "http://10.evil.test", "http://169.254.1.2",
            "http://100.64.0.1", "http://127.1", "http://0177.0.0.1", "http://2130706433", "http://[fe80::1]", "http://[::ffff:127.0.0.1]")) {
            invalid(link(destination))
            invalid(token, destination)
        }
        for (host in listOf("localhost", "127.255.255.255", "10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.2", "[::1]", "[fc00::1]")) {
            assertTrue(InviteLink(link("http://$host:8080/paw")).server.usesPlaintextHTTP)
        }
    }

    @Test fun bindingDistinguishesSchemeHostPortAndDeploymentPrefix() {
        val bound = InviteLink(original)
        for (destination in listOf("https://other.test/paw", "https://example.test:8443/paw", "https://example.test/paw2", "https://example.test/paw/child")) {
            assertTrue(bound.server != InviteLink(link(destination)).server, "Different destination aliased")
        }
        assertTrue(InviteLink(link("http://localhost/paw")).server != InviteLink(link("https://localhost/paw")).server)
        assertTrue(bound == InviteLink(link("https://EXAMPLE.test:443/paw/api/v1")), "Equivalent destination changed")
        assertEquals(bound.hashCode(), InviteLink(original).hashCode())
    }

    @Test fun diagnosticsNeverContainBearerInputOrParserCause() {
        val parsed = InviteLink(original)
        assertEquals("<invite link redacted>", parsed.toString())
        val failure = assertFailsWith<InviteLinkError> { InviteLink(original + "#invalid") }
        assertNull(failure.cause)
        for (diagnostic in listOf(parsed.toString(), failure.toString(), failure.message.orEmpty(), failure.stackTraceToString())) {
            assertFalse(diagnostic.contains(token) || diagnostic.contains(original), "Secret in diagnostics")
        }
    }

    private fun link(destination: String, value: String = token) = "monkeyspaw://join?server=${percent(destination)}&token=${percent(value)}"
    private fun percent(value: String) = value.encodeToByteArray().joinToString("") { byte ->
        val number = byte.toInt() and 255
        if (number.toChar() in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~") number.toChar().toString()
        else "%" + number.toString(16).uppercase().padStart(2, '0')
    }
    private fun invalid(input: String, destination: String? = null) {
        assertSame(InviteLinkError.InvalidLink, assertFailsWith<InviteLinkError>("Invalid invite accepted") { InviteLink(input, destination) })
    }
}
