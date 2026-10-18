package ch.lkmc.monkeyspaw.data

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ListenableWorker.Result
import androidx.work.WorkerParameters
import dagger.Lazy
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.CancellationException
import java.util.UUID

@HiltWorker
internal class SyncWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted parameters: WorkerParameters,
    private val scheduler: Lazy<SyncWorkScheduler>,
) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result = syncWorkerResult(inputData, scheduler)
}

/** Keep validation, dispatch and returned Data on one JVM-testable production path. */
internal suspend fun syncWorkerResult(input: Data, scheduler: Lazy<SyncWorkScheduler>): Result {
    val generation = input.getString(AndroidSyncWorkQueue.GENERATION) ?: return Result.failure()
    val version = if (input.keyValueMap.containsKey(AndroidSyncWorkQueue.VERSION))
        input.getLong(AndroidSyncWorkQueue.VERSION, -1).takeIf { it > 0 } ?: return Result.failure() else null
    if (runCatching { UUID.fromString(generation).toString() == generation }.getOrDefault(false).not()) return Result.failure()
    return try {
        scheduler.get().dispatch(SyncWorkRequest(generation, version))
        // Reports preserve offline/partial/401 outcomes; retries use our persisted, capped due policy.
        Result.success()
    } catch (error: CancellationException) { throw error }
    catch (_: Exception) { Result.failure() }
}
