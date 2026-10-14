package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.llm.AssistantClient
import ch.lkmc.monkeyspaw.core.llm.AssistantModelList
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import ch.lkmc.monkeyspaw.core.ports.MonotonicClock
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.time.Duration.Companion.nanoseconds
import kotlinx.coroutines.*

/** Explicit, read-only Test intent. Clients and this service must share the monotonic time base.
 * IO owns credential resolution and list processing; completion owns the timer and callbacks.
 * Supply a dispatch-capable completion executor independent of potentially blocking IO.
 */
class AssistantConnectionService(
    private val providerSettings: ProviderSettingsService,
    private val anthropic: AssistantClient,
    private val openAICompatible: AssistantClient,
    private val io: CoroutineDispatcher,
    private val completion: CoroutineDispatcher,
    private val clock: MonotonicClock = MonotonicClock(System::nanoTime),
) {
    /** The caller cancels this handle on edit, navigation departure or destruction. */
    fun testConnection(draft: ProviderDraft, onComplete: (ConnectionTestResult) -> Unit): AssistantConnectionTest {
        val deadline = clock.nowNanos() + Limits.modelListTimeoutNanos
        val test = AssistantConnectionTest(completion, onComplete)
        test.scope.launch(completion) {
            while (true) {
                val remaining = deadline - clock.nowNanos()
                if (remaining <= 0) break
                delay(remaining.nanoseconds)
            }
            test.finish(ConnectionTestResult.Timeout)
        }
        test.scope.launch(io) {
            try {
                checkActive(deadline)
                val connection = providerSettings.resolveForTesting(draft)
                checkActive(deadline)
                val client = if (connection.kind == ProviderKind.ANTHROPIC) anthropic else openAICompatible
                test.finish(ConnectionTestResult.Ok(models(connection, client, deadline)))
            } catch (error: Exception) {
                test.finish(failure(error))
            }
        }
        return test
    }

    private suspend fun models(connection: ProviderConnection, client: AssistantClient, deadline: Long): List<ModelDescriptor> {
        val models = mutableMapOf<String, ModelDescriptor>()
        val cursors = mutableSetOf<String>()
        var afterID: String? = null
        var count = 0
        var bytes = 0L
        repeat(Limits.modelListPageCap) {
            checkActive(deadline)
            val page = client.listModels(connection, afterID, deadline)
            checkActive(deadline)
            if (page.models.size > Limits.modelListEntryCap - count) throw AssistantError.InvalidOutput
            count += page.models.size
            for (cursor in listOfNotNull(page.firstID, page.lastID)) {
                bytes += cursor.encodeToByteArray(throwOnInvalidSequence = true).size
            }
            if (bytes > Limits.modelListByteCap) throw AssistantError.InvalidOutput
            for (model in page.models) {
                if (!AssistantModelList.validID(model.id)) throw AssistantError.InvalidOutput
                bytes += model.id.encodeToByteArray(throwOnInvalidSequence = true).size.toLong() +
                    (model.displayName?.encodeToByteArray(throwOnInvalidSequence = true)?.size ?: 0)
                if (bytes > Limits.modelListByteCap) throw AssistantError.InvalidOutput
                val names = listOfNotNull(models[model.id]?.displayName, model.displayName)
                models[model.id] = ModelDescriptor(model.id, names.minWithOrNull(utf8Order))
            }
            if (!page.hasMore) {
                val sorted = models.values.sortedWith { a, b -> utf8Order.compare(a.id, b.id) }
                checkActive(deadline)
                return sorted
            }
            val cursor = page.lastID
            if (page.models.isEmpty() || cursor == null || !AssistantModelList.validID(cursor) || !cursors.add(cursor)) {
                throw AssistantError.InvalidOutput
            }
            afterID = cursor
        }
        throw AssistantError.InvalidOutput
    }

    private suspend fun checkActive(deadline: Long) {
        currentCoroutineContext().ensureActive()
        if (deadline - clock.nowNanos() <= 0) throw AssistantError.Transport(HttpTransportError.DeadlineExceeded)
    }

    private fun failure(error: Exception): ConnectionTestResult = when (error) {
        is ProviderSettingsError -> ConnectionTestResult.Settings(error)
        is CancellationException -> ConnectionTestResult.Cancelled
        AssistantError.Authentication -> ConnectionTestResult.Authentication
        AssistantError.ModelNotFound -> ConnectionTestResult.NotFound
        is AssistantError.RateLimited -> ConnectionTestResult.RateLimited(error.retryAfterSeconds)
        AssistantError.Overloaded -> ConnectionTestResult.ProviderFailure(529)
        is AssistantError.ProviderFailure -> if (error.statusCode in listOf(405, 501)) ConnectionTestResult.UnsupportedListing
            else ConnectionTestResult.ProviderFailure(error.statusCode)
        is AssistantError.Transport -> when (error.error) {
            HttpTransportError.Cancelled -> ConnectionTestResult.Cancelled
            HttpTransportError.DeadlineExceeded -> ConnectionTestResult.Timeout
            HttpTransportError.NetworkFailure, HttpTransportError.RedirectRefused -> ConnectionTestResult.Network
            else -> ConnectionTestResult.InvalidResponse
        }
        is AssistantError -> ConnectionTestResult.InvalidResponse
        else -> ConnectionTestResult.Network
    }

    private val utf8Order = Comparator<String> { a, b ->
        val left = a.encodeToByteArray(throwOnInvalidSequence = true)
        val right = b.encodeToByteArray(throwOnInvalidSequence = true)
        var order = 0
        for (i in 0 until minOf(left.size, right.size)) {
            order = (left[i].toInt() and 255).compareTo(right[i].toInt() and 255)
            if (order != 0) break
        }
        if (order == 0) left.size.compareTo(right.size) else order
    }

    override fun toString(): String = "<assistant connection service>"
}

/** Completion is claimed before dispatch. Cancellation never joins a blocked native read. */
class AssistantConnectionTest internal constructor(
    private val completion: CoroutineDispatcher,
    onComplete: (ConnectionTestResult) -> Unit,
) {
    private val lock = Any()
    private var callback: ((ConnectionTestResult) -> Unit)? = onComplete
    internal val scope = CoroutineScope(SupervisorJob())

    fun cancel() = finish(ConnectionTestResult.Cancelled)

    internal fun finish(result: ConnectionTestResult) {
        val callback = synchronized(lock) { this.callback?.also { this.callback = null } } ?: return
        scope.cancel()
        // The callback survives cancellation of the worker/timer scope, including queued completion.
        completion.dispatch(EmptyCoroutineContext, Runnable { callback(result) })
    }

    override fun toString(): String = "<assistant connection test>"
}
