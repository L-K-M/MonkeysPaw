package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.domain.llm.ProviderKind
import ch.lkmc.monkeyspaw.core.domain.llm.ProviderSettings
import ch.lkmc.monkeyspaw.core.domain.llm.ProviderSettingsError
import ch.lkmc.monkeyspaw.core.ports.*
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.coroutines.executeAsync
import okio.BufferedSink
import okio.GzipSource
import okio.buffer
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.Locale
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit.NANOSECONDS
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Shared Android network driver. M10 can add its URL policy here without a second HTTP stack. */
internal class OkHttpHttpTransport(
    private val clock: MonotonicClock,
    private val scope: CoroutineScope,
    dispatcher: Dispatcher = Dispatcher(),
) : HttpTransport {
    private val client = OkHttpClient.Builder()
        .dispatcher(dispatcher)
        .followRedirects(false)
        .followSslRedirects(false)
        .retryOnConnectionFailure(false)
        .fastFallback(false)
        .authenticator(Authenticator.NONE)
        .proxyAuthenticator(Authenticator.NONE)
        .cookieJar(CookieJar.NO_COOKIES)
        .cache(null)
        // The separate monotonic timer also covers dispatcher queues and continuous receipt.
        .connectTimeout(0, NANOSECONDS)
        .readTimeout(0, NANOSECONDS)
        .writeTimeout(0, NANOSECONDS)
        .callTimeout(0, NANOSECONDS)
        .addNetworkInterceptor { chain ->
            val receipt = checkNotNull(chain.request().tag(Receipt::class.java))
            val response = chain.proceed(chain.request())
            receipt.checkHeaders(response)
            // OkHttp 5.5.0 retries 503/Retry-After:0 and coalesced 421 even with retries disabled.
            // Hide those codes (and 407's direct-route exception) only from its follow-up logic.
            // The receipt restores the wire status without changing headers or decoded bytes.
            if (response.code in listOf(407, 421, 503)) {
                receipt.wireStatus = response.code
                response.newBuilder().code(400).build()
            } else response
        }
        .build()

    override suspend fun send(request: HttpRequest): HttpResponse {
        val url = validatedURL(request)
        val receipt = Receipt(request, clock)
        val call = try {
            val body = request.body?.let(::OneShotBody) ?: when (request.method) {
                HttpMethod.POST, HttpMethod.PUT, HttpMethod.PATCH -> OneShotBody(byteArrayOf())
                else -> null
            }
            val headers = Headers.Builder().apply {
                // Core already rejects controls; its contract permits non-ASCII values.
                request.headers.forEach { (name, value) -> addUnsafeNonAscii(name, value) }
            }.build()
            client.newCall(Request.Builder().url(url).headers(headers)
                .method(request.method.rawValue, body).tag(Receipt::class.java, receipt).build())
        } catch (_: IllegalArgumentException) {
            throw HttpTransportError.InvalidRequest
        }

        try {
            return suspendCancellableCoroutine { continuation ->
                receipt.start(call, continuation)
                continuation.invokeOnCancellation { receipt.fail(HttpTransportError.Cancelled) }
                val worker = scope.launch {
                    try {
                        receipt.checkActive()
                        call.executeAsync().use { response -> receipt.read(response) }
                    } catch (_: CancellationException) {
                        receipt.fail(HttpTransportError.Cancelled)
                    } catch (_: Exception) {
                        receipt.fail(HttpTransportError.NetworkFailure)
                    }
                }
                worker.invokeOnCompletion { if (it != null) receipt.fail(HttpTransportError.Cancelled) }
            }
        } catch (failure: HttpTransportError) {
            // An exceptional resume can arrive before cancellation but run after the caller cancels.
            if (failure != HttpTransportError.Cancelled && currentCoroutineContext().isActive) throw failure
            throw CancellationException(failure.message, failure)
        } catch (_: CancellationException) {
            // L1/Swift require typed cancellation. Keep it as a cause so cancelled launches stay cancelled.
            val failure = receipt.failure ?: HttpTransportError.Cancelled
            throw CancellationException(failure.message, failure)
        }
    }

    private fun validatedURL(request: HttpRequest): HttpUrl {
        if (request.method == HttpMethod.GET && request.body != null) throw HttpTransportError.InvalidRequest
        val raw = request.url
        if ('#' in raw || '\\' in raw || raw.codePoints().anyMatch {
                Character.isISOControl(it) || Character.getType(it) == Character.FORMAT.toInt()
            }) {
            throw HttpTransportError.InvalidURL
        }
        when (request.urlPolicy) {
            HttpUrlPolicy.ASSISTANT -> try {
                // Validate with Core before OkHttp can normalize deceptive host/path spellings.
                // Queries belong to model-list requests, never the provider's base URL.
                ProviderSettings.normalizeBaseURL(raw.substringBefore('?'), ProviderKind.ANTHROPIC)
            } catch (error: ProviderSettingsError) {
                throw when (error) {
                    ProviderSettingsError.CredentialsInURL -> HttpTransportError.CredentialsInURL
                    ProviderSettingsError.InsecureBaseURL -> HttpTransportError.InsecureURL
                    else -> HttpTransportError.InvalidURL
                }
            }
            // Z6 adds the sync TLS trust factory; until then only system trust is honoured.
            is HttpUrlPolicy.Sync -> {
                val policy = request.urlPolicy as HttpUrlPolicy.Sync
                if (policy.trust != SyncTLSTrust.SYSTEM) throw HttpTransportError.InvalidRequest
                policy.server.validatedRequestURL(raw)
            }
        }
        val url = raw.toHttpUrlOrNull() ?: throw HttpTransportError.InvalidURL
        return url.newBuilder().host(url.host.removeSuffix(".")).build()
    }

    private class OneShotBody(private val bytes: ByteArray) : RequestBody() {
        override fun contentType(): MediaType? = null
        override fun contentLength(): Long = bytes.size.toLong()
        override fun isOneShot(): Boolean = true
        override fun writeTo(sink: BufferedSink) { sink.write(bytes) }
    }

    private class Receipt(private val request: HttpRequest, private val clock: MonotonicClock) {
        private val lock = Any()
        private var result: Result<HttpResponse>? = null
        private var call: Call? = null
        private var continuation: CancellableContinuation<HttpResponse>? = null
        private var timer: ScheduledFuture<*>? = null
        var wireStatus: Int? = null
        val failure: HttpTransportError? get() = synchronized(lock) { result?.exceptionOrNull() as? HttpTransportError }

        fun start(call: Call, continuation: CancellableContinuation<HttpResponse>) {
            synchronized(lock) {
                this.call = call
                this.continuation = continuation
                val remaining = request.deadlineNanos - clock.nowNanos()
                timer = deadlines.schedule({ fail(HttpTransportError.DeadlineExceeded) }, maxOf(0, remaining), NANOSECONDS)
            }
        }

        fun checkActive() {
            failure?.let { throw it }
            if (request.deadlineNanos - clock.nowNanos() <= 0) {
                fail(HttpTransportError.DeadlineExceeded)
                throw checkNotNull(failure)
            }
        }

        fun checkHeaders(response: Response) {
            transition {
                // This interceptor runs before BridgeInterceptor removes gzip Content-Length.
                // Compare decimal lexemes without allocating an arbitrarily large integer.
                val length = response.header("Content-Length")?.trimStart('0')
                val cap = request.responseByteCap.toString()
                val oversized = length != null && length.all { it in '0'..'9' } &&
                    (length.length > cap.length || length.length == cap.length && length > cap)
                val error = when {
                    request.deadlineNanos - clock.nowNanos() <= 0 -> HttpTransportError.DeadlineExceeded
                    response.code in 300..399 -> HttpTransportError.RedirectRefused
                    oversized -> HttpTransportError.ResponseTooLarge
                    else -> null
                }
                error?.let { Result.failure(it) }
            }
            if (failure != null) {
                response.close()
                throw IOException("Receipt closed")
            }
        }

        fun read(response: Response) {
            checkActive()
            val body = ByteArrayOutputStream()
            val chunk = ByteArray(8192)
            // Bridge skips decoding when callers supply Accept-Encoding or Range.
            val gzip = response.code != 204 && response.code != 205 &&
                response.header("Content-Encoding").equals("gzip", ignoreCase = true)
            val source = if (gzip) GzipSource(response.body.source()).buffer().inputStream() else response.body.byteStream()
            source.use {
                while (true) {
                    checkActive()
                    // Read at most one byte past the selected cap and check before appending.
                    val count = it.read(chunk, 0, minOf(chunk.size.toLong(), request.responseByteCap.toLong() - body.size() + 1).toInt())
                    if (count == -1) break
                    // Observe and claim a cap failure under the same lock as cancel/deadline.
                    transition {
                        when {
                            request.deadlineNanos - clock.nowNanos() <= 0 -> Result.failure(HttpTransportError.DeadlineExceeded)
                            count > request.responseByteCap - body.size() -> Result.failure(HttpTransportError.ResponseTooLarge)
                            else -> { body.write(chunk, 0, count); null }
                        }
                    }
                    if (failure != null) return
                }
            }
            val decodedHeaders = if (gzip) response.headers.newBuilder().removeAll("Content-Encoding").removeAll("Content-Length").build()
                else response.headers
            val headers = decodedHeaders.names().associate { it.lowercase(Locale.ROOT) to decodedHeaders.values(it).joinToString(", ") }
            finish(Result.success(HttpResponse(wireStatus ?: response.code, headers, body.toByteArray())))
        }

        fun fail(error: HttpTransportError) { finish(Result.failure(error)) }

        private fun finish(proposed: Result<HttpResponse>) = transition {
            if ((proposed.isSuccess || proposed.exceptionOrNull() == HttpTransportError.NetworkFailure) &&
                request.deadlineNanos - clock.nowNanos() <= 0) {
                Result.failure(HttpTransportError.DeadlineExceeded)
            } else proposed
        }

        private fun transition(propose: () -> Result<HttpResponse>?) {
            val complete = synchronized(lock) {
                if (result != null) return
                val outcome = propose() ?: return
                result = outcome
                val task = call
                val callback = continuation
                val deadlineTimer = timer
                call = null
                continuation = null
                timer = null
                val complete: () -> Unit = {
                    deadlineTimer?.cancel(false)
                    task?.cancel()
                    outcome.fold({ callback?.resume(it) }, { callback?.resumeWithException(it) })
                }
                complete
            }
            complete()
        }
    }

    private companion object {
        val deadlines = ScheduledThreadPoolExecutor(1) { work ->
            Thread(work, "MonkeysPaw HTTP deadline").apply { isDaemon = true }
        }.apply { removeOnCancelPolicy = true }
    }
}
