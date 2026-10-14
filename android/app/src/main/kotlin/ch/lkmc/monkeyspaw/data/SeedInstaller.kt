package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.services.LibraryError
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

internal data class SeedSummary(val seededCount: Int = 0, val skippedExistingCount: Int = 0)
internal data class SeedInstallResult(val summary: SeedSummary, val error: Exception? = null)

/** One local-library decision. Serialized with the shared repository; no batch rollback or retry. */
internal class SeedInstaller(
    private val repository: LibraryRepository,
    private val settings: AndroidSettingsStore,
    private val catalog: AndroidSeedCatalog,
    private val io: CoroutineDispatcher,
) {
    private val mutex = Mutex()

    suspend fun shouldOffer(): Boolean = withContext(io) {
        mutex.withLock {
            if (settings.read().seedProgress != SeedProgress.NOT_OFFERED) return@withLock false
            val empty = repository.withLibrary { library, _ -> library.entries().isEmpty() }
            // Seeing an existing library completes this step, even if its prompts are later deleted.
            if (!empty) settings.setSeedProgress(SeedProgress.COMPLETE)
            empty
        }
    }

    suspend fun decline(): Unit = withContext(io) {
        mutex.withLock {
            if (settings.read().seedProgress == SeedProgress.NOT_OFFERED) settings.setSeedProgress(SeedProgress.DECLINED)
        }
    }

    suspend fun install(): SeedInstallResult = withContext(io) {
        mutex.withLock {
            var seeded = 0
            var skipped = 0
            try {
                if (settings.read().seedProgress != SeedProgress.NOT_OFFERED) return@withLock SeedInstallResult(SeedSummary())
                // Persist before any first save. Failure or cancellation leaves an absorbing INSTALLING state.
                settings.setSeedProgress(SeedProgress.INSTALLING)
                repository.withLibrary { library, _ ->
                    // Includes invalid prompts and rechecks a library that changed after the offer.
                    if (library.entries().isNotEmpty()) return@withLibrary
                    for (seed in catalog.prompts()) {
                        val document = PromptCodec.parseFile(seed.bytes, seed.relativePath.substringAfterLast('/'))
                        try {
                            library.create(document, seed.relativePath)
                            seeded += 1
                        } catch (_: LibraryError.DestinationOccupied) {
                            skipped += 1
                        }
                    }
                }
                settings.setSeedProgress(SeedProgress.COMPLETE)
                SeedInstallResult(SeedSummary(seeded, skipped))
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                val failure = when (error) {
                    is StoreError, is LibraryError -> error
                    else -> LibraryError.OperationFailed
                }
                SeedInstallResult(SeedSummary(seeded, skipped), failure)
            }
        }
    }
}
