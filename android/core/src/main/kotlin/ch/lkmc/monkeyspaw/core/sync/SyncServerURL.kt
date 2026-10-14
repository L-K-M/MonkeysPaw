package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.llm.hasControls
import ch.lkmc.monkeyspaw.core.domain.llm.trimProviderWhitespace
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import com.ibm.icu.text.IDNA
import java.io.ByteArrayOutputStream
import java.nio.charset.CharacterCodingException
import java.util.Locale

sealed class SyncServerURLError private constructor(code: String) : Exception(code, null, false, true) {
    data object InvalidURL : SyncServerURLError("invalidURL")
    data object CredentialsInURL : SyncServerURLError("credentialsInURL")
    data object QueryOrFragmentInURL : SyncServerURLError("queryOrFragmentInURL")
    data object InsecureURL : SyncServerURLError("insecureURL")
    data object InvalidDeploymentPrefix : SyncServerURLError("invalidDeploymentPrefix")

    final override fun toString(): String = message.orEmpty()
}

/** Canonical deployment base without /api/v1. HTTP exemptions never consult DNS. */
class SyncServerURL(input: String) {
    private val components = parse(input, URLUse.DEPLOYMENT)
    val baseURL: String
    val apiURL: String get() = "$baseURL/api/v1"
    val usesPlaintextHTTP: Boolean get() = components.scheme == "http"

    init {
        var path = components.path.trimEnd('/')
        while (path.endsWith(apiSuffix)) path = path.dropLast(apiSuffix.length)
        baseURL = components.origin + encode(path, pathCharacters)
    }

    /** Drivers call this before dispatch, including anonymous requests. */
    fun validatedRequestURL(url: String): String {
        val request = try {
            parse(url, URLUse.REQUEST)
        } catch (error: SyncServerURLError) {
            throw when (error) {
                SyncServerURLError.CredentialsInURL -> HttpTransportError.CredentialsInURL
                SyncServerURLError.InsecureURL -> HttpTransportError.InsecureURL
                else -> HttpTransportError.InvalidURL
            }
        }
        if (request.origin != components.origin || !request.encodedPath.startsWith(apiURL.removePrefix(components.origin) + "/")) {
            throw HttpTransportError.ServerMismatch
        }
        return request.origin + request.encodedPath + request.query
    }

    override fun equals(other: Any?): Boolean = other is SyncServerURL && baseURL == other.baseURL
    override fun hashCode(): Int = baseURL.hashCode()
    override fun toString(): String = "<sync server URL>"

    private data class Components(val scheme: String, val origin: String, val path: String, val encodedPath: String, val query: String)
    private enum class URLUse { DEPLOYMENT, REQUEST }

