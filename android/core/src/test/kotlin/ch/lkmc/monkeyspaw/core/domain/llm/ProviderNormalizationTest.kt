package ch.lkmc.monkeyspaw.core.domain.llm

import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/** Port of Swift ProviderNormalizationTests; no shared provider-URL fixture exists yet. */
class ProviderNormalizationTest {
    @Test fun escapedIPLiteralSpellingsAreRejectedWithoutDecoding() {
        for (kind in ProviderKind.entries) {
            for (scheme in listOf("http", "https")) {
                for (host in listOf("[::%31]", "[%3A%3A1]", "[v1.%66e]", "[::%2531]")) {
                    assertError("$scheme://$host", kind, ProviderSettingsError.InvalidBaseURL)
                }
            }
            for (input in listOf("https://[::%31]?q", "https://[%3A%3A1]#fragment")) {
                assertError(input, kind, ProviderSettingsError.QueryOrFragmentInURL)
            }
            assertError("https://user@[::%31]", kind, ProviderSettingsError.CredentialsInURL)
        }
    }

    @Test fun invalidBracketedHostsAreRejectedForBothSchemesAndKinds() {
        val hosts = listOf("[]", "[!]", "[foo]", "[::g]", "[1:2:3]", "[1:2:3:4:5:6:7:8:9]",
            "[1::2::3]", "[:::1]", "[12345::]", "[::ffff:999.0.0.1]",
            "[::ffff:192.0.02.1]", "[192.0.2.1::]", "[1:2:3:4:5:6:7:8::]",
            "[1:2:3:4:5:6::192.0.2.1]", "[v.fe]", "[vg.fe]", "[v1.]", "%5bfoo%5d")
        for (kind in ProviderKind.entries) for (scheme in listOf("http", "https")) for (host in hosts) {
            assertError("$scheme://$host", kind, ProviderSettingsError.InvalidBaseURL)
        }
    }

    @Test fun overflowedPortLexemesAreRejectedForBothKinds() {
        for (kind in ProviderKind.entries) for (host in listOf("example.com", "[::1]", "[v1.fe]")) {
            for (port in listOf("0", "65536", "9223372036854775808", "18446744073709551616", "9".repeat(100))) {
                assertError("https://$host:$port/gateway", kind, ProviderSettingsError.InvalidBaseURL)
            }
        }
    }

    @Test fun undecodablePercentEscapedPathsAreRejectedWithoutTruncation() {
        for (kind in ProviderKind.entries) {
            for (path in listOf("/%FF", "/gateway/a%FFb/models", "/%C3", "/%C0%AF", "/%ED%A0%80", "/%F4%90%80%80", "/%E2%82")) {
                assertError("https://example.com$path", kind, ProviderSettingsError.InvalidBaseURL)
            }
        }
    }

    @Test fun validIPLiteralPortAndPathSpellingsRemainCanonical() {
        val cases = listOf(
            "https://[::]" to "https://[::]",
            "https://[2001:DB8::1]:443/gateway" to "https://[2001:db8::1]/gateway",
            "https://[1:2:3:4:5:6:7:8]:65535" to "https://[1:2:3:4:5:6:7:8]:65535",
            "https://[1:2:3:4:5:6:7::]" to "https://[1:2:3:4:5:6:7::]",
            "https://[::ffff:192.0.2.1]" to "https://[::ffff:192.0.2.1]",
            "https://[1:2:3:4:5:6:192.0.2.1]" to "https://[1:2:3:4:5:6:192.0.2.1]",
            "https://[v1.fe]" to "https://[v1.fe]",
            "https://[vF.a:b]" to "https://[vf.a:b]",
            "https://example.com:00000000000000000000000000000000000000000000001" to "https://example.com:1",
            "https://example.com/%" to "https://example.com/%25",
            "https://example.com/%ZZ" to "https://example.com/%25ZZ",
            "https://example.com/caf%C3%A9" to "https://example.com/caf%C3%A9",
        )
        for (kind in ProviderKind.entries) {
            assertNormalization(cases.map { (input, base) -> input to
                if (kind == ProviderKind.OPENAI_COMPATIBLE && '/' !in base.drop(8)) "$base/v1" else base }, kind)
        }
    }

