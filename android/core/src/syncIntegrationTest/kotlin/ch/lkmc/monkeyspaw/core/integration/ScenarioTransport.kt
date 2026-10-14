package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import ch.lkmc.monkeyspaw.data.OkHttpHttpTransport
import kotlinx.coroutines.*
import java.net.URI

/** Mutations wrap the unchanged HTTP driver; traces always describe the actual server response. */
internal class ScenarioTransport : HttpTransport {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val driver = OkHttpHttpTransport(MonotonicClock(System::nanoTime), scope)
    private val lock = Any()
    var library: DiskSyncFiles? = null
    private var online = true
    private data class Patch(val response: Boolean, val method: String, val path: String, val fields: Map<String, WireValue>)
    private data class Hook(val after: Boolean, val method: String, val path: String, var skip: Long, val run: suspend () -> Unit)
    private data class Interruption(val after: Boolean, val method: String, val path: String)
    internal class Trace(val method: String, val path: String, val status: Int, val body: WireValue?,
                         val localPaths: List<String>, val pull: PullResponse?, val responseBytes: Int)
    private val recorded = mutableListOf<Trace>()
    private val patches = mutableListOf<Patch>()
    private val hooks = mutableListOf<Hook>()
    private val interruptions = mutableListOf<Interruption>()
    private var failure: ScenarioFailure? = null
    val traces: List<Trace> get() = synchronized(lock) { recorded.toList() }
    val pending: Int get() = synchronized(lock) { patches.size + hooks.size + interruptions.size }
    val mutationFailure: ScenarioFailure? get() = synchronized(lock) { failure }
    fun resetMetrics() = synchronized(lock) { recorded.clear() }
    fun network(online: Boolean) = synchronized(lock) { this.online = online }
    fun patch(response: Boolean, method: String, path: String, fields: Map<String, WireValue>) = synchronized(lock) {
        patches.add(Patch(response, method, path, fields))
    }
    fun hook(after: Boolean, method: String, path: String, skip: Long = 0, run: suspend () -> Unit) = synchronized(lock) {
        hooks.add(Hook(after, method, path, skip, run))
    }
    fun interrupt(after: Boolean, method: String, path: String) = synchronized(lock) {
        interruptions.add(Interruption(after, method, path))
    }

    override suspend fun send(request: HttpRequest): HttpResponse = try {
        sendReal(request)
    } catch (error: ScenarioFailure) {
        synchronized(lock) { if (failure == null) failure = error }
        throw error
    }

    private suspend fun sendReal(request: HttpRequest): HttpResponse {
        currentCoroutineContext().ensureActive()
        val uri = URI(request.url)
        val path = uri.rawPath + (uri.rawQuery?.let { "?$it" } ?: "")
        val method = request.method.rawValue
        takeHook(false, method, path)?.let { runHook(it) }
        val requestPatch = takePatch(false, method, path)
        val responsePatch = takePatch(true, method, path)
        val bytes = if (requestPatch == null) request.body else {
            val original = request.body ?: throw ScenarioFailure("request patch without body")
            WireJson.canonical(WireJson.parse(original).patching(requestPatch.fields))
        }
        val actual = HttpRequest(request.url, request.method, request.headers, bytes, request.requestByteCap,
            request.responseByteCap, request.deadlineNanos, request.urlPolicy)
        val safeBody = if (path.startsWith("/api/v1/prompts/") || path == "/api/v1/sync/pull") bytes?.let(WireJson::parse) else null
        val localPaths = library?.listFiles()?.map { it.relativePath }.orEmpty()
        if (!synchronized(lock) { online } || takeInterruption(false, method, path)) {
            record(Trace(method, path, 0, safeBody, localPaths, null, 0))
            throw HttpTransportError.NetworkFailure
        }
        val response = driver.send(actual)
        val pull = if (path == "/api/v1/sync/pull" && response.statusCode == 200) PullResponse.codec.decode(response.body) else null
        record(Trace(method, path, response.statusCode, safeBody, localPaths, pull, response.bodyByteCount))
        takeHook(true, method, path)?.let {
            scenarioCheck(response.statusCode == 200, "after hook requires real success")
            runHook(it)
        }
        if (takeInterruption(true, method, path)) {
            scenarioCheck(response.statusCode == 200, "acknowledgement loss requires real success")
            throw HttpTransportError.NetworkFailure
        }
        if (responsePatch == null) return response
        scenarioCheck(response.statusCode == 200, "response patch requires real success")
        val changed = WireJson.canonical(WireJson.parse(response.body).patching(responsePatch.fields))
        if (changed.size > request.responseByteCap) throw HttpTransportError.ResponseTooLarge
        return HttpResponse(response.statusCode, response.headers, changed)
    }

    private suspend fun runHook(hook: Hook) {
        try { hook.run() }
        catch (error: Throwable) {
            if (error is CancellationException) throw error
            val safe = error as? ScenarioFailure ?: ScenarioFailure("network hook operation failed")
            synchronized(lock) { if (failure == null) failure = safe }
            throw safe
        }
    }
    private fun record(trace: Trace) = synchronized(lock) { recorded.add(trace) }
    private fun takePatch(response: Boolean, method: String, path: String): Patch? = synchronized(lock) {
        val index = patches.indexOfFirst { it.response == response && it.method == method && it.path == path }
        if (index < 0) null else patches.removeAt(index)
    }
    private fun takeHook(after: Boolean, method: String, path: String): Hook? = synchronized(lock) {
        val index = hooks.indexOfFirst { it.after == after && it.method == method && it.path == path }
        when {
            index < 0 -> null
            hooks[index].skip > 0 -> { hooks[index].skip--; null }
            else -> hooks.removeAt(index)
        }
    }
    private fun takeInterruption(after: Boolean, method: String, path: String): Boolean = synchronized(lock) {
        val index = interruptions.indexOfFirst { it.after == after && it.method == method && it.path == path }
        if (index < 0) false else { interruptions.removeAt(index); true }
    }
    suspend fun close() { scope.cancel(); scope.coroutineContext[Job]?.join() }
}
