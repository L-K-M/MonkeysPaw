package ch.lkmc.monkeyspaw.core.domain.llm

/** Storage tier only; a driver must separately establish StrongBox/hardware backing. */
enum class SecretTier(val rawValue: String) { KEYSTORE("keystore") }

data class SecretAccount(val namespace: String, val name: String) {
    init {
        if (namespace.isEmpty() || name.isEmpty() || (namespace + name).any { it !in accountCharacters }) {
            throw SecretStoreError.InvalidAccount
        }
    }

    val rawValue: String get() = "$namespace:$name"

    companion object {
        private const val accountCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."

        fun provider(id: ProviderProfileID): SecretAccount = SecretAccount("provider", id.rawValue)

        fun device(id: java.util.UUID): SecretAccount = SecretAccount("device", id.toString())

        fun parse(value: String): SecretAccount {
            val parts = value.split(':')
            if (parts.size != 2) throw SecretStoreError.InvalidAccount
            return SecretAccount(parts[0], parts[1])
        }
    }
}

/** No serializer or raw-value property. Unwrap only at storage/request boundaries. */
class SecretValue(private val value: String) {
    fun <T> withValue(body: (String) -> T): T = body(value)

    override fun equals(other: Any?): Boolean = other is SecretValue && value == other.value
    override fun hashCode(): Int = value.hashCode()
    override fun toString(): String = "<secret redacted>"
}

data class StoredSecret(val value: SecretValue, val tier: SecretTier) {
    override fun toString(): String = "<stored secret redacted>"
}

enum class SecretReadSource { EFFECTIVE, PERSISTED }

/** No paths, input, secret value or underlying driver cause. */
sealed class SecretStoreError private constructor(code: String) : Exception(code, null, false, true) {
    data object InvalidAccount : SecretStoreError("invalidAccount")
    data object Unavailable : SecretStoreError("unavailable")
    data object Locked : SecretStoreError("locked")
    data object ReadOnly : SecretStoreError("readOnly")
    data object ReadFailed : SecretStoreError("readFailed")
    data object WriteFailed : SecretStoreError("writeFailed")
    data object DeleteFailed : SecretStoreError("deleteFailed")

    final override fun toString(): String = message.orEmpty()
}