    @Test fun emptyPortsNormalizeToTheAbsentPortForEveryHostKind() {
        for (kind in ProviderKind.entries) {
            assertNormalization(listOf("example.com", "[::1]", "[v1.fe]").map {
                "https://$it:/gateway" to "https://$it/gateway"
            }, kind)
        }
    }

    @Test fun anthropicBasesAndFullEndpointsReachAFixedPoint() {
        val cases = listOf(
            "https://api.anthropic.com" to "https://api.anthropic.com",
            " HTTPS://API.ANTHROPIC.COM:443/ \n" to "https://api.anthropic.com",
            "https://api.anthropic.com/v1/" to "https://api.anthropic.com",
            "https://api.anthropic.com/v1/messages/" to "https://api.anthropic.com",
            "https://api.anthropic.com/v1/models" to "https://api.anthropic.com",
            "https://proxy.example/anthropic/v1/messages" to "https://proxy.example/anthropic",
            "https://proxy.example/anthropic/" to "https://proxy.example/anthropic",
            "https://proxy.example/anthropic/v1/v1/messages" to "https://proxy.example/anthropic",
            "http://[0:0:0:0:0:0:0:1]:8080/v1" to "http://[0:0:0:0:0:0:0:1]:8080",
            "http://localhost:8080/v1" to "http://localhost:8080",
        )
        assertNormalization(cases, ProviderKind.ANTHROPIC)
    }

    @Test fun openAIBasesCustomPathsAndFullEndpointsReachAFixedPoint() {
        val cases = listOf(
            "https://api.openai.com" to "https://api.openai.com/v1",
            "https://api.openai.com/" to "https://api.openai.com/v1",
            "https://api.openai.com/v1/" to "https://api.openai.com/v1",
            "https://api.openai.com/v1/chat/completions/" to "https://api.openai.com/v1",
            "https://api.openai.com/chat/completions" to "https://api.openai.com/v1",
            "https://openrouter.ai/api/v1/chat/completions" to "https://openrouter.ai/api/v1",
            "https://proxy.example/custom" to "https://proxy.example/custom",
            "https://proxy.example/custom/models" to "https://proxy.example/custom",
            "https://proxy.example/custom/models/models" to "https://proxy.example/custom",
            "http://127.0.0.1:11434/v1" to "http://127.0.0.1:11434/v1",
            "http://[::1]:1234/" to "http://[::1]:1234/v1",
            "http://localhost.:80" to "http://localhost/v1",
        )
        assertNormalization(cases, ProviderKind.OPENAI_COMPATIBLE)
    }

    @Test fun endpointConstructionPreservesEscapedSegmentsForProfilesAndConnections() {
        for (kind in ProviderKind.entries) {
            for (path in listOf("", "/gateway", "/gateway%20space")) {
                val expected = "https://example.com" + if (path.isEmpty() && kind == ProviderKind.OPENAI_COMPATIBLE) "/v1" else path
                assertNormalization(listOf("https://example.com$path" to expected), kind)
            }
        }
    }

    @Test fun httpAcceptsOnlyLiteralCanonicalLoopback() {
        val valid = listOf("localhost", "127.0.0.1", "127.12.34.56", "127.255.255.255", "[::1]", "[0:0:0:0:0:0:0:1]", "[0::01]")
        val invalid = listOf(
            "example.com", "localhost.evil.test", "127.0.0.1.evil.test", "192.168.1.2", "[::2]", "127.0.0.999",
            "127.0.0.08", "127.09.1.1", "127.0.018.1", "127.00.0.1", "127.0.0.010", "127.0.0.01",
            "127.1", "2130706433", "0x7f000001", "10.0.0.1", "172.16.0.1", "[fc00::1]",
            "localhost..", "[::ffff:127.0.0.1]", "[::127.0.0.1]", "[::ffff:7f00:1]",
        )
        for (kind in ProviderKind.entries) {
            for (host in valid) ProviderSettings.normalizeBaseURL("http://$host:8080", kind)
            for (host in invalid) assertError("http://$host", kind, ProviderSettingsError.InsecureBaseURL)
        }
        // Direct classification must not resolve names or accept malformed IPv6 groups.
        for (host in listOf(":::", "::1::", "00000::1", ":1", "0:0:0:0:0:0:1", "0:0:0:0:0:0:0:0:1", "::g")) {
            assertEquals(false, ProviderSettings.isLoopbackHost(host), host)
        }
    }

