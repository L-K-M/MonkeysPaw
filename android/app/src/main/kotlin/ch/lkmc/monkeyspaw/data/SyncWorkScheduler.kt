package ch.lkmc.monkeyspaw.data

import android.content.Context
import androidx.work.*
import ch.lkmc.monkeyspaw.core.domain.sync.SyncExecutionMode
import dagger.Lazy
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

/** Hooks belong to the authenticated graph, never the local Library/IME dependency graph. */
internal interface SyncWorkHooks {
    suspend fun authenticationStopped(): Boolean = false
    suspend fun authenticated(connection: String) {}
    suspend fun signedOut() {}
    suspend fun saved() {}
    suspend fun changed() {}
    data object None : SyncWorkHooks
}

/** Construction performs no IO and does not initialize WorkManager or the authenticated graph. */
internal class SyncWorkScheduler(private val policy: SyncWorkPolicy, private val io: CoroutineDispatcher) : SyncWorkHooks {
    suspend fun enter(owner: SyncForegroundOwner) = withContext(io) { policy.enter(owner) }
    suspend fun leave(owner: SyncForegroundOwner) = withContext(io) { policy.leave(owner) }
    suspend fun dispatch(request: SyncWorkRequest) = withContext(io) { policy.dispatch(request) }
    override suspend fun authenticated(connection: String) = withContext(io) { policy.authenticated(connection) }
    override suspend fun signedOut() = withContext(io) { policy.signedOut() }
    override suspend fun authenticationStopped() = withContext(io) { policy.authenticationStopped() }
    override suspend fun saved() = withContext(io) { policy.saved() }
    override suspend fun changed() = withContext(io) { policy.changed() }
}

internal class AndroidSyncWorkSession(private val startup: AndroidSyncStartup,
    private val repository: Lazy<AndroidSyncRepository>) : SyncWorkSession {
    override suspend fun connection() = startup.metadata().enabledConnectionID()?.toString()
    override suspend fun resume() { repository.get().resume() }
    override suspend fun requireSignIn() { repository.get().requireSignIn() }
    override suspend fun mode(value: SyncExecutionMode) { repository.get().setExecutionMode(value) }
    override suspend fun restoreEligibility(retries: Int, dueAt: Long) { repository.get().restoreWorkEligibility(retries, dueAt) }
    override fun facts(): SyncWorkFacts? {
        return repository.get().workFacts()
    }
    override suspend fun run(epoch: Long, version: Long?) { repository.get().runBackground(epoch, version) }
}

/** KEEP deduplicates periodic registration; appending one successor cannot cancel a running pass. */
internal class AndroidSyncWorkQueue(private val context: Context) : SyncWorkQueue {
    private fun manager() = WorkManager.getInstance(context)

    override suspend fun periodic(generation: String, intervalMillis: Long) {
        val request = PeriodicWorkRequestBuilder<SyncWorker>(intervalMillis, TimeUnit.MILLISECONDS)
            .setConstraints(connected()).setInputData(input(SyncWorkRequest(generation))).addTag(tag(generation)).build()
        manager().enqueueUniquePeriodicWork("sync-periodic-$generation", ExistingPeriodicWorkPolicy.KEEP, request).await()
    }

    override suspend fun once(request: SyncWorkRequest) {
        val builder = OneTimeWorkRequestBuilder<SyncWorker>().setConstraints(connected()).setInputData(input(request))
            .addTag(tag(request.generation))
        if (request.delayMillis > 0) builder.setInitialDelay(request.delayMillis, TimeUnit.MILLISECONDS)
        else if (request.expedited) builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
        manager().enqueueUniqueWork("sync-once-${request.generation}", ExistingWorkPolicy.APPEND_OR_REPLACE, builder.build()).await()
    }

    override suspend fun cancel(generation: String) { manager().cancelAllWorkByTag(tag(generation)).await() }

    private fun connected() = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
    private fun tag(generation: String) = "sync-$generation"

    companion object {
        const val GENERATION = "generation"
        const val VERSION = "version"

        /** OS requests and privacy tests use the same encoder. */
        internal fun input(request: SyncWorkRequest) = Data.Builder().putString(GENERATION, request.generation).apply {
            request.version?.let { putLong(VERSION, it) }
        }.build()
    }
}
