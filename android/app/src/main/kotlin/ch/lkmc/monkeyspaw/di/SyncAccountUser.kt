package ch.lkmc.monkeyspaw.di

import ch.lkmc.monkeyspaw.core.domain.ULID

/** Resolves the persisted sync account identity on IO; null when signed out. */
internal fun interface SyncAccountUser {
    suspend fun userID(): ULID?
}
