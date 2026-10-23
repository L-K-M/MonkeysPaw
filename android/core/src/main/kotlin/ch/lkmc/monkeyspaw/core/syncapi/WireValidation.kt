package ch.lkmc.monkeyspaw.core.syncapi

import java.time.DateTimeException
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.chrono.IsoChronology
import java.time.format.DateTimeFormatter
import java.time.format.ResolverStyle
import java.util.Locale

internal object WireValidation {
    const val MAX_INVITE_TTL: Long = 604_800
    private const val MAX_NAME_SCALARS = 255
    private const val MAX_USERNAME_SCALARS = 64
    private const val MIN_PASSWORD_SCALARS = 12
    private const val MAX_PASSWORD_BYTES = 72
    private const val MAX_CONTENT_BYTES = 262_144
    private const val MAX_PATH_BYTES = 1_024
    private const val MAX_PROVIDER_SYNC_DOCUMENT_SCALARS = 349_600

    private val ulidPattern = Regex("[0-7][0-9A-HJKMNP-TV-Z]{25}")
    private val uuidPattern = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    private val scopeKeyPattern = Regex("(user|group):[0-7][0-9A-HJKMNP-TV-Z]{25}")
    private val usernamePattern = Regex("[a-z0-9][a-z0-9._-]{0,63}")
    private val tokenPattern = Regex("[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]")
    private val providerSyncDocumentPattern = Regex("[A-Za-z0-9_-]+")
    private val timestampPattern = Regex("(?!0000)[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z")
    private val timestampFormatter = DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT)
        .withChronology(IsoChronology.INSTANCE).withResolverStyle(ResolverStyle.STRICT).withZone(ZoneOffset.UTC)

    // JVM Strings can contain unpaired surrogates. Never silently replace them
    // while counting UTF-8 bytes or encoding a constructed DTO.
    fun scalarCount(text: String): Int {
        var count = 0
        var index = 0
        while (index < text.length) {
            val char = text[index++]
            wireRequire(!char.isLowSurrogate())
            if (char.isHighSurrogate()) {
                wireRequire(index < text.length && text[index].isLowSurrogate())
                index++
            }
            count++
        }
        return count
    }

    fun string(text: String, minimum: Int = 0, maximum: Int? = null, maximumBytes: Int? = null) {
        val count = scalarCount(text)
        wireRequire(count >= minimum && (maximum == null || count <= maximum))
        wireRequire(maximumBytes == null || text.toByteArray(Charsets.UTF_8).size <= maximumBytes)
    }

    fun ulid(text: String) { wireRequire(ulidPattern.matches(text)) }
    fun uuid(text: String) { wireRequire(uuidPattern.matches(text)) }
    fun scopeKey(text: String) { wireRequire(scopeKeyPattern.matches(text)) }
    fun token(text: String) { wireRequire(tokenPattern.matches(text)) }
    fun name(text: String) { string(text, minimum = 1, maximum = MAX_NAME_SCALARS) }
    fun displayName(text: String) { string(text, maximum = MAX_NAME_SCALARS) }
    fun nonempty(text: String) { string(text, minimum = 1) }
    fun username(text: String) {
        string(text, minimum = 1, maximum = MAX_USERNAME_SCALARS)
        wireRequire(usernamePattern.matches(text))
    }

    fun password(text: String) { string(text, minimum = MIN_PASSWORD_SCALARS, maximum = MAX_PASSWORD_BYTES, maximumBytes = MAX_PASSWORD_BYTES) }
    fun suppliedPassword(text: String) { string(text, minimum = 1, maximum = MAX_PASSWORD_BYTES, maximumBytes = MAX_PASSWORD_BYTES) }
    fun content(text: String) { string(text, maximumBytes = MAX_CONTENT_BYTES) }
    fun path(text: String) { string(text, minimum = 1, maximum = MAX_PATH_BYTES, maximumBytes = MAX_PATH_BYTES) }
    fun providerSyncDocument(text: String) {
        string(text, minimum = 1, maximum = MAX_PROVIDER_SYNC_DOCUMENT_SCALARS)
        wireRequire(providerSyncDocumentPattern.matches(text))
    }

    fun timestamp(text: String) {
        wireRequire(timestampPattern.matches(text))
        try {
            LocalDateTime.parse(text, timestampFormatter)
        } catch (_: DateTimeException) {
            throw WireContractException()
        }
    }
}
