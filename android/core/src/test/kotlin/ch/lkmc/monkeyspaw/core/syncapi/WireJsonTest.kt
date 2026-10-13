package ch.lkmc.monkeyspaw.core.syncapi

import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.assertContentEquals

class WireJsonTest {
    private val id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    private val time = "2026-10-12T20:10:56.557Z"
    private val token = "A".repeat(43)
    private val user = User(id, "alice", null, AccountKind.MEMBER, time, null)
    private val integer = WireCodec("Integer", WireValue::longValue, ::wireLong)

    @Test
    fun `Longs never pass through floating point or coercion`() {
        for (value in listOf(Long.MIN_VALUE, -1, 0, 1, 9_007_199_254_740_993, Long.MAX_VALUE)) {
            val bytes = value.toString().toByteArray()
            assertEquals(value, integer.decode(bytes))
            assertContentEquals(bytes, integer.encode(value))
        }
        for (source in listOf("9223372036854775808", "-9223372036854775809", "1.5", "true", "false", "\"1\"", "null")) {
            assertFailsWith<WireDecodingException> { integer.decode(source.toByteArray()) }
        }
        // Noncanonical integral tokens are an implementation choice, not a corpus promise.
        for (source in listOf("1.0", "1e0")) assertEquals(1L, integer.decode(source.toByteArray()))
    }

    @Test
    fun `strict parser rejects malformed JSON and UTF-8`() {
        for (source in listOf("", "tru", "nul", "{", "[1", "1 2", "{}{}", "[1,]", "{\"x\":1,}",
            "{x:1}", "{\"x\" 1}", "[01]", "[-01]", "[+1]", "[.5]", "[1.]", "[1e]", "[NaN]",
            "[Infinity]", "/*comment*/1", "\"\\x20\"", "\"raw\nline\"", "\"raw\tline\"", "\"raw\u0000nul\"",
            "\"\\uD800\"", "\"\\uDC00\"", "\"\\uD800\\u0041\"", "\"\\uZZZZ\"", "\u00A01")) {
            assertFailsWith<WireContractException> { WireJson.parse(source.toByteArray()) }
        }
        for (bytes in listOf(byteArrayOf(0xff.toByte()), byteArrayOf(0xc3.toByte(), 0x28),
            byteArrayOf(0xed.toByte(), 0xa0.toByte(), 0x80.toByte()))) {
            assertFailsWith<WireDecodingException> { HealthResponse.codec.decode(bytes) }
        }
    }

    @Test
    fun `excessive JSON nesting produces a sanitized decoding failure`() {
        WireJson.parse(("[".repeat(512) + "0" + "]".repeat(512)).toByteArray())
        assertFailsWith<WireContractException> {
            WireJson.parse(("[".repeat(513) + "0" + "]".repeat(513)).toByteArray())
        }
        val source = "[".repeat(20_000) + "0" + "]".repeat(20_000)
        assertFailsWith<WireDecodingException> { HealthResponse.codec.decode(source.toByteArray()) }
    }

    @Test
    fun `canonical JSON sorts recursively and pins escapes and literal Unicode`() {
        val source = """{"z":[{"z":null,"a":"é/😀﻿"}],"a":"\"\\\b\f\n\r\t\u0000\u001f"}"""
        val expected = """{"a":"\"\\\b\f\n\r\t\u0000\u001f","z":[{"a":"é/😀﻿","z":null}]}"""
        val bytes = WireJson.canonical(WireJson.parse(source.toByteArray()))
        assertContentEquals(expected.toByteArray(), bytes)
        assertTrue(bytes.last() != '\n'.code.toByte())
        val escaped = WireJson.parse("\"\\uD83D\\uDE00\\/\\uFEFF\"".toByteArray())
        assertContentEquals("\"😀/\uFEFF\"".toByteArray(), WireJson.canonical(escaped))
        val keys = WireValue.ObjectValue(mapOf("😀" to wireLong(1), "\uE000" to wireLong(2), "a" to wireLong(3)))
        assertContentEquals("""{"a":3,"":2,"😀":1}""".toByteArray(), WireJson.canonical(keys))
    }

    @Test
    fun `required nullable metadata cannot disappear`() {
        val bytes = User.codec.encode(user)
        assertTrue(String(bytes).contains("\"display_name\":null"))
        assertTrue(String(bytes).contains("\"disabled_at\":null"))
        for (key in listOf("display_name", "disabled_at")) {
            val objectValue = WireJson.parse(bytes) as WireValue.ObjectValue
            val changed = WireValue.ObjectValue(objectValue.fields - key)
            assertFailsWith<WireDecodingException> { User.codec.decode(WireJson.canonical(changed)) }
        }
    }

