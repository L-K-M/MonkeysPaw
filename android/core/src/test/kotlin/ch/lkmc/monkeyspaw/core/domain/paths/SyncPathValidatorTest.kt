package ch.lkmc.monkeyspaw.core.domain.paths

import com.ibm.icu.lang.UCharacter
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SyncPathValidatorTest {
    @Test
    fun `ordinary and dot prefixed filenames remain available in both scopes`() {
        for (path in listOf("a.md", ".md", ".hidden.md", "Conflicts/Personal/a.md", "a..b/x.md",
            " Notes/a.md", "Topic: one/a.md", "a\u00A0/b.md", "a／b.md", "%2e%2e/a.md",
            "Folder/\u0301/x.md", "Folder/.hidden.md")) {
            for (scope in SyncPathValidator.Scope.entries) {
                assertEquals(path, SyncPathValidator.validate(path, scope).path)
            }
        }
    }

    @Test
    fun `ASCII slash bytes separate segments next to combining and supplementary scalars`() {
        assertIssue("", SyncPathIssueCode.EMPTY_PATH)
        listOf("/a.md", "//a.md", "/\u0301a.md").forEach { assertIssue(it, SyncPathIssueCode.ABSOLUTE_PATH) }
        for ((path, index) in listOf("a//b.md" to 1, "a.md/" to 1, "a//\u0301b.md" to 1)) {
            assertIssue(path, SyncPathIssueCode.EMPTY_SEGMENT, index)
        }
        for ((path, index) in listOf("./a.md" to 0, "../a.md" to 0, "a/./b.md" to 1,
            "a/../b.md" to 1, "a/\u0301/../b.md" to 2, "😀/\u0301/../b.md" to 2)) {
            assertIssue(path, SyncPathIssueCode.DOT_SEGMENT, index)
        }
        val result = validate("Cafe\u0301/\u0301A.md")
        assertEquals("Café/\u0301A.md", result.path)
        assertEquals("café/\u0301a.md", result.pathKey)
        assertIssue("a/\u0301/bad./x.md", SyncPathIssueCode.TRAILING_DOT_OR_SPACE, 2)
    }

    @Test
    fun `hidden directories and backslashes are rejected in both scopes`() {
        for ((path, index) in listOf(".hidden/a.md" to 0, ".git/a.md" to 0, "a/.hidden/b.md" to 1,
            ".\u0301/x.md" to 0, "a/.\u0301/.hidden.md" to 1)) {
            assertIssue(path, SyncPathIssueCode.HIDDEN_DIRECTORY, index)
        }
        listOf("a\\b.md", "C:\\a.md", "\\\\server\\a.md").forEach {
            assertIssue(it, SyncPathIssueCode.BACKSLASH, 0)
        }
        assertIssue("a/b\\c.md", SyncPathIssueCode.BACKSLASH, 1)
    }

    @Test
    fun `pinned ICU properties reject Cc and Cf including supplementary formats`() {
        assertEquals("17.0.0.0", UCharacter.getUnicodeVersion().toString())
        for (value in (0..31) + (127..159)) {
            assertIssue("a/one${scalar(value)}.md", SyncPathIssueCode.CONTROL_CHARACTER, 1)
        }
        for (value in listOf(0x00AD, 0x061C, 0x200B, 0x200D, 0x200E, 0x202E, 0x2060,
            0xFEFF, 0x1343F, 0xE0001, 0xE0020, 0xE007F)) {
            assertIssue("${scalar(value)}a.md", SyncPathIssueCode.CONTROL_CHARACTER, 0)
        }
        // Marks, private-use and unassigned scalars are not Cc/Cf.
        for (value in listOf(0x0301, 0xE000, 0x0378, 0x10FFFF)) validate("${scalar(value)}.md")
    }

    @Test
    fun `suffix and trailing punctuation use exact ASCII spellings`() {
        for ((path, index) in listOf("a./b.md" to 0, "a /b.md" to 0, "a/b./c.md" to 1,
            "a/b /c.md" to 1, "a.md." to 0, "a.md " to 0)) {
            assertIssue(path, SyncPathIssueCode.TRAILING_DOT_OR_SPACE, index)
        }
        for (path in listOf("a", "a.MD", "a.Md", "a.mD", "a.md.txt", "a.md/x", "a.md\u0301", "a.mＤ")) {
            assertIssue(path, SyncPathIssueCode.INVALID_EXTENSION)
        }
    }

    @Test
    fun `segment limits count UTF-8 bytes including the suffix`() {
        for (size in listOf(254, 255, 256)) {
            val directory = "a".repeat(size) + "/x.md"
            val filename = "a".repeat(size - 3) + ".md"
            if (size <= 255) {
                validate(directory)
                validate(filename)
            } else {
                assertIssue(directory, SyncPathIssueCode.SEGMENT_TOO_LONG, 0)
                assertIssue(filename, SyncPathIssueCode.SEGMENT_TOO_LONG, 0)
            }
        }
        val multibyte = "😀".repeat(63)
        validate("$multibyte.md")
        assertIssue("${multibyte}a.md", SyncPathIssueCode.SEGMENT_TOO_LONG, 0)
        assertIssue("a/" + "é".repeat(128) + "/x.md", SyncPathIssueCode.SEGMENT_TOO_LONG, 1)
    }

    @Test
    fun `whole path limits count slash bytes and precede segment limits`() {
        val prefix = ("a".repeat(255) + "/").repeat(3)
        for (size in listOf(1_023, 1_024, 1_025)) {
            val path = prefix + "b/" + "x".repeat(size - utf8Size(prefix) - 5) + ".md"
            assertEquals(size, utf8Size(path))
            if (size <= 1_024) validate(path) else assertIssue(path, SyncPathIssueCode.PATH_TOO_LONG)
        }
    }

    @Test
    fun `byte limits apply after NFC composition and expansion`() {
        val nfd = "e\u0301".repeat(126) + ".md"
        assertTrue(utf8Size(nfd) > 255)
        assertEquals(255, utf8Size(validate(nfd).path))
        validate("\u0344".repeat(63) + ".md")
        assertIssue("\u0344".repeat(64) + ".md", SyncPathIssueCode.SEGMENT_TOO_LONG, 0)

        val path = ("e\u0301".repeat(127) + "/").repeat(3) + "bbb/" + "e\u0301".repeat(126) + ".md"
        assertTrue(utf8Size(path) > 1_024)
        assertEquals(1_024, utf8Size(validate(path).path))
    }

    @Test
    fun `NFC retains and orders every scalar in long combining runs`() {
        val input = "\u0F73".repeat(20) + ".md"
        val expected = "\u0F71".repeat(20) + "\u0F72".repeat(20) + ".md"
        val actual = validate(input)
        assertEquals(expected, actual.path)
        assertEquals(expected, actual.pathKey)
        val longRun = "\u0F73".repeat(1_000)
        assertEquals("\u0F71".repeat(1_000) + "\u0F72".repeat(1_000), UnicodeText.nfc(longRun))
        assertIssue("$longRun.md", SyncPathIssueCode.PATH_TOO_LONG)
    }

    @Test
    fun `full default fold preserves accents width and non Turkic I distinctions`() {
        val cases = mapOf("Café/É.md" to "café/é.md", "Cafe\u0301/E\u0301.md" to "café/é.md",
            "Straße/ẞ.md" to "strasse/ss.md", "Σ/ςσ.md" to "σ/σσ.md", "İ/Iıi.md" to "i\u0307/iıi.md",
            "ﬃ/K.md" to "ffi/k.md", "\u1F80.md" to "ἀι.md", "J\u030C.md" to "ǰ.md",
            "ꭰ.md" to "Ꭰ.md", "Ꭰ.md" to "Ꭰ.md", "\u1C80.md" to "в.md",
            "\uA7CB.md" to "\u0264.md", "${scalar(0x10D50)}.md" to "${scalar(0x10D70)}.md")
        for ((path, key) in cases) {
            val actual = validate(path)
            assertEquals(key, actual.pathKey)
            assertEquals(actual, validate(actual.path))
            assertEquals(key, validate(key).pathKey)
        }
        for ((first, second) in listOf("İ.md" to "i.md", "ı.md" to "i.md", "é.md" to "e.md", "Ａ.md" to "a.md")) {
            assertNotEquals(validate(first).pathKey, validate(second).pathKey)
        }
    }

    @Test
    fun `fold expansion has no segment or whole key size cap`() {
        val path = ("İ".repeat(127) + "/").repeat(3) + "bbb/" + "İ".repeat(126) + ".md"
        assertEquals(1_024, utf8Size(path))
        val actual = validate(path)
        val expected = ("i\u0307".repeat(127) + "/").repeat(3) + "bbb/" + "i\u0307".repeat(126) + ".md"
        assertEquals(expected, actual.pathKey)
        assertTrue(utf8Size(actual.pathKey) > 1_024)
        assertTrue(utf8Size(actual.pathKey.substringBefore('/')) > 255)
        assertEquals(actual.pathKey, UnicodeText.nfc(SyncPathCaseFold.fold(actual.pathKey)))
    }

    @Test
    fun `folded Groups prefix is reserved only for private paths and Conflicts is allowed`() {
        for (path in listOf("Groups/a.md", "groups/a.md", "GROUPS/a.md", "gRoUpS/a.md",
            "Groupſ/a.md", "Groups/\u0301a.md")) {
            assertIssue(path, SyncPathIssueCode.RESERVED_GROUPS_PREFIX)
            SyncPathValidator.validate(path, SyncPathValidator.Scope.GROUP)
        }
        for (path in listOf("Groups.md", "GroupsExtra/a.md", "Other/Groups/a.md", "Gróups/a.md",
            "Gro\u0301ups/a.md", "Conflicts/a.md", "CONFLICTS/Groups/a.md", "Ｇroups/a.md")) validate(path)
    }

    @Test
    fun `first failure has the Swift precedence and retains no input path`() {
        assertIssue("/a\\.MD", SyncPathIssueCode.ABSOLUTE_PATH)
        assertIssue("a".repeat(1_025), SyncPathIssueCode.PATH_TOO_LONG)
        assertIssue("../a\\.MD", SyncPathIssueCode.DOT_SEGMENT, 0)
        assertIssue(".hidden/a\\.MD", SyncPathIssueCode.HIDDEN_DIRECTORY, 0)
        assertIssue("a\\\u0000.MD", SyncPathIssueCode.BACKSLASH, 0)
        assertIssue("a\u0000.MD ", SyncPathIssueCode.CONTROL_CHARACTER, 0)
        assertIssue("a".repeat(256) + " /x.MD", SyncPathIssueCode.TRAILING_DOT_OR_SPACE, 0)
        assertIssue("Groups/a.MD", SyncPathIssueCode.INVALID_EXTENSION)
        val issue = assertFailsWith<SyncPathIssue> { validate("private-name.MD") }
        assertNull(issue.segmentIndex)
        assertNull(issue.cause)
        assertFalse(issue.toString().contains("private-name"))
    }

    @Test
    fun `malformed JVM UTF-16 cannot be silently repaired into a sync path`() {
        for (input in listOf("\uD800.md", "\uDC00.md", "/\uD800.md", "a/\uD800/b.md")) {
            assertIssue(input, SyncPathIssueCode.NORMALIZATION_FAILED)
        }
    }

    @Test
    fun `sync normalization does not mutate or equate local string bytes`() {
        val localNfc = "é.md"
        val localNfd = "e\u0301.md"
        assertEquals(2, setOf(localNfc, localNfd).size)
        assertEquals(validate(localNfc), validate(localNfd))
        assertEquals("e\u0301.md", localNfd)
    }

    private fun validate(path: String): SyncPath = SyncPathValidator.validate(path, SyncPathValidator.Scope.USER)

    private fun assertIssue(path: String, code: SyncPathIssueCode, segment: Int? = null) {
        val scopes = if (code == SyncPathIssueCode.RESERVED_GROUPS_PREFIX) listOf(SyncPathValidator.Scope.USER)
            else SyncPathValidator.Scope.entries
        for (scope in scopes) {
            val issue = assertFailsWith<SyncPathIssue> { SyncPathValidator.validate(path, scope) }
            assertEquals(code, issue.code)
            assertEquals(segment, issue.segmentIndex)
        }
    }
}

internal fun scalar(value: Int): String = String(Character.toChars(value))
private fun utf8Size(text: String): Int = text.toByteArray(Charsets.UTF_8).size
