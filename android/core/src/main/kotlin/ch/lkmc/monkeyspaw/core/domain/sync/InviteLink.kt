package ch.lkmc.monkeyspaw.core.domain.sync

import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.domain.llm.hasControls
import ch.lkmc.monkeyspaw.core.sync.SyncServerURL
import ch.lkmc.monkeyspaw.core.sync.SyncServerURLError
import ch.lkmc.monkeyspaw.core.syncapi.WireValidation
import java.nio.charset.CharacterCodingException
import java.util.Locale

internal sealed class InviteLinkError(message: String) : Exception(message, null, false, true) {
    data object InvalidLink : InviteLinkError("Enter a valid invite link or token.")
    data object ServerRequired : InviteLinkError("Select the server explicitly before entering a bare invite token.")

    final override fun toString(): String = "<invite link error redacted>"
}

/** Untrusted bearer input. No serializer, diagnostic URL or plain token property. */
internal class InviteLink(input: String, explicitServer: String? = null) {
    val server: SyncServerURL
    val token: SecretValue

    init {
        if (':' !in input) {
            validateToken(input)
            if (explicitServer.isNullOrEmpty()) throw InviteLinkError.ServerRequired
            server = destination(explicitServer)
            token = SecretValue(input)
        } else {
            val separator = input.indexOf('?')
            if (separator < 0 || input.substring(0, separator).lowercase(Locale.ROOT) != "monkeyspaw://join" ||
                '\\' in input || '#' in input || input.hasControls() || input.any { it.isWhitespace() || Character.isSpaceChar(it) }) {
                throw InviteLinkError.InvalidLink
            }
            val values = mutableMapOf<String, String>()
            for (item in input.substring(separator + 1).split('&')) {
                val pair = item.split('=', limit = 2)
                if (pair.size != 2 || pair[0] !in setOf("server", "token") || pair[0] in values) throw InviteLinkError.InvalidLink
                val value = decode(pair[1])
                if (value.isEmpty()) throw InviteLinkError.InvalidLink
                values[pair[0]] = value
            }
            if (values.size != 2) throw InviteLinkError.InvalidLink
            val supplied = values.getValue("token")
            validateToken(supplied)
            server = destination(values.getValue("server"))
            token = SecretValue(supplied)
        }
    }

    override fun equals(other: Any?): Boolean = other is InviteLink && server == other.server && token == other.token
    override fun hashCode(): Int = 31 * server.hashCode() + token.hashCode()
    override fun toString(): String = "<invite link redacted>"

    private companion object {
        fun validateToken(value: String) {
            try { WireValidation.token(value) }
            catch (_: IllegalArgumentException) { throw InviteLinkError.InvalidLink }
        }

        fun destination(value: String): SyncServerURL = try { SyncServerURL(value) }
        catch (_: SyncServerURLError) { throw InviteLinkError.InvalidLink }

        fun decode(value: String): String {
            val source = try { value.encodeToByteArray(throwOnInvalidSequence = true) }
            catch (_: CharacterCodingException) { throw InviteLinkError.InvalidLink }
            val decoded = ByteArray(source.size)
            var input = 0
            var output = 0
            while (input < source.size) {
                if (source[input] == '%'.code.toByte()) {
                    val high = source.getOrNull(input + 1)?.toInt()?.toChar()?.let(::hex)
                    val low = source.getOrNull(input + 2)?.toInt()?.toChar()?.let(::hex)
                    if (high == null || low == null) throw InviteLinkError.InvalidLink
                    decoded[output++] = (high * 16 + low).toByte()
                    input += 3
                } else {
                    decoded[output++] = source[input++]
                }
            }
            // '+' is literal. A decoded '%' is not interpreted again by this parser.
            return try { decoded.decodeToString(0, output, throwOnInvalidSequence = true) }
            catch (_: CharacterCodingException) { throw InviteLinkError.InvalidLink }
        }

        fun hex(char: Char): Int? = when (char) {
            in '0'..'9' -> char - '0'
            in 'a'..'f' -> char - 'a' + 10
            in 'A'..'F' -> char - 'A' + 10
            else -> null
        }
    }
}