    @Test
    fun `patch omitted null and value stay distinct`() {
        val base = CreateUserRequest("alice", "a".repeat(12))
        for ((presence, expected) in listOf(
            OptionalValue.Omitted to """{"password":"aaaaaaaaaaaa","username":"alice"}""",
            OptionalValue.Null to """{"display_name":null,"password":"aaaaaaaaaaaa","username":"alice"}""",
            OptionalValue.Value("") to """{"display_name":"","password":"aaaaaaaaaaaa","username":"alice"}""",
            OptionalValue.Value("Alice") to """{"display_name":"Alice","password":"aaaaaaaaaaaa","username":"alice"}""",
        )) {
            val value = base.copy(displayName = presence)
            assertContentEquals(expected.toByteArray(), CreateUserRequest.codec.encode(value))
            assertEquals(value, CreateUserRequest.codec.decode(expected.toByteArray()))
        }
        assertFailsWith<WireEncodingException> { UpdateUserRequest.codec.encode(UpdateUserRequest()) }
        assertContentEquals("""{"disabled":false}""".toByteArray(), UpdateUserRequest.codec.encode(UpdateUserRequest(disabled = false)))
        for (source in listOf("""{"password":null}""", """{"disabled":null}""", """{"account_kind":null}""")) {
            assertFailsWith<WireDecodingException> { UpdateUserRequest.codec.decode(source.toByteArray()) }
        }
        assertEquals(OptionalValue.Null, UpdateUserRequest.codec.decode("""{"display_name":null}""".toByteArray()).displayName)
    }

    @Test
    fun `unions reject mixed partial foreign and null branches`() {
        for (source in listOf("""{"scope":"user","group_id":null}""", """{"scope":"group"}""",
            """{"scope":"group","group_id":null}""", """{"scope":"private"}""", """{"scope":"user","role":"viewer"}""")) {
            assertFailsWith<WireDecodingException> { PromptScope.codec.decode(source.toByteArray()) }
        }
        for (source in listOf("""{"role":"viewer"}""", """{"group_id":"$id"}""",
            """{"group_id":null,"role":"viewer"}""", """{"group_id":"$id","role":"owner"}""",
            """{"expires_in":null}""", """{"kind":"account"}""")) {
            assertFailsWith<WireDecodingException> { AdminInviteRequest.codec.decode(source.toByteArray()) }
        }
        assertEquals(AdminInviteRequest(InviteTarget.Account), AdminInviteRequest.codec.decode("{}".toByteArray()))
        val group = AdminInviteRequest(InviteTarget.Group(id, InviteRole.EDITOR), 604_800)
        assertEquals(group, AdminInviteRequest.codec.decode(AdminInviteRequest.codec.encode(group)))
    }

    @Test
    fun `constructed invalid DTOs fail encode including nested values`() {
        val failures = listOf<() -> ByteArray>(
            { HealthResponse.codec.encode(HealthResponse("bad", "1")) },
            { IDPath.codec.encode(IDPath("bad")) },
            { MemberPath.codec.encode(MemberPath(id, "bad")) },
            { RevisionPath.codec.encode(RevisionPath(id, 0)) },
            { LoginRequest.codec.encode(LoginRequest("Alice", "x", "phone")) },
            { RegisterRequest.codec.encode(RegisterRequest(token, "alice", "short", "phone")) },
            { PasswordChangeRequest.codec.encode(PasswordChangeRequest("", "a".repeat(12))) },
            { User.codec.encode(user.copy(disabledAt = "bad")) },
            { AuthResponse.codec.encode(AuthResponse(token, user.copy(id = "bad"))) },
            { Device.codec.encode(Device(id, "phone", time, "bad", null, true)) },
            { MeResponse.codec.encode(MeResponse(user, listOf(GroupMembership("bad", "group", Role.OWNER)), emptyList())) },
            { CreateUserRequest.codec.encode(CreateUserRequest("alice", "a".repeat(12), OptionalValue.Value("x".repeat(256)))) },
            { UpdateUserRequest.codec.encode(UpdateUserRequest(password = "short")) },
            { Group.codec.encode(Group(id, "group", "bad", time)) },
            { GroupMembership.codec.encode(GroupMembership(id, "", Role.VIEWER)) },
            { CreateGroupRequest.codec.encode(CreateGroupRequest("")) },
            { RenameGroupRequest.codec.encode(RenameGroupRequest("x".repeat(256))) },
            { Member.codec.encode(Member(id, "Alice", null, Role.EDITOR, time)) },
            { MembersResponse.codec.encode(MembersResponse(listOf(Member(id, "alice", null, Role.VIEWER, "bad")))) },
            { GroupInviteRequest.codec.encode(GroupInviteRequest(InviteRole.VIEWER, 0)) },
            { JoinGroupRequest.codec.encode(JoinGroupRequest("bad")) },
            { AdminInviteRequest.codec.encode(AdminInviteRequest(InviteTarget.Account, 604_801)) },
            { AdminInviteRequest.codec.encode(AdminInviteRequest(InviteTarget.Group("bad", InviteRole.VIEWER))) },
            { InviteResponse.codec.encode(InviteResponse(token, "bad", InviteTarget.Account)) },
            { PromptScope.codec.encode(PromptScope.Group("bad")) },
            { CreateGroupRequest.codec.encode(CreateGroupRequest("\uD800")) },
        )
        failures.forEach { assertFailsWith<WireEncodingException> { it() } }
    }

