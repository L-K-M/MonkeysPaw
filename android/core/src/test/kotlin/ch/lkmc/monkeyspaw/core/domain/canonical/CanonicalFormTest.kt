package ch.lkmc.monkeyspaw.core.domain.canonical

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueLocation
import ch.lkmc.monkeyspaw.core.domain.format.PromptWriteError
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CanonicalFormTest {
    private val id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    private val otherId = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
    private fun bytes(text: String) = text.toByteArray(Charsets.UTF_8)
    private fun group(text: String) = CanonicalForm.group(bytes(text), "source.md")
    private fun user(text: String) = CanonicalForm.user(bytes(text), "source.md")

    private fun adoption(left: String, right: String, expected: Boolean, scope: CanonicalForm.Scope = CanonicalForm.Scope.GROUP) {
        assertEquals(expected, CanonicalForm.equivalentForAdoption(bytes(left), bytes(right), scope, "source.md"))
        assertEquals(expected, CanonicalForm.equivalentForAdoption(bytes(right), bytes(left), scope, "source.md"))
    }

    @Test fun personalPresenceDistinguishesAbsentFalseAndTrueAndWarnsForEveryPrivate() {
        for (favorite in listOf(null, false, true)) for (privacy in listOf(null, false, true)) {
            val lines = mutableListOf("id: $id", "title: Shared")
            if (favorite != null) lines.add("favorite: $favorite")
            if (privacy != null) lines.add("private: $privacy")
            val result = group("---\n${lines.joinToString("\n")}\n---\nBody\r\n")
            assertContentEquals(bytes("---\nid: $id\ntitle: Shared\n---\nBody\r\n"), result.bytes)
            assertEquals(favorite, result.favorite)
            assertEquals(if (privacy == null) emptyList() else listOf(PromptIssueCode.GROUP_PRIVATE_REMOVED), result.warnings.map { it.code })
            val repeated = CanonicalForm.group(result.bytes, "source.md")
            assertContentEquals(result.bytes, repeated.bytes)
            assertEquals(result.canonicalHash, repeated.canonicalHash)
            assertNull(repeated.favorite)
            assertTrue(repeated.warnings.isEmpty())
        }
    }

    @Test fun onlyTopLevelPersonalKeysAreRemovedAndUnknownValuesRetainOrder() {
        val input = "---\nprivate: true\nfavorite: false\nx: {private: false, favorite: true, z: [null, true, '010'], a: 2.5}\ndescription: ''\nformat: 1\n---\nBody"
        assertContentEquals(bytes("---\ndescription: \"\"\nformat: 1\nx:\n  private: false\n  favorite: true\n  z:\n  - null\n  - true\n  - \"010\"\n  a: 2.5\n---\nBody"), group(input).bytes)
    }

    @Test fun bodyBytesRemainExactAcrossCrLfBomsNullsAndFrontMatterLikeText() {
        for (body in listOf("", "No final newline", "\r\n\n  indent\t \r\n\n", "é / e\u0301 / 界 / 🐾\n", "\uFEFFBody\n", "\u0000body\r\n", "---\nBody\n", "{{not valid}}\n")) {
            val result = group("---\r\nfavorite: true\r\nprivate: false\r\n---\r\n$body")
            assertContentEquals(bytes("---\n{}\n---\n$body"), result.bytes)
            assertEquals(body, PromptCodec.parseFile(result.bytes, "source.md").body)
        }
        for (body in listOf("", "Plain\r\n", "\uFEFF---\nprivate: true\n---\nBody\r\n", "\uFEFFBody\n")) {
            assertContentEquals(bytes(body), group(body).bytes)
            assertNull(group(body).favorite)
        }
    }

    @Test fun userStorageStaysVerbatimAndSha256UsesTheWholeStoredBytes() {
        val source = "---\r\n# keep comment\r\nprivate: true\r\nfavorite: false\r\nid: ${id.lowercase()}\r\ntitle: 'Shared'\r\n---\r\nBody\r\n"
        val result = user(source)
        assertContentEquals(bytes(source), result.bytes)
        assertNull(result.favorite)
        assertTrue(result.warnings.isEmpty())
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", group("").canonicalHash)
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", group("abc").canonicalHash)
        assertNotEquals(result.canonicalHash, user(source.replace(id.lowercase(), otherId.lowercase())).canonicalHash)
        assertNotEquals(group("é").canonicalHash, group("e\u0301").canonicalHash)
    }

    @Test fun returnedAndSuppliedByteArraysCannotInvalidateTheHash() {
        val input = bytes("abc")
        val result = CanonicalForm.user(input, "source.md")
        input[0] = 0
        result.bytes[0] = 0
        assertContentEquals(bytes("abc"), result.bytes)
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", result.canonicalHash)
    }

    @Test fun existingWarningsKeepOrderAndPrivateRemovalHasAValueLocation() {
        val input = "---\nprivate: false\nfields: {unused: {}}\n---\n{{not valid}}"
        val result = group(input)
        assertEquals(listOf(PromptIssueCode.INVALID_PLACEHOLDER, PromptIssueCode.UNUSED_FIELD, PromptIssueCode.GROUP_PRIVATE_REMOVED), result.warnings.map { it.code })
        assertEquals(PromptIssueLocation.FrontMatter(2, 10), result.warnings.last().location)
        assertEquals(listOf(PromptIssueCode.INVALID_PLACEHOLDER, PromptIssueCode.UNUSED_FIELD), user(input).warnings.map { it.code })
    }

    @Test fun invalidInputFailsBeforePersonalKeysCanBeStrippedOrAdoptionCanIgnoreIt() {
        val inputs = listOf("---\nfavorite: 'true'\n---\nBody", "---\nprivate: 'false'\n---\nBody",
            "---\nprivate: on\n---\nBody", "---\nprivate: true\nprivate: false\n---\nBody",
            "---\nid: invalid\n---\nBody", "---\nunknown: &anchor [a]\n---\nBody",
            "---\nunknown: {nested: on}\n---\nBody", "---\n[broken\n---\nBody", "---\nprivate: true\nBody", "{{unclosed")
            .map(::bytes) + listOf(byteArrayOf(0xff.toByte()), byteArrayOf(0xc0.toByte(), 0xaf.toByte()))
        for (input in inputs) {
            assertEquals(PromptWriteError.InvalidPrompt, assertFailsWith<PromptWriteError> { CanonicalForm.group(input, "source.md") })
            assertEquals(PromptWriteError.InvalidPrompt, assertFailsWith<PromptWriteError> { CanonicalForm.user(input, "source.md") })
            for (scope in CanonicalForm.Scope.entries) {
                assertEquals(PromptWriteError.InvalidPrompt, assertFailsWith<PromptWriteError> {
                    CanonicalForm.equivalentForAdoption(input, bytes("Body"), scope, "source.md")
                })
                assertEquals(PromptWriteError.InvalidPrompt, assertFailsWith<PromptWriteError> {
                    CanonicalForm.equivalentForAdoption(bytes("Body"), input, scope, "source.md")
                })
            }
        }
    }

    @Test fun futureFormatRefusalPrecedesStrippingAndOtherValidationErrors() {
        for (version in listOf("2", "999999999999999999999999999999999999")) {
            val input = bytes("---\nformat: $version\nprivate: on\nfavorite: true\n---\nBody")
            val expected = PromptWriteError.UnsupportedFormat(PromptCodec.parseFile(input, "source.md").frontMatter.format)
            assertEquals(expected, assertFailsWith<PromptWriteError> { CanonicalForm.group(input, "source.md") })
            assertEquals(expected, assertFailsWith<PromptWriteError> { CanonicalForm.user(input, "source.md") })
            for (scope in CanonicalForm.Scope.entries) assertEquals(expected, assertFailsWith<PromptWriteError> {
                CanonicalForm.equivalentForAdoption(bytes("Body"), input, scope, "source.md")
            })
        }
    }

    @Test fun canonicalExpansionIsCheckedAfterGroupStrippingAndUserStorageDoesNotExpand() {
        val exact = ByteArray(Limits.maxPromptBytes) { 'a'.code.toByte() }
        assertContentEquals(exact, CanonicalForm.group(exact, "source.md").bytes)
        assertContentEquals(exact, CanonicalForm.user(exact, "source.md").bytes)
        val oversized = exact + byteArrayOf(97)
        assertEquals(PromptWriteError.InvalidPrompt, assertFailsWith<PromptWriteError> { CanonicalForm.group(oversized, "source.md") })
        assertEquals(PromptWriteError.InvalidPrompt, assertFailsWith<PromptWriteError> { CanonicalForm.user(oversized, "source.md") })
        val header = "---\nx: [a, b, c]\n---\n"
        val expanded = bytes(header + "a".repeat(Limits.maxPromptBytes - bytes(header).size))
        assertContentEquals(expanded, CanonicalForm.user(expanded, "source.md").bytes)
        assertEquals(PromptWriteError.SourceTooLarge, assertFailsWith<PromptWriteError> { CanonicalForm.group(expanded, "source.md") })
        val personal = "---\nfavorite: true\nprivate: true\nx: [a, b, c]\n---\n"
        val shrinks = bytes(personal + "a".repeat(Limits.maxPromptBytes - bytes(personal).size))
        assertEquals(PromptWriteError.SourceTooLarge, assertFailsWith<PromptWriteError> { PromptCodec.write(PromptCodec.parseFile(shrinks, "source.md")) })
        assertTrue(CanonicalForm.group(shrinks, "source.md").bytes.size < Limits.maxPromptBytes)
    }

    @Test fun adoptionIgnoresIdentityWhileStoredHashesIncludeItAndPersonalKeysRespectScope() {
        val local = "---\n# comment\ntitle: 'Shared'\nfavorite: true\nprivate: true\n---\nBody\r\n"
        val server = "---\nid: $id\ntitle: Shared\n---\nBody\r\n"
        val other = server.replace(id, otherId)
        adoption(local, server, true)
        adoption(server, other, true)
        adoption(local, server, false, CanonicalForm.Scope.USER)
        assertNotEquals(group(server).canonicalHash, group(other).canonicalHash)
        val personal = "---\nid: $id\nfavorite: true\nprivate: true\ntitle: Shared\n---\nBody\r\n"
        adoption(local, personal, true, CanonicalForm.Scope.USER)
        assertNotEquals(user(local).canonicalHash, user(personal).canonicalHash)
    }

    @Test fun adoptionTreatsEmptyHeadersAsAbsentWithoutIgnoringOtherOptionalKeys() {
        val body = "Body\r\n"
        for (header in listOf("id: $id", "{}", "# empty", "id: $id\nfavorite: false\nprivate: false")) {
            adoption(body, "---\n$header\n---\n$body", true)
        }
        adoption(body, "---\nid: $id\n---\n$body", true, CanonicalForm.Scope.USER)
        adoption(body, "---\nfavorite: false\n---\n$body", false, CanonicalForm.Scope.USER)
        val base = "---\nid: $id\ntitle: Shared\nunknown: {value: a}\n---\né\r\n"
        for (candidate in listOf(base.replace("Shared", "Changed"), base.replace("value: a", "value: b"),
            base.replace("title:", "description: ''\ntitle:"), base.replace("é", "e\u0301"), base.replace("\r\n", "\n"))) {
            for (scope in CanonicalForm.Scope.entries) adoption(base, candidate, false, scope)
        }
    }

    @Test fun adoptionComparesTheBodyBoundarySeparatelyInBothDirections() {
        val local = "---\ntitle: Shared\n---\nBody\n"
        val server = "---\nid: $id\n---\n$local"
        for (scope in CanonicalForm.Scope.entries) {
            adoption(local, server, false, scope)
            adoption("\uFEFF$local", local, false, scope)
        }
        assertFalse(CanonicalForm.equivalentForAdoption(bytes("é"), bytes("e\u0301"), CanonicalForm.Scope.USER, "source.md"))
    }
}