    @Test fun credentialsQueriesAndFragmentsAreRejectedForBothKinds() {
        for (kind in ProviderKind.entries) {
            for (input in listOf("https://user:password@example.com", "https://user@example.com", "https://@example.com")) {
                assertError(input, kind, ProviderSettingsError.CredentialsInURL)
            }
            for (input in listOf("https://example.com?api_key=secret", "https://example.com?token=secret",
                "https://example.com?harmless=value", "https://example.com#secret", "https://example.com?", "https://example.com#")) {
                assertError(input, kind, ProviderSettingsError.QueryOrFragmentInURL)
            }
        }
    }

    @Test fun malformedSchemesPortsAndUnsafePathsAreRejected() {
        val cases = listOf(
            "", "example.com", "/v1", "file:///v1", "ftp://example.com", "https://",
            "https://example.com:0", "https://example.com:65536", "https://example.com:-1", "https://example.com:abc",
            "https://example.com/a/../v1", "https://example.com/./v1", "https://example.com/%2e%2e/v1",
            "https://example.com/%2E/v1", "https://example.com/v1%2Fmessages", "https://example.com/a%2fb",
            "https://example.com/a\\b", "https://example.com/a%5Cb", "https://example.com/a//b", "https://example.com/a%0Ab",
            "https://example.com/a%00b", "https://example.com/a\nb", "https://example.com/a\u200db", "https://example.com/a%C2%ADb",
            "https://café.example", "https://[::1%25lo]",
        )
        for (kind in ProviderKind.entries) for (input in cases) assertError(input, kind, ProviderSettingsError.InvalidBaseURL)
    }

    @Test fun foundationEscapingAndDecodedSuffixesRemainIdempotent() {
        // Supplementary cases verified against the Swift normalization function on this host.
        val cases = listOf(
            "https://example.com/gateway%20space" to "https://example.com/gateway%20space",
            "https://example.com/a b" to "https://example.com/a%20b",
            "https://example.com/%41/%7e/%25/%3F/%23" to "https://example.com/A/~/%25/%3F/%23",
            "http://%6cocalhost" to "http://localhost",
            "https://some_host" to "https://some_host",
            "https://example.com:" to "https://example.com",
            "https://example.com:01" to "https://example.com:1",
            "https://example.com/models/messages/v1/v1" to "https://example.com",
            "https://example.com/%" to "https://example.com/%25",
            "https://example.com/[a]" to "https://example.com/%5Ba%5D",
            "https://example.com/a|b" to "https://example.com/a%7Cb",
            "https://example.com/a;b" to "https://example.com/a;b",
            "https://example.com/gateway/%76%31/%6dodels" to "https://example.com/gateway",
        )
        assertNormalization(cases, ProviderKind.ANTHROPIC)
        for (kind in ProviderKind.entries) {
            val suffixes = if (kind == ProviderKind.ANTHROPIC) listOf("/v1", "/messages", "/models") else listOf("/models", "/chat/completions")
            for (first in suffixes) for (second in suffixes) {
                assertNormalization(listOf("https://example.com/gateway$first$second/" to "https://example.com/gateway"), kind)
            }
        }
    }