    private companion object {
        const val apiSuffix = "/api/v1"
        const val hostCharacters = "abcdefghijklmnopqrstuvwxyz0123456789-_."
        const val pathCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=:@/"
        const val hex = "0123456789ABCDEF"
        val idna: IDNA = IDNA.getUTS46Instance(IDNA.NONTRANSITIONAL_TO_ASCII)

        fun parse(raw: String, use: URLUse): Components {
            val input = raw.trimProviderWhitespace()
            if (input.isEmpty() || '\\' in input || input.hasControls()) throw SyncServerURLError.InvalidURL
            try { input.encodeToByteArray(throwOnInvalidSequence = true) }
            catch (_: CharacterCodingException) { throw SyncServerURLError.InvalidURL }
            val schemeEnd = input.indexOf("://")
            if (schemeEnd < 0) throw SyncServerURLError.InvalidURL
            val scheme = input.substring(0, schemeEnd).lowercase(Locale.ROOT)
            if (scheme != "http" && scheme != "https") throw SyncServerURLError.InvalidURL

            val start = schemeEnd + 3
            val end = input.indexOfAny(charArrayOf('/', '?', '#'), start).let { if (it < 0) input.length else it }
            val authority = input.substring(start, end)
            val hostAndPort = authority.substringAfterLast('@')
            val hostEnd = if (hostAndPort.startsWith('[')) {
                hostAndPort.indexOf(']').let { if (it < 0) throw SyncServerURLError.InvalidURL else it + 1 }
            } else hostAndPort.indexOf(':').let { if (it < 0) hostAndPort.length else it }
            val rawHost = hostAndPort.substring(0, hostEnd)
            if (rawHost.isEmpty()) throw SyncServerURLError.InvalidURL
            val rawPort = hostAndPort.substring(hostEnd)
            if (rawPort.isNotEmpty() && (!rawPort.startsWith(':') || rawPort.drop(1).any { it !in '0'..'9' })) {
                throw SyncServerURLError.InvalidURL
            }
            val port = rawPort.drop(1).takeIf { it.isNotEmpty() }?.toIntOrNull()
            if (rawPort.length > 1 && port == null || port != null && port !in 1..65535) throw SyncServerURLError.InvalidURL
            if ('@' in authority) throw SyncServerURLError.CredentialsInURL
            if ((use == URLUse.DEPLOYMENT && input.indexOf('?', end) >= 0) || input.indexOf('#', end) >= 0) {
                throw SyncServerURLError.QueryOrFragmentInURL
            }
            if ('%' in authority) throw SyncServerURLError.InvalidURL

            var host = rawHost.lowercase(Locale.ROOT)
            val words = if (host.startsWith('[') && host.endsWith(']')) {
                ipv6(host.substring(1, host.length - 1)) ?: throw SyncServerURLError.InvalidURL
            } else null
            if (words != null) {
                host = "[${canonicalIPv6(words)}]"
            } else {
                // ICU is already pinned for portable Unicode; Java IDN uses an older mapping.
                if (host.any { it.code > 127 }) {
                    host = idna.nameToASCII(host, StringBuilder(), IDNA.Info()).toString()
                }
                host = host.removeSuffix(".")
                if (host.isEmpty() || host.endsWith('.') || ".." in host || host.any { it !in hostCharacters }) {
                    throw SyncServerURLError.InvalidURL
                }
            }
            if (scheme == "http" && (authority.any { it.code > 127 } || !allowsHTTP(host, words))) {
                throw SyncServerURLError.InsecureURL
            }
            val normalizedPort = if (port == null || port == if (scheme == "https") 443 else 80) "" else ":$port"

            val queryStart = input.indexOf('?', end).let { if (it < 0) input.length else it }
            val rawPath = input.substring(end, queryStart)
            val path = decodePercent(rawPath)
            if ('\\' in path || "//" in path || '%' in path || '?' in path || '#' in path || path.hasControls() ||
                path.split('/').any { it == "." || it == ".." } || rawPath.contains("%2f", ignoreCase = true)) {
                throw SyncServerURLError.InvalidDeploymentPrefix
            }
            val query = if (queryStart == input.length) "" else "?" + encode(input.substring(queryStart + 1), pathCharacters + "?%")
            return Components(scheme, "$scheme://$host$normalizedPort", path, encode(path, pathCharacters), query)
        }

        fun allowsHTTP(host: String, words: List<Int>?): Boolean {
            if (host == "localhost") return true
            if (words != null) return words.dropLast(1).all { it == 0 } && words.last() == 1 || words[0] and 0xfe00 == 0xfc00
            val bytes = ipv4(host) ?: return false
            return bytes[0] == 127 || bytes[0] == 10 || bytes[0] == 172 && bytes[1] in 16..31 || bytes[0] == 192 && bytes[1] == 168
        }

        fun ipv4(text: String): List<Int>? {
            val parts = text.split('.')
            if (parts.size != 4) return null
            return parts.map { part ->
                val value = part.toIntOrNull() ?: return null
                if (part.any { it !in '0'..'9' } || value !in 0..255 || value.toString() != part) return null
                value
            }
        }

        fun ipv6(raw: String): List<Int>? {
            var text = raw
            if ('.' in text) {
                val separator = text.lastIndexOf(':')
                if (separator < 0) return null
                val bytes = ipv4(text.substring(separator + 1)) ?: return null
                text = text.substring(0, separator + 1) + ((bytes[0] shl 8) or bytes[1]).toString(16) + ":" +
                    ((bytes[2] shl 8) or bytes[3]).toString(16)
            }
            val halves = text.split("::")
            if (halves.size > 2) return null
            fun words(part: String): List<Int>? {
                if (part.isEmpty()) return emptyList()
                return part.split(':').map {
                    if (it.length !in 1..4 || it.any { digit -> digit !in "0123456789abcdef" }) return null
                    it.toInt(16)
                }
            }
            val left = words(halves[0]) ?: return null
            if (halves.size == 1) return left.takeIf { it.size == 8 }
            val right = words(halves[1]) ?: return null
            if (left.size + right.size >= 8) return null
            return left + List(8 - left.size - right.size) { 0 } + right
        }

        fun canonicalIPv6(words: List<Int>): String {
            var bestStart = 0
            var bestCount = 0
            var index = 0
            while (index < words.size) {
                if (words[index] != 0) { index++; continue }
                val start = index
                while (index < words.size && words[index] == 0) index++
                if (index - start > bestCount) { bestStart = start; bestCount = index - start }
            }
            val text = words.map { it.toString(16) }
            if (bestCount < 2) return text.joinToString(":")
            return text.take(bestStart).joinToString(":") + "::" + text.drop(bestStart + bestCount).joinToString(":")
        }

        fun decodePercent(value: String): String {
            val bytes = ByteArrayOutputStream()
            var index = 0
            while (index < value.length) {
                if (value[index] == '%') {
                    val high = value.getOrNull(index + 1)?.takeIf { it in "0123456789abcdefABCDEF" }?.digitToIntOrNull(16)
                    val low = value.getOrNull(index + 2)?.takeIf { it in "0123456789abcdefABCDEF" }?.digitToIntOrNull(16)
                    if (high == null || low == null) throw SyncServerURLError.InvalidDeploymentPrefix
                    bytes.write(high * 16 + low)
                    index += 3
                } else {
                    val end = index + Character.charCount(value.codePointAt(index))
                    bytes.write(value.substring(index, end).toByteArray(Charsets.UTF_8))
                    index = end
                }
            }
            return try { bytes.toByteArray().decodeToString(throwOnInvalidSequence = true) }
            catch (_: CharacterCodingException) { throw SyncServerURLError.InvalidDeploymentPrefix }
        }

        fun encode(value: String, allowed: String): String = buildString {
            for (byte in value.toByteArray(Charsets.UTF_8)) {
                val number = byte.toInt() and 255
                if (number < 128 && number.toChar() in allowed) append(number.toChar())
                else { append('%'); append(hex[number ushr 4]); append(hex[number and 15]) }
            }
        }
    }
}
