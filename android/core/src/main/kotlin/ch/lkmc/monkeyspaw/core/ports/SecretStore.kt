package ch.lkmc.monkeyspaw.core.ports

import ch.lkmc.monkeyspaw.core.domain.llm.SecretAccount
import ch.lkmc.monkeyspaw.core.domain.llm.SecretReadSource
import ch.lkmc.monkeyspaw.core.domain.llm.SecretTier
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.domain.llm.StoredSecret

/** App-owned storage serializes account operations off UI and throws only SecretStoreError.
 * A failed mutation retains the old value. Delete is idempotent and affects persisted copies
 * only. Persisted reads support exact compensation; Android has no environment/file fallback.
 * Services must complete cancellation/deadlines even if a driver read remains blocked.
 */
interface SecretStore {
    suspend fun read(account: SecretAccount, source: SecretReadSource): StoredSecret?
    suspend fun write(value: SecretValue, account: SecretAccount): SecretTier
    suspend fun delete(account: SecretAccount)
}