    @Test fun canonicalizationDoesNotDependOnTheJvmLocale() {
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("tr-TR"))
            assertNormalization(listOf("HTTPS://API.ANTHROPIC.COM:443/V1" to "https://api.anthropic.com/V1"), ProviderKind.ANTHROPIC)
        } finally {
            Locale.setDefault(previous)
        }
    }

    @Test fun malformedAuthoritiesMatchSwiftRefusalsAndErrorOrdering() {
        for (kind in ProviderKind.entries) {
            for (input in listOf("https://user@", "https://@", "https://user@:0", "https://a[b]", "https://a]b",
                "https://a%3ab", "https://foo%40bar", "https://foo%3fbar", "https://foo%23bar", "https://foo%5dbar",
                "https://bad host", "https://%2f127.0.0.1", "https://foo@example.com:bad")) {
                assertError(input, kind, ProviderSettingsError.InvalidBaseURL)
            }
            for (input in listOf("https://example.com:0?q", "https://example.com:65536?q", "https://a%3ab?q", "https://foo%40bar?q")) {
                assertError(input, kind, ProviderSettingsError.QueryOrFragmentInURL)
            }
            assertError("https://foo@example.com:0", kind, ProviderSettingsError.CredentialsInURL)
        }
    }

    @Test fun foundationBracketedHostsAreCarriedWithoutJvmReinterpretation() {
        assertNormalization(listOf(
            "https://[v1.fe]" to "https://[v1.fe]",
            "https://[vF.a:b]" to "https://[vf.a:b]",
            "https://[::1]:" to "https://[::1]",
            "https://[v1.fe]:" to "https://[v1.fe]",
        ), ProviderKind.ANTHROPIC)
        for (kind in ProviderKind.entries) {
            assertError("http://[v1.fe]", kind, ProviderSettingsError.InsecureBaseURL)
        }
    }

    @Test fun credentialOriginsIncludeSchemeAndEffectivePortButNotPathOrModel() {
        fun profile(base: String, model: String = "manual") = ProviderProfile(ProviderProfileID(), "Name", ProviderKind.ANTHROPIC, base, model)
        assertEquals("https://example.com:443", profile("HTTPS://EXAMPLE.COM.:443/gateway/v1/messages").credentialOrigin)
        assertEquals("http://localhost:80", profile("http://localhost").credentialOrigin)
        assertEquals("https://[::1]:8443", profile("https://[::1]:8443").credentialOrigin)
        assertEquals(profile("https://example.com/a").credentialOrigin, profile("https://example.com/b", "other").credentialOrigin)
        assertNotEquals(profile("https://localhost").credentialOrigin, profile("http://localhost").credentialOrigin)
        assertNotEquals(profile("https://localhost").credentialOrigin, profile("https://localhost:8443").credentialOrigin)
    }

    private fun assertNormalization(cases: List<Pair<String, String>>, kind: ProviderKind) {
        for ((input, expected) in cases) {
            val normalized = ProviderSettings.normalizeBaseURL(input, kind)
            assertEquals(expected, normalized, input)
            assertEquals(normalized, ProviderSettings.normalizeBaseURL(expected, kind), input)
            val profile = ProviderProfile(ProviderProfileID(), "Custom", kind, input, "manual")
            val connection = ProviderConnection(profile.id, kind, profile.baseURL, profile.modelID, null)
            val completion = if (kind == ProviderKind.ANTHROPIC) "/v1/messages" else "/chat/completions"
            val models = if (kind == ProviderKind.ANTHROPIC) "/v1/models" else "/models"
            assertEquals(expected + completion, profile.completionURL, input)
            assertEquals(expected + models, profile.modelsURL, input)
            assertEquals(profile.completionURL, connection.completionURL, input)
            assertEquals(profile.modelsURL, connection.modelsURL, input)
            assertTrue("%2f" !in profile.completionURL.lowercase(Locale.ROOT), input)
        }
    }

    private fun assertError(input: String, kind: ProviderKind, expected: ProviderSettingsError) {
        assertEquals(expected, assertFailsWith<ProviderSettingsError>(input) { ProviderSettings.normalizeBaseURL(input, kind) }, input)
    }
}
