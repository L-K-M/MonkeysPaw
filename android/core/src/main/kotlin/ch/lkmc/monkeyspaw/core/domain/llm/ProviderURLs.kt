package ch.lkmc.monkeyspaw.core.domain.llm

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.Locale

/** Canonical URL strings preserve Foundation spellings that java.net.URI cannot represent. */
internal object ProviderURLs {
    private data class Authority(val host: String, val port: Long?, val rawPort: String, val hasUserInfo: Boolean)
    private const val hex = "0123456789ABCDEF"
    private const val hostCharacters = "abcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;="
    private const val pathCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=:@/"

    fun normalize(raw: String, kind: ProviderKind): String {
        val input = raw.trimProviderWhitespace()
        if (input.isEmpty() || '\\' in input || input.hasControls()) throw ProviderSettingsError.InvalidBaseURL
        val schemeEnd = input.indexOf("://")
        if (schemeEnd < 0) throw ProviderSettingsError.InvalidBaseURL
        val scheme = input.substring(0, schemeEnd).lowercase(Locale.ROOT)
        if (scheme != "http" && scheme != "https") throw ProviderSettingsError.InvalidBaseURL

        val start = schemeEnd + 3
        val authorityEnd = input.indexOfAny(charArrayOf('/', '?', '#'), start).let { if (it < 0) input.length else it }
        val authority = authority(input.substring(start, authorityEnd))
        if (authority.hasUserInfo) throw ProviderSettingsError.CredentialsInURL
        if (input.indexOfAny(charArrayOf('?', '#'), authorityEnd) >= 0) throw ProviderSettingsError.QueryOrFragmentInURL
        val host = authority.host.lowercase(Locale.ROOT).removeSuffix(".")
        if (host.isEmpty() || '%' in host || host.any { it.code > 127 } || (authority.port != null && authority.port !in 1L..65535L)) {
            throw ProviderSettingsError.InvalidBaseURL
        }
        if (scheme == "http" && !isLoopback(host)) throw ProviderSettingsError.InsecureBaseURL

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
        val bracketed = host.startsWith('[') && host.endsWith(']')
        val hostValue = if (bracketed) host.substring(1, host.length - 1) else host
        val allowed = if (bracketed) hostCharacters + ":" else hostCharacters
        if (hostValue.any { it !in allowed }) throw ProviderSettingsError.InvalidBaseURL
        val port = when {
            authority.port == (if (scheme == "https") 443L else 80L) -> ""
            authority.port != null -> ":${authority.port}"
            authority.rawPort == ":" && !bracketed -> ""
            else -> authority.rawPort
        }
        return "$scheme://$host$port${encode(path, pathCharacters)}"
    }

    private fun authority(raw: String): Authority {
        if (raw.isEmpty()) throw ProviderSettingsError.InvalidBaseURL
        val hostAndPort = raw.substringAfterLast('@')
        val hostEnd = if (hostAndPort.startsWith('[')) {
            hostAndPort.indexOf(']').let { if (it < 0) throw ProviderSettingsError.InvalidBaseURL else it + 1 }
        } else hostAndPort.indexOf(':').let { if (it < 0) hostAndPort.length else it }
        val rawHost = hostAndPort.substring(0, hostEnd)
        if (rawHost.isEmpty()) throw ProviderSettingsError.InvalidBaseURL
        val bracketed = rawHost.startsWith('[') && rawHost.endsWith(']')
        val rawHostValue = if (bracketed) rawHost.substring(1, rawHost.length - 1) else rawHost
        val allowed = hostCharacters + "ABCDEFGHIJKLMNOPQRSTUVWXYZ%" + if (bracketed) ":" else ""
        if (rawHostValue.any { it.code < 128 && it !in allowed }) throw ProviderSettingsError.InvalidBaseURL
        val rawPort = hostAndPort.substring(hostEnd)
        if (rawPort.isNotEmpty() && (!rawPort.startsWith(':') || rawPort.drop(1).any { it !in '0'..'9' })) {
            throw ProviderSettingsError.InvalidBaseURL
        }
        // Foundation keeps a numeric port lexeme when it overflows its 64-bit Int.
        val port = rawPort.drop(1).takeIf { it.isNotEmpty() }?.toLongOrNull()
        val host = decodePercent(rawHost)
            ?: throw ProviderSettingsError.InvalidBaseURL
        return Authority(host, port, rawPort, '@' in raw)
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

    fun credentialOrigin(url: String): String {
        val scheme = url.substringBefore("://")
        val authority = authority(url.substringAfter("://").substringBefore('/'))
        return "$scheme://${authority.host}:${authority.port ?: if (scheme == "https") 443 else 80}"
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
