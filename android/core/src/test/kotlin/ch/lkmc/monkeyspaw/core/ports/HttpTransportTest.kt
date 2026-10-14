package ch.lkmc.monkeyspaw.core.ports

import ch.lkmc.monkeyspaw.core.domain.Limits
import java.net.URI
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/** Request cases port Swift AssistantValuesTests, with mutation and pre-dispatch proof. */
class HttpTransportTest {
    @Test fun rejectsInvalidHeadersBeforeTheTransportIsCalled() = runTest {
        val invalid = listOf(
            mapOf("" to "value"), mapOf("X-\rName" to "value"), mapOf("X-\nName" to "value"), mapOf("X-\u0000Name" to "value"),
            mapOf("X Name" to "value"), mapOf("X:Name" to "value"), mapOf("X-ñ" to "value"),
            mapOf("Authorization" to "one", "authorization" to "two"),
        ) + listOf("\r", "\n", "\u0000", "\t", "\u001f", "\u007f", "\u0085", "\r\nX-Injected: b", "\u200d", "\u00ad").map {
            mapOf("Authorization" to "Bearer a${it}b")
        }
        val transport = CountingTransport()
        for (headers in invalid) {
            assertEquals(HttpTransportError.InvalidRequest, assertFailsWith<HttpTransportError> {
                transport.send(request(headers = headers))
            })
        }
        assertEquals(0, transport.calls)
    }

    @Test fun rejectsInvalidCapsAndOversizedBytesBeforeTheTransportIsCalled() = runTest {
        val transport = CountingTransport()
        for (cap in listOf(-1, 0)) {
            assertEquals(HttpTransportError.InvalidRequest, assertFailsWith<HttpTransportError> {
                transport.send(request(requestByteCap = cap))
            })
            assertEquals(HttpTransportError.InvalidRequest, assertFailsWith<HttpTransportError> {
                transport.send(request(responseByteCap = cap))
            })
        }
        assertEquals(HttpTransportError.RequestTooLarge, assertFailsWith<HttpTransportError> {
            transport.send(request(body = byteArrayOf(1, 2), requestByteCap = 1))
        })
        assertEquals(HttpTransportError.RequestTooLarge, assertFailsWith<HttpTransportError> {
            transport.send(request(body = ByteArray(Limits.httpRequestCap + 1)))
        })
        assertEquals(0, transport.calls)
        transport.send(request(body = byteArrayOf(1), requestByteCap = 1))
        transport.send(request(body = ByteArray(Limits.httpRequestCap)))
        assertEquals(2, transport.calls)
    }

    @Test fun preservesValidHeadersEmptyValuesAndTypedDeadline() = runTest {
        val headers = mapOf("Authorization" to "Bearer key", "x-api-key" to "key", "X-Empty" to "",
            "X-Text" to "café", "!#$%&'*+-.^_`|~0123456789AZaz" to "value")
        val clock = MonotonicClock { Long.MAX_VALUE - 10 }
        val deadline = clock.nowNanos() + Limits.llmBudgetNanos
        val request = HttpRequest(URI("https://example.com/v1/messages"), HttpMethod.POST, headers, byteArrayOf(1, 2, 3),
            requestByteCap = 3, responseByteCap = Limits.syncResponseCap, deadlineNanos = deadline)
        val response = CountingTransport().send(request)
        assertEquals(headers, request.headers)
        assertEquals(deadline, request.deadlineNanos)
        assertEquals(Limits.llmBudgetNanos, request.deadlineNanos - clock.nowNanos())
        assertEquals(HttpUrlPolicy.ASSISTANT, request.urlPolicy)
        assertEquals(3, request.requestByteCap)
        assertEquals(16 * 1024 * 1024, request.responseByteCap)
        assertContentEquals(byteArrayOf(1, 2, 3), request.body)
        assertEquals(200, response.statusCode)
        assertContentEquals(byteArrayOf(4, 5), response.body)
        assertEquals(2 * 1024 * 1024, Limits.responseCap)
        assertEquals(2 * 1024 * 1024, Limits.httpRequestCap)
        assertEquals(15_000_000_000L, Limits.modelListTimeoutNanos)
        assertEquals(300_000_000_000L, Limits.llmBudgetNanos)
    }

    @Test fun callerMutationCannotInvalidateAnEnvelopeAfterConstruction() {
        val headers = linkedMapOf("x-api-key" to "original")
        val bytes = byteArrayOf(1, 2)
        val request = request(headers = headers, body = bytes)
        val response = HttpResponse(500, headers, bytes)
        headers["x-api-key"] = "changed\r\nInjected: header"
        bytes[0] = 9
        request.body!![0] = 8
        response.body[0] = 7
        assertEquals(mapOf("x-api-key" to "original"), request.headers)
        assertEquals(request.headers, response.headers)
        assertContentEquals(byteArrayOf(1, 2), request.body)
        assertContentEquals(byteArrayOf(1, 2), response.body)
        assertEquals(2, request.bodyByteCount)
        assertEquals(2, response.bodyByteCount)
        assertFailsWith<UnsupportedOperationException> { (request.headers as MutableMap)["X Name"] = "bad" }
        assertFailsWith<UnsupportedOperationException> { (response.headers as MutableMap).clear() }
    }

    private fun request(headers: Map<String, String> = emptyMap(), body: ByteArray? = null,
                        requestByteCap: Int = Limits.httpRequestCap, responseByteCap: Int = Limits.responseCap): HttpRequest =
        HttpRequest(URI("https://example.com"), HttpMethod.POST, headers, body, requestByteCap, responseByteCap, deadlineNanos = 1L)

    private class CountingTransport : HttpTransport {
        var calls = 0

        override suspend fun send(request: HttpRequest): HttpResponse {
            calls++
            return HttpResponse(200, body = byteArrayOf(4, 5))
        }
    }
}
