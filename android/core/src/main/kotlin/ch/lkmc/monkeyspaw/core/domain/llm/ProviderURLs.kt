package ch.lkmc.monkeyspaw.core.domain.llm

import java.io.ByteArrayOutputStream
import java.net.URI
import java.net.URISyntaxException
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.Locale

/** URI.host rejects some Foundation host spellings; parse authority without DNS. */
internal object ProviderURLs {
    private data class Authority(val host: String, val port: Int?)
    private const val hex = "0123456789ABCDEF"
    private const val hostCharacters = "abcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;="
    private const val pathCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=:@/"

    fun normalize(raw: String, kind: ProviderKind): URI {
        val input = raw.trimProviderWhitespace()
        if (input.isEmpty() || '\\' in input || input.hasControls()) throw ProviderSettingsError.InvalidBaseURL
        val schemeEnd = input.indexOf("://")
        if (schemeEnd < 0) throw ProviderSettingsError.InvalidBaseURL
        val scheme = input.substring(0, schemeEnd).lowercase(Locale.ROOT)
        if (scheme != "http" && scheme != "https") throw ProviderSettingsError.InvalidBaseURL

        val start = schemeEnd + 3
        val authorityEnd = input.indexOfAny(charArrayOf('/', '?', '#'), start).let { if (it < 0) input.length else it }
        val authority = authority(input.substring(start, authorityEnd))
        if (input.indexOfAny(charArrayOf('?', '#'), authorityEnd) >= 0) throw ProviderSettingsError.QueryOrFragmentInURL
        if (scheme == "http" && !isLoopback(authority.host)) throw ProviderSettingsError.InsecureBaseURL

        val encodedPath = input.substring(authorityEnd)
        // Foundation exposes an undecodable UTF-8 path as empty; invalid literal % is escaped.
        var path = decodePercent(encodedPath).orEmpty()
        if ('\\' in path || "//" in path || path.hasControls() || path.split('/').any { it == "." || it == ".." } ||
            "%2f" in encodedPath.lowercase(Locale.ROOT)) {
            throw ProviderSettingsError.InvalidBaseURL
        }
        path = path.trimEnd('/')
        val suffixes = when (kind) {
            ProviderKind.ANTHROPIC -> listOf("/messages", "/models", "/v1")
            ProviderKind.OPENAI_COMPATIBLE -> listOf("/chat/completions", "/models")
        }
        while (true) {
            val suffix = suffixes.firstOrNull { path.endsWith(it) } ?: break
            path = path.dropLast(suffix.length)
        }
        if (kind == ProviderKind.OPENAI_COMPATIBLE && path.isEmpty()) path = "/v1"
        val port = authority.port?.takeUnless { it == if (scheme == "https") 443 else 80 }
        val host = if (authority.host.startsWith('[')) authority.host else encode(authority.host, hostCharacters)
        return try {
            URI("$scheme://$host${port?.let { ":$it" }.orEmpty()}${encode(path, pathCharacters)}")
        } catch (_: URISyntaxException) {
            throw ProviderSettingsError.InvalidBaseURL
        }
    }

    private fun authority(raw: String): Authority {
        if (raw.isEmpty()) throw ProviderSettingsError.InvalidBaseURL
        if ('@' in raw) throw ProviderSettingsError.CredentialsInURL
        val hostEnd = if (raw.startsWith('[')) {
            raw.indexOf(']').let { if (it < 0) throw ProviderSettingsError.InvalidBaseURL else it + 1 }
        } else raw.indexOf(':').let { if (it < 0) raw.length else it }
        val rawPort = raw.substring(hostEnd)
        if (rawPort.isNotEmpty() && (!rawPort.startsWith(':') || rawPort.drop(1).any { it !in '0'..'9' })) {
            throw ProviderSettingsError.InvalidBaseURL
        }
        val port = rawPort.drop(1).takeIf { it.isNotEmpty() }?.let {
            it.toIntOrNull()?.takeIf { number -> number in 1..65535 } ?: throw ProviderSettingsError.InvalidBaseURL
        }
        var host = decodePercent(raw.substring(0, hostEnd))?.lowercase(Locale.ROOT)
            ?: throw ProviderSettingsError.InvalidBaseURL
        if (host.endsWith('.')) host = host.dropLast(1)
        if (host.isEmpty() || '%' in host || host.any { it.code > 127 } || host.hasControls()) {
            throw ProviderSettingsError.InvalidBaseURL
        }
        if (host.startsWith('[')) {
            try {
                if (URI("http://$host").host == null) throw ProviderSettingsError.InvalidBaseURL
            } catch (_: URISyntaxException) {
                throw ProviderSettingsError.InvalidBaseURL
            }
        }
        return Authority(host, port)
    }

    fun isLoopback(host: String): Boolean {
        if (host == "localhost") return true
        val literal = if (host.startsWith('[') && host.endsWith(']')) host.substring(1, host.length - 1) else host
        if (':' in literal) {
            val halves = literal.split("::")
            val groups = if (halves.size == 2) {
                val left = if (halves[0].isEmpty()) emptyList() else halves[0].split(':')
                val right = if (halves[1].isEmpty()) emptyList() else halves[1].split(':')
                val missing = 8 - left.size - right.size
                if (missing <= 0) return false
                left + List(missing) { "0" } + right
            } else literal.split(':')
            if (groups.size != 8 || groups.any { it.isEmpty() || it.length > 4 || it.any { digit -> digit !in "0123456789abcdef" } }) return false
            return groups.dropLast(1).all { it.toInt(16) == 0 } && groups.last().toInt(16) == 1
        }
        val octets = host.split('.')
        return octets.size == 4 && octets[0] == "127" && octets.all {
            val number = it.toIntOrNull()
            number != null && number in 0..255 && number.toString() == it
        }
    }

    fun credentialOrigin(url: URI): String {
        val authority = authority(url.rawAuthority ?: throw ProviderSettingsError.InvalidBaseURL)
        return "${url.scheme}://${authority.host}:${authority.port ?: if (url.scheme == "https") 443 else 80}"
    }

    private fun decodePercent(value: String): String? {
        val bytes = ByteArrayOutputStream()
        var index = 0
        while (index < value.length) {
            val high = value.getOrNull(index + 1)?.takeIf { it in "0123456789abcdefABCDEF" }?.digitToIntOrNull(16)
            val low = value.getOrNull(index + 2)?.takeIf { it in "0123456789abcdefABCDEF" }?.digitToIntOrNull(16)
            if (value[index] == '%' && high != null && low != null) {
                bytes.write(high * 16 + low)
                index += 3
            } else {
                val end = index + Character.charCount(value.codePointAt(index))
                bytes.write(value.substring(index, end).toByteArray(Charsets.UTF_8))
                index = end
            }
        }
        return try {
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes.toByteArray())).toString()
        } catch (_: CharacterCodingException) {
            null
        }
    }

    private fun encode(value: String, allowed: String): String = buildString {
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val number = byte.toInt() and 255
            if (number < 128 && number.toChar() in allowed) append(number.toChar())
            else { append('%'); append(hex[number ushr 4]); append(hex[number and 15]) }
        }
    }
}
