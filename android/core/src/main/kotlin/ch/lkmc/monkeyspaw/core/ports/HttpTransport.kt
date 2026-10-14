package ch.lkmc.monkeyspaw.core.ports

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.hasControls
import java.util.Collections
import java.util.Locale

enum class HttpMethod(val rawValue: String) { GET("GET"), POST("POST"), PUT("PUT"), DELETE("DELETE"), PATCH("PATCH") }

/** M10 adds its deployment-bound sync policy when the Kotlin sync URL type exists. */
enum class HttpUrlPolicy { ASSISTANT }

/** No client objects. Caps/header validation finish before any adapter sees a request. */
class HttpRequest(
    val url: String,
    val method: HttpMethod,
    headers: Map<String, String> = emptyMap(),
    body: ByteArray? = null,
    val requestByteCap: Int = Limits.httpRequestCap,
    val responseByteCap: Int = Limits.responseCap,
    val deadlineNanos: Long,
    val urlPolicy: HttpUrlPolicy = HttpUrlPolicy.ASSISTANT,
) {
    private val payload: ByteArray?
    val headers: Map<String, String>
    val body: ByteArray? get() = payload?.copyOf()
    val bodyByteCount: Int get() = payload?.size ?: 0

    init {
        if (requestByteCap <= 0 || responseByteCap <= 0) throw HttpTransportError.InvalidRequest
        if ((body?.size ?: 0) > requestByteCap) throw HttpTransportError.RequestTooLarge

        val snapshot = LinkedHashMap(headers)
        val names = HashSet<String>()
        for ((name, value) in snapshot) {
            if (name.isEmpty() || name.any { it !in headerToken } || !names.add(name.lowercase(Locale.ROOT)) || value.hasControls()) {
                throw HttpTransportError.InvalidRequest
            }
        }
        this.headers = Collections.unmodifiableMap(snapshot)
        payload = body?.copyOf()
    }

    override fun toString(): String = "<HTTP request redacted>"

    private companion object {
        const val headerToken = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    }
}

/** Adapters return lowercase headers and bounded decoded bytes, including error statuses. */
class HttpResponse(val statusCode: Int, headers: Map<String, String> = emptyMap(), body: ByteArray) {
    val headers: Map<String, String> = Collections.unmodifiableMap(LinkedHashMap(headers))
    private val payload = body.copyOf()
    val body: ByteArray get() = payload.copyOf()
    val bodyByteCount: Int get() = payload.size

    override fun toString(): String = "<HTTP response redacted>"
}

sealed class HttpTransportError private constructor(code: String) : Exception(code, null, false, true) {
    data object InvalidRequest : HttpTransportError("invalidRequest")
    data object InvalidURL : HttpTransportError("invalidURL")
    data object InsecureURL : HttpTransportError("insecureURL")
    data object CredentialsInURL : HttpTransportError("credentialsInURL")
    data object ServerMismatch : HttpTransportError("serverMismatch")
    data object RedirectRefused : HttpTransportError("redirectRefused")
    data object RequestTooLarge : HttpTransportError("requestTooLarge")
    data object ResponseTooLarge : HttpTransportError("responseTooLarge")
    data object DeadlineExceeded : HttpTransportError("deadlineExceeded")
    data object Cancelled : HttpTransportError("cancelled")
    data object InvalidResponse : HttpTransportError("invalidResponse")
    data object NetworkFailure : HttpTransportError("networkFailure")

    final override fun toString(): String = message.orEmpty()
}

/** One non-streaming attempt. App/data validates the URL policy and rejects GET bodies,
 * userinfo and every 3xx. No automatic retry, cookies, cache, credential storage or logging.
 * Keep normal TLS validation; enforce selected caps before/during decoded body accumulation,
 * including advertised lengths, and retain an observed cap failure after cancellation.
 * The absolute monotonic deadline covers queue/connect/body and cancellation closes receipt.
 * Throw only body-free HttpTransportError; protocol clients interpret bounded error responses.
 */
fun interface HttpTransport {
    suspend fun send(request: HttpRequest): HttpResponse
}
