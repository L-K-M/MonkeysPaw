package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.sync.SyncAccountIdentity
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import ch.lkmc.monkeyspaw.core.ports.HttpUrlPolicy
import ch.lkmc.monkeyspaw.core.ports.SyncTLSTrust
import java.util.UUID
import kotlin.test.*

class SyncServerURLTest {
    @Test fun normalizationMatchesSwiftAndProducesPersistableDeploymentBases() {
        val cases = mapOf(
            " HTTPS://EXAMPLE.COM.:443/ " to "https://example.com",
            "http://LOCALHOST:80/paw/" to "http://localhost/paw",
            "https://example.com:8443/paw/api/v1/" to "https://example.com:8443/paw",
            "https://example.com/api/v1/api/v1" to "https://example.com",
            "https://example.com/paw/api/v1/api/v1/" to "https://example.com/paw",
            "https://example.com/a%20b/" to "https://example.com/a%20b",
            "https://example.com/café/" to "https://example.com/caf%C3%A9",
            "https://BÜCHER.example/" to "https://xn--bcher-kva.example",
            "https://xn--bcher-kva.example/" to "https://xn--bcher-kva.example",
            "http://[FC00:0000:0:0:0:0:0:1]:80/" to "http://[fc00::1]",
            "http://[0:0:0:0:0:0:0:1]/" to "http://[::1]",
            "https://example.com/API/V1" to "https://example.com/API/V1",
            "https://example.com/%7e" to "https://example.com/~",
            "https://example.com/%7E" to "https://example.com/~",
            "https://my_host:8443/paw" to "https://my_host:8443/paw",
            "https://-abc.example" to "https://-abc.example",
            "https://faß.example" to "https://xn--fa-hia.example",
        )
        for ((input, expected) in cases) {
            val server = SyncServerURL(input)
            assertEquals(expected, server.baseURL, input)
            assertEquals("$expected/api/v1", server.apiURL, input)
            assertEquals(server, SyncServerURL(expected), input)
            assertEquals(server, SyncServerURL(server.apiURL), input)
            SyncAccountIdentity(expected, userID)
        }
    }

    @Test fun httpExemptionsAreOnlyCanonicalLiteralLoopbackRFC1918AndULA() {
        for (host in listOf("localhost", "LOCALHOST.", "127.0.0.1", "127.255.255.255", "[::1]",
            "10.0.0.0", "10.255.255.255", "172.16.0.0", "172.31.255.255", "192.168.0.0", "192.168.255.255",
            "[fc00::]", "[fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]")) {
            val server = SyncServerURL("http://$host:8080/paw")
            assertTrue(server.usesPlaintextHTTP, host)
            assertEquals(server.apiURL + "/me", server.validatedRequestURL(server.apiURL + "/me"), host)
        }
    }

    @Test fun publicPrivateDNSAndLookalikeLiteralsRequireHTTPS() {
        for (host in listOf("example.com", "server.local", "lan", "localhost.evil.test", "localhost.localdomain",
            "9.255.255.255", "11.0.0.0", "172.15.255.255", "172.32.0.0", "192.167.255.255", "192.169.0.0",
            "100.64.0.0", "100.127.255.255", "169.254.0.1", "0.0.0.0", "[fbff:ffff::1]", "[fe00::1]",
            "[fe80::1]", "[::2]", "[::ffff:127.0.0.1]", "[::ffff:192.168.1.1]", "[::ffff:a00:1]",
            "127.1", "10.1", "2130706433", "167772161", "0177.0.0.1", "012.0.0.1", "127.0.0.01",
            "10.00.0.1", "0x7f000001", "0x0a000001", "0x0a.0.0.1", "bücher.example", "xn--bcher-kva.example",
            "１２７.０.０.１", "ｌｏｃａｌｈｏｓｔ", "１０.０.０.１", "localhoſt")) {
            assertEquals(SyncServerURLError.InsecureURL, assertFailsWith<SyncServerURLError>(host) { SyncServerURL("http://$host") })
            assertFalse(SyncServerURL("https://$host").usesPlaintextHTTP, host)
        }
    }

    @Test fun malformedAuthoritiesAndEscapedHostsAreRejected() {
        for (input in listOf("", "example.com", "//example.com", "ftp://localhost", "https://example.com:0",
            "https://example.com:65536", "https://example.com:abc", "https://example.com:9999999999999",
            "https://example.com..", "https://localhost..", "http://10.0.0.1..", "https://[not:ipv6]",
            "https://[fc00:::1]", "https://[::1]evil", "https://[::1]:80:80", "http://[fe80::1%25eth0]",
            "http://%31%32%37.0.0.1", "https://ex%C3%A9mple.com", "https://ex%61mple.com",
            "https://%78n--bcher-kva.example", "https://exam ple.com", "https://example.com\\evil",
            "https://example.com/a\nb", "https://example.com/a\u200db", "https://example.com/\ud800")) {
            assertEquals(SyncServerURLError.InvalidURL, assertFailsWith<SyncServerURLError>(input) { SyncServerURL(input) })
        }
    }

    @Test fun credentialsQueriesAndFragmentsNeverBecomeDeploymentBases() {
        for (input in listOf("https://user:synthetic@example.com", "https://@example.com")) {
            assertEquals(SyncServerURLError.CredentialsInURL, assertFailsWith<SyncServerURLError> { SyncServerURL(input) })
        }
        for (input in listOf("https://example.com?", "https://example.com?token=synthetic", "https://example.com#")) {
            assertEquals(SyncServerURLError.QueryOrFragmentInURL, assertFailsWith<SyncServerURLError> { SyncServerURL(input) })
        }
    }