    @Test
    fun `scalar and byte bounds do not use UTF-16 length`() {
        assertEquals(255, WireValidation.scalarCount("😀".repeat(255)))
        CreateGroupRequest.codec.encode(CreateGroupRequest("😀".repeat(255)))
        assertFailsWith<WireEncodingException> { CreateGroupRequest.codec.encode(CreateGroupRequest("😀".repeat(256))) }
        PasswordChangeRequest.codec.encode(PasswordChangeRequest("é".repeat(36), "😀".repeat(12)))
        assertFailsWith<WireEncodingException> { PasswordChangeRequest.codec.encode(PasswordChangeRequest("é".repeat(37), "😀".repeat(12))) }
        assertFailsWith<WireEncodingException> { PasswordChangeRequest.codec.encode(PasswordChangeRequest("x", "😀".repeat(11))) }
        assertFailsWith<WireEncodingException> { PasswordChangeRequest.codec.encode(PasswordChangeRequest("x", "😀".repeat(19))) }
        WireValidation.path("é".repeat(512))
        assertFailsWith<WireContractException> { WireValidation.path("é".repeat(513)) }
        WireValidation.content("😀".repeat(65_536))
        assertFailsWith<WireContractException> { WireValidation.content("😀".repeat(65_537)) }
    }

    @Test
    fun `identifiers and regexes match the full spelling without normalization`() {
        WireValidation.ulid(id)
        WireValidation.uuid("12345678-1234-1234-abcd-123456789abc")
        WireValidation.scopeKey("user:$id")
        WireValidation.scopeKey("group:$id")
        for (invalid in listOf(id.lowercase(Locale.ROOT), "8" + id.drop(1), id + "\n", id.dropLast(1) + "I")) {
            assertFailsWith<WireContractException> { WireValidation.ulid(invalid) }
        }
        for (invalid in listOf("12345678-1234-1234-ABCD-123456789abc", "12345678-1234-1234-abcd-123456789abc\n")) {
            assertFailsWith<WireContractException> { WireValidation.uuid(invalid) }
        }
        for (invalid in listOf("alice\n", "Alice", "é", "_alice", "a".repeat(65))) {
            assertFailsWith<WireContractException> { WireValidation.username(invalid) }
        }
        for (invalid in listOf(token + "\n", "A".repeat(42) + "B", token + "=", "A".repeat(42))) {
            assertFailsWith<WireContractException> { WireValidation.token(invalid) }
        }
    }

    @Test
    fun `timestamps use strict proleptic Gregorian UTC milliseconds under any locale`() {
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("th-TH"))
            for (value in listOf("0001-01-01T00:00:00.000Z", "1582-10-10T00:00:00.000Z",
                "2000-02-29T12:34:56.789Z", "9999-12-31T23:59:59.999Z")) WireValidation.timestamp(value)
            for (value in listOf("0000-01-01T00:00:00.000Z", "10000-01-01T00:00:00.000Z",
                "1900-02-29T00:00:00.000Z", "2025-02-29T00:00:00.000Z", "2024-04-31T00:00:00.000Z",
                "2024-01-01T24:00:00.000Z", "2024-01-01T00:60:00.000Z", "2024-01-01T00:00:60.000Z",
                "2024-01-01T00:00:00Z", "2024-01-01T00:00:00.00Z", "2024-01-01T00:00:00.0000Z",
                "2024-01-01T00:00:00.000+00:00", time.lowercase(Locale.ROOT), time + "\n")) {
                assertFailsWith<WireContractException> { WireValidation.timestamp(value) }
            }
        } finally {
            Locale.setDefault(previous)
        }
    }

    @Test
    fun `diagnostics contain neither values nor parser causes`() {
        val secret = "private-secret-value"
        for (bytes in listOf("""{"username":"alice","password":"$secret","device_name":""}""".toByteArray(),
            """{"username":"alice","password":"$secret","device_name":tru}""".toByteArray())) {
            val failure = assertFailsWith<WireDecodingException> { LoginRequest.codec.decode(bytes) }
            assertEquals("Invalid LoginRequest contract.", failure.message)
            assertNull(failure.cause)
            assertTrue(!failure.stackTraceToString().contains(secret))
        }
        val failure = assertFailsWith<WireEncodingException> { LoginRequest.codec.encode(LoginRequest("Alice", secret, "phone")) }
        assertEquals("Invalid LoginRequest contract.", failure.message)
        assertNull(failure.cause)
        assertTrue(!failure.stackTraceToString().contains(secret))
    }
}
