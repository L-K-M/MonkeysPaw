package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.llm.AssistantError
import ch.lkmc.monkeyspaw.core.domain.llm.trimProviderWhitespace
import ch.lkmc.monkeyspaw.core.ports.HttpRequest
import ch.lkmc.monkeyspaw.core.ports.HttpResponse
import ch.lkmc.monkeyspaw.core.ports.HttpTransport
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import java.time.Instant
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.ResolverStyle
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Only OpenAI's explicit format-rejection probes may accept a 400 for inspection. */
internal object AssistantHTTP {
    enum class StatusPolicy { SUCCESS_ONLY, FORMAT_PROBE }

    suspend fun send(request: HttpRequest, transport: HttpTransport, nowUTC: () -> Instant,
                     policy: StatusPolicy = StatusPolicy.SUCCESS_ONLY): HttpResponse = try {
        currentCoroutineContext().ensureActive()
        val response = transport.send(request)
        currentCoroutineContext().ensureActive()
        if (response.bodyByteCount > request.responseByteCap) throw HttpTransportError.ResponseTooLarge

        when (response.statusCode) {
            200 -> response
            400 -> if (policy == StatusPolicy.FORMAT_PROBE) response else throw AssistantError.ProviderFailure(400)
            401, 403 -> throw AssistantError.Authentication
            404 -> throw AssistantError.ModelNotFound
            429 -> throw AssistantError.RateLimited(retryAfter(response.headers, nowUTC()))
            529 -> throw AssistantError.Overloaded
            else -> throw AssistantError.ProviderFailure(response.statusCode)
        }
    } catch (error: AssistantError) {
        throw error
    } catch (error: HttpTransportError) {
        throw AssistantError.Transport(error)
    } catch (_: CancellationException) {
        throw AssistantError.Transport(HttpTransportError.Cancelled)
    } catch (_: Exception) {
        throw AssistantError.Transport(HttpTransportError.NetworkFailure)
    }

    private fun retryAfter(headers: Map<String, String>, now: Instant): Double? {
        val value = headers.entries.firstOrNull { it.key.equals("retry-after", ignoreCase = true) }
            ?.value?.trimProviderWhitespace() ?: return null
        if (value.isNotEmpty() && value.all { it in '0'..'9' }) return value.toDoubleOrNull()?.takeIf { it.isFinite() }

        // shortcut: IMF-fixdate only; add obsolete forms if an endpoint needs them.
        val date = try { ZonedDateTime.parse(value, httpDate).toInstant() } catch (_: Exception) { return null }
        if (httpDate.format(date) != value) return null
        return maxOf(0.0, date.epochSecond.toDouble() - now.epochSecond - now.nano / 1_000_000_000.0)
    }

    private val httpDate = DateTimeFormatter.ofPattern("EEE, dd MMM uuuu HH:mm:ss 'GMT'", Locale.US)
        .withResolverStyle(ResolverStyle.STRICT).withZone(ZoneOffset.UTC)
}