    @Test fun unsafeDecodedDeploymentPrefixesAreRejectedBeforeNormalization() {
        for (path in listOf("/a//b", "/../paw", "/%2E/paw", "/a%2fb", "/a%2Fb", "/a%5cb", "/%00",
            "/%252e%252e", "/a%3fb", "/a%23b", "/%7F", "/%C2%85", "/%E2%80%8D", "/%FF", "/%", "/%xy", "/%２ｅ")) {
            assertEquals(SyncServerURLError.InvalidDeploymentPrefix,
                assertFailsWith<SyncServerURLError>(path) { SyncServerURL("https://example.com$path") })
        }
    }

    @Test fun ipv6CanonicalizationUsesTheFirstLongestZeroRunWithoutMappedHTTPExemptions() {
        for ((input, output) in mapOf(
            "0:0:1:0:0:1:1:1" to "::1:0:0:1:1:1", "fc00:0:0:1:0:0:0:1" to "fc00:0:0:1::1",
            "::ffff:127.0.0.1" to "::ffff:7f00:1", "fc00:0:0:0:0:0:192.168.1.1" to "fc00::c0a8:101")) {
            assertEquals("https://[$output]", SyncServerURL("https://[$input]").baseURL)
        }
    }

    @Test fun eachRequestIsBoundToSchemeHostEffectivePortAndExactEncodedAPITree() {
        val server = SyncServerURL("https://example.com:8443/paw")
        assertEquals("https://example.com:8443/paw/api/v1/prompts/ID?base_rev=1",
            server.validatedRequestURL("https://EXAMPLE.COM:8443/paw/api/v1/prompts/ID?base_rev=1"))
        for (input in listOf("https://other.example:8443/paw/api/v1/me", "https://example.com/paw/api/v1/me",
            "https://example.com:8443/other/api/v1/me", "https://example.com:8443/paw/api/v10/me",
            "https://example.com:8443/paw-evil/api/v1/me", "https://example.com:8443/api/v1/me",
            "https://example.com:8443/paw/api/v1")) {
            assertEquals(HttpTransportError.ServerMismatch, assertFailsWith<HttpTransportError>(input) { server.validatedRequestURL(input) })
        }
        assertEquals(server.apiURL + "/me", server.validatedRequestURL("https://example.com:8443/p%61w/api/v1/me"))
        val https = SyncServerURL("https://10.0.0.1/paw")
        assertEquals(HttpTransportError.ServerMismatch, assertFailsWith<HttpTransportError> {
            https.validatedRequestURL("http://10.0.0.1/paw/api/v1/me")
        })
        val defaults = SyncServerURL("https://example.com")
        assertEquals(defaults.apiURL + "/me", defaults.validatedRequestURL("HTTPS://EXAMPLE.COM.:443/api/v1/me"))
        val encoded = SyncServerURL("https://example.com/café")
        assertEquals(encoded.apiURL + "/me", encoded.validatedRequestURL(encoded.apiURL + "/me"))
    }

    @Test fun requestValidationRetainsTypedSecurityFailures() {
        val server = SyncServerURL("https://example.com/paw")
        for (path in listOf("/paw/api/v1/../me", "/paw/api/v1/%2e%2e/me", "/paw/api/v1/a%2fb", "/paw/api/v1/me#synthetic")) {
            assertEquals(HttpTransportError.InvalidURL, assertFailsWith<HttpTransportError> { server.validatedRequestURL("https://example.com$path") })
        }
        assertEquals(HttpTransportError.CredentialsInURL, assertFailsWith<HttpTransportError> {
            server.validatedRequestURL("https://user:synthetic@example.com/paw/api/v1/me")
        })
        assertEquals(HttpTransportError.InsecureURL, assertFailsWith<HttpTransportError> {
            server.validatedRequestURL("http://example.com/paw/api/v1/me")
        })
    }

    @Test fun policyCarriesImmutableServerAndTrustWithAssistantAsTheDefault() {
        val server = SyncServerURL("https://example.com/paw")
        assertEquals(SyncTLSTrust.SYSTEM, HttpUrlPolicy.Sync(server).trust)
        val optIn = HttpUrlPolicy.Sync(server, SyncTLSTrust.SYSTEM_AND_USER)
        assertEquals(server, optIn.server)
        assertNotEquals(optIn, HttpUrlPolicy.Sync(SyncServerURL("https://other.example/paw"), optIn.trust))
    }

    @Test fun errorsRetainNoInputOrParserCause() {
        val sentinel = UUID.randomUUID().toString()
        val error = assertFailsWith<SyncServerURLError> { SyncServerURL("https://$sentinel@example.com") }
        assertEquals(SyncServerURLError.CredentialsInURL, error)
        for (text in listOf(error.toString(), error.message.orEmpty(), error.localizedMessage.orEmpty(), error.stackTraceToString())) {
            assertFalse(sentinel in text)
        }
        assertNull(error.cause)
        assertTrue(error.suppressed.isEmpty())
    }

    private companion object { val userID = ULID.parse("01ARZ3NDEKTSV4RRFFQ69G5FAV")!! }
}
