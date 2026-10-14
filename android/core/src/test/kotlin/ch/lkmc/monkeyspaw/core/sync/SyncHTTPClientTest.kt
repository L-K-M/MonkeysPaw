package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import java.util.Base64
import java.util.UUID
import kotlin.test.*

class SyncHTTPClientTest {
    @Test fun authenticatedEndpointsUseExactMethodsPathsHeadersAndCanonicalBodies() = runTest {
        val transport = RecordingTransport()
        val client = client(transport)
        suspend fun <T> check(method: HttpMethod, path: String, response: T, codec: WireCodec<T>, body: String? = null,
                              call: suspend () -> Any?) {
            transport.response = HttpResponse(200, body = codec.encode(response))
            call()
            val request = transport.requests.last()
            assertEquals(method, request.method)
            assertEquals(server.apiURL + path, request.url)
            val headers = linkedMapOf("Accept" to "application/json", "Authorization" to "Bearer $fakeToken")
            if (body != null) headers["Content-Type"] = "application/json"
            assertEquals(headers, request.headers)
            assertContentEquals(body?.toByteArray(), request.body)
            assertEquals(2 * 1024 * 1024, request.requestByteCap)
            assertEquals(if (path == "/sync/pull") 16 * 1024 * 1024 else 2 * 1024 * 1024, request.responseByteCap)
            assertEquals(60_000_000_000L, request.deadlineNanos)
            assertEquals(HttpUrlPolicy.Sync(server), request.urlPolicy)
        }
        check(HttpMethod.POST, "/auth/logout", EmptyResponse, EmptyResponse.codec) { client.logout() }
        check(HttpMethod.GET, "/me", me, MeResponse.codec) { assertEquals(me, client.me()) }
        check(HttpMethod.GET, "/me", me, MeResponse.codec) { assertEquals(me.devices, client.devices()) }
        check(HttpMethod.DELETE, "/me/devices/${id.rawValue}", EmptyResponse, EmptyResponse.codec) { client.revokeDevice(id) }
        check(HttpMethod.GET, "/prompts/${id.rawValue}", prompt, Prompt.codec) { assertEquals(prompt, client.prompt(id)) }
        check(HttpMethod.PUT, "/prompts/${id.rawValue}", write, WriteResponse.codec,
            """{"base_rev":0,"content":"line\r\n雪","group_id":"${group.rawValue}","origin":"llm","path":"é.md","scope":"group"}""") {
            assertEquals(write, client.putPrompt(id, PutPromptRequest(0, PromptScope.Group(group.rawValue), "é.md", "line\r\n雪", WriteOrigin.LLM)))
        }
        check(HttpMethod.DELETE, "/prompts/${id.rawValue}?base_rev=9223372036854775807", write, WriteResponse.codec) {
            assertEquals(write, client.deletePrompt(id, Long.MAX_VALUE))
        }
        check(HttpMethod.POST, "/prompts/${id.rawValue}/move", write, WriteResponse.codec,
            """{"base_rev":1,"path":"moved.md","scope":"user"}""") {
            assertEquals(write, client.movePrompt(id, MovePromptRequest(1, PromptScope.User, "moved.md")))
        }
        check(HttpMethod.POST, "/sync/pull", pull, PullResponse.codec,
            """{"cursors":{"user:${id.rawValue}":"snap:opaque雪\u0000"},"database_id":null}""") {
            assertEquals(pull, client.pull(PullRequest(null, mapOf("user:${id.rawValue}" to "snap:opaque雪\u0000"))))
        }
        val membership = GroupMembership(group.rawValue, "Test group", Role.VIEWER)
        check(HttpMethod.POST, "/groups/join", membership, GroupMembership.codec,
            """{"invite_token":"$fakeToken"}""") { assertEquals(membership, client.joinGroup(JoinGroupRequest(fakeToken))) }
        assertEquals(10, transport.requests.size)
    }

    @Test fun loginAndRegistrationAreAnonymousEvenWithAnUnrelatedCredential() = runTest {
        val transport = RecordingTransport(HttpResponse(200, body = AuthResponse.codec.encode(AuthResponse(fakeToken, user))))
        val client = SyncHTTPClient(server, transport, SyncCredential(SyncServerURL("https://other.example"), SecretValue(fakeToken)), clock)
        val authentication = client.login(LoginRequest("test", "synthetic-password", "Test device"))
        assertEquals(SyncCredential(server, SecretValue(fakeToken)), authentication.credential)
        assertEquals(user, authentication.user)
        assertEquals("""{"device_name":"Test device","password":"synthetic-password","username":"test"}""",
            transport.requests.last().body!!.toString(Charsets.UTF_8))
        client.register(RegisterRequest(fakeToken, "test", "synthetic-password", "Test device"))
        assertEquals("""{"device_name":"Test device","invite_token":"$fakeToken","password":"synthetic-password","username":"test"}""",
            transport.requests.last().body!!.toString(Charsets.UTF_8))
        for ((index, suffix) in listOf("/auth/login", "/auth/register").withIndex()) {
            val request = transport.requests[index]
            assertEquals(HttpMethod.POST, request.method)
            assertEquals(server.apiURL + suffix, request.url)
            assertEquals(mapOf("Accept" to "application/json", "Content-Type" to "application/json"), request.headers)
            assertEquals(HttpUrlPolicy.Sync(server), request.urlPolicy)
        }
    }

    @Test fun missingMismatchedAndInvalidCredentialsFailWithoutDispatch() = runTest {
        val transport = RecordingTransport()
        assertEquals(SyncHTTPClientError.Unauthorized, failure { SyncHTTPClient(server, transport, clock = clock).me() })
        for (url in listOf("https://other.example/paw", "https://example.com/other", "https://example.com:8443/paw", "http://localhost/paw")) {
            assertEquals(SyncHTTPClientError.CredentialServerMismatch, failure {
                SyncHTTPClient(server, transport, SyncCredential(SyncServerURL(url), SecretValue(fakeToken)), clock).me()
            })
        }
        for (token in listOf("", "synthetic\r\nInjected", "a".repeat(43), fakeToken + " ")) {
            assertEquals(SyncHTTPClientError.InvalidRequest, failure {
                SyncHTTPClient(server, transport, SyncCredential(server, SecretValue(token)), clock).me()
            })
        }
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun equivalentServerSpellingsShareTheCredentialButTrustAlwaysTravelsWithTheBoundPolicy() = runTest {
        val transport = RecordingTransport(HttpResponse(200, body = MeResponse.codec.encode(me)))
        val credential = SyncCredential(SyncServerURL("HTTPS://EXAMPLE.COM.:443/paw/api/v1/"), SecretValue(fakeToken))
        SyncHTTPClient(server, transport, credential, clock, SyncTLSTrust.SYSTEM_AND_USER).me()
        assertEquals(HttpUrlPolicy.Sync(server, SyncTLSTrust.SYSTEM_AND_USER), transport.requests.single().urlPolicy)
    }

    @Test fun everyErrorEnvelopePreservesItsTypedEnginePayload() = runTest {
        val transport = RecordingTransport()
        val client = client(transport)
        for (envelope in errors) {
            transport.response = errorResponse(envelope)
            assertEnvelope(envelope, failure { client.prompt(id) })
        }
        assertEquals(errors.size, transport.requests.size)
    }

    @Test fun emptyResponseEndpointsCannotAcceptErrorEnvelopes() = runTest {
        val transport = RecordingTransport()
        val client = client(transport)
        for (envelope in errors) {
            transport.response = errorResponse(envelope)
            assertEnvelope(envelope, failure { client.logout() })
            assertEnvelope(envelope, failure { client.revokeDevice(id) })
        }
    }

    @Test fun statusAndEnvelopeMustAgreeIncludingSuccessAndEmptyBodiesOnFailures() = runTest {
        val transport = RecordingTransport()
        val client = client(transport)
        for (envelope in errors) {
            for (status in listOf(200, 201, 400, 401, 403, 404, 409, 410, 413, 422, 429, 500, 503).filter { it != envelope.httpStatus }) {
                transport.response = HttpResponse(status, mapOf("Retry-After" to "7"), ErrorResponse.codec.encode(envelope))
                assertEquals(status, assertIs<SyncHTTPClientError.StatusEnvelopeMismatch>(failure { client.prompt(id) }).statusCode)
                assertEquals(status, assertIs<SyncHTTPClientError.StatusEnvelopeMismatch>(failure { client.logout() }).statusCode)
            }
        }
        for (status in listOf(201, 401, 500, 599)) {
            transport.response = HttpResponse(status, body = Prompt.codec.encode(prompt))
            assertEquals(status, assertIs<SyncHTTPClientError.StatusEnvelopeMismatch>(failure { client.prompt(id) }).statusCode)
            transport.response = HttpResponse(status, body = "{}".toByteArray())
            assertEquals(status, assertIs<SyncHTTPClientError.StatusEnvelopeMismatch>(failure { client.logout() }).statusCode)
        }
    }

    @Test fun malformedAndNonJSONFailuresHaveNoUnboundedDiagnosticFallback() = runTest {
        val transport = RecordingTransport()
        val client = client(transport)
        for (body in listOf("", "<html>synthetic upstream detail</html>", "[]", "{\"code\":\"unknown\"}",
            "{\"code\":\"unauthorized\",\"extra\":true}")) {
            for (status in listOf(200, 400, 401, 409, 429)) {
                transport.response = HttpResponse(status, body = body.toByteArray())
                assertEquals(SyncHTTPClientError.MalformedResponse, failure { client.me() })
            }
            for (status in listOf(500, 502, 503, 599)) {
                transport.response = HttpResponse(status, body = body.toByteArray())
                assertEquals(status, assertIs<SyncHTTPClientError.ServerFailure>(failure { client.me() }).statusCode)
            }
        }
        transport.response = HttpResponse(200, body = byteArrayOf(0xff.toByte()))
        assertEquals(SyncHTTPClientError.MalformedResponse, failure { client.me() })
    }

    @Test fun retryAfterRequiresExactlyOneCaseInsensitiveCanonicalBoundedInteger() = runTest {
        val transport = RecordingTransport()
        val client = client(transport)
        val body = ErrorResponse.codec.encode(ErrorResponse.Failure(FailureCode.RATE_LIMITED))
        for (value in listOf("1", "7", "900")) {
            for (name in listOf("retry-after", "Retry-After", "RETRY-AFTER")) {
                transport.response = HttpResponse(429, mapOf(name to value), body)
                assertEquals(value.toLong(), assertIs<SyncHTTPClientError.RateLimited>(failure { client.me() }).retryAfter.seconds)
            }
        }
        for (headers in listOf(emptyMap(), mapOf("Retry-After" to "7", "retry-after" to "7")) +
            listOf("0", "901", "01", "+1", "-1", "1.0", "1e0", " 1", "1 ", "1, 2", "", "999999999999999999999999",
                "Wed, 21 Oct 2015 07:28:00 GMT").map { mapOf("Retry-After" to it) }) {
            transport.response = HttpResponse(429, headers, body)
            assertEquals(SyncHTTPClientError.MalformedResponse, failure { client.me() })
        }
    }

    @Test fun deleteNotFoundAndDeletedRemainErrorsForTheEngineToInterpret() = runTest {
        val transport = RecordingTransport()
        val client = client(transport)
        transport.response = errorResponse(ErrorResponse.Failure(FailureCode.NOT_FOUND))
        assertEquals(SyncHTTPClientError.NotFound, failure { client.deletePrompt(id, 1) })
        transport.response = errorResponse(ErrorResponse.Deleted)
        assertEquals(SyncHTTPClientError.Deleted, failure { client.deletePrompt(id, 1) })
    }

    @Test fun invalidConstructedDTOsAreRejectedBeforeDispatch() = runTest {
        val transport = RecordingTransport()
        val client = client(transport)
        val actions: List<suspend () -> Any?> = listOf(
            { client.login(LoginRequest("TEST", "synthetic", "Test")) },
            { client.register(RegisterRequest("invalid", "test", "synthetic-password", "Test")) },
            { client.putPrompt(id, PutPromptRequest(-1, PromptScope.User, "p.md", "")) },
            { client.putPrompt(id, PutPromptRequest(0, PromptScope.Group("invalid"), "p.md", "")) },
            { client.putPrompt(id, PutPromptRequest(0, PromptScope.User, "p.md", "x".repeat(256 * 1024 + 1))) },
            { client.movePrompt(id, MovePromptRequest(0, PromptScope.User, "p.md")) },
            { client.deletePrompt(id, 0) }, { client.deletePrompt(id, -1) },
            { client.pull(PullRequest("invalid", emptyMap())) },
            { client.pull(PullRequest(null, mapOf("group:invalid" to "0"))) },
            { client.joinGroup(JoinGroupRequest("invalid")) },
        )
        for (action in actions) assertEquals(SyncHTTPClientError.InvalidRequest, failure(action))
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun requestEnvelopeCapIsInclusiveAndOverflowNeverDispatches() = runTest {
        val transport = RecordingTransport(HttpResponse(200, body = PullResponse.codec.encode(pull)))
        val client = client(transport)
        val key = "user:${id.rawValue}"
        val overhead = PullRequest.codec.encode(PullRequest(null, mapOf(key to "x"))).size - 1
        client.pull(PullRequest(null, mapOf(key to "x".repeat(2 * 1024 * 1024 - overhead))))
        assertEquals(2 * 1024 * 1024, transport.requests.single().bodyByteCount)
        assertTransport(HttpTransportError.RequestTooLarge) {
            client.pull(PullRequest(null, mapOf(key to "x".repeat(2 * 1024 * 1024 - overhead + 1))))
        }
        assertEquals(1, transport.requests.size)
    }

    @Test fun fakeTransportsStillFaceInclusiveDecodedResponseCaps() = runTest {
        val transport = RecordingTransport()
        val client = client(transport)
        transport.response = HttpResponse(200, body = padded(MeResponse.codec.encode(me), 2 * 1024 * 1024))
        assertEquals(me, client.me())
        transport.response = HttpResponse(200, body = padded(PullResponse.codec.encode(pull), 16 * 1024 * 1024))
        assertEquals(pull, client.pull(PullRequest(null, emptyMap())))
        for (status in listOf(200, 401, 500)) {
            transport.response = HttpResponse(status, body = ByteArray(2 * 1024 * 1024 + 1))
            assertTransport(HttpTransportError.ResponseTooLarge) { client.me() }
            transport.response = HttpResponse(status, body = ByteArray(16 * 1024 * 1024 + 1))
            assertTransport(HttpTransportError.ResponseTooLarge) { client.pull(PullRequest(null, emptyMap())) }
        }
    }

    @Test fun everyRedirectIsRefusedWithoutRetry() = runTest {
        val transport = RecordingTransport()
        val client = client(transport)
        for (status in 300..399) {
            transport.response = HttpResponse(status, mapOf("Location" to "https://other.example"), MeResponse.codec.encode(me))
            assertTransport(HttpTransportError.RedirectRefused) { client.me() }
        }
        assertEquals(100, transport.requests.size)
    }

    @Test fun suppliedDeadlineOnlyShortensTheSixtySecondCapAndSupportsNanoTimeWrap() = runTest {
        for (now in listOf(123L, Long.MAX_VALUE - 100)) {
            val transport = RecordingTransport(HttpResponse(200, body = MeResponse.codec.encode(me)))
            val client = SyncHTTPClient(server, transport, credential, MonotonicClock { now })
            for (budget in listOf(5_000_000_000L, 120_000_000_000L)) {
                client.me(now + budget)
                assertEquals(minOf(budget, 60_000_000_000L), transport.requests.last().deadlineNanos - now)
            }
            assertTransport(HttpTransportError.DeadlineExceeded) { client.me(now) }
            assertTransport(HttpTransportError.DeadlineExceeded) { client.me(now - 1) }
            assertEquals(2, transport.requests.size)
        }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test fun clientCancelsACooperativeTransportThatMissesItsDeadline() = runTest {
        var released = false
        val transport = HttpTransport {
            try { awaitCancellation() }
            finally { released = true }
        }
        assertTransport(HttpTransportError.DeadlineExceeded) { client(transport).me(5_000_000_000L) }
        assertTrue(released)
        assertEquals(5000, testScheduler.currentTime)
    }

    @Test fun deadlineAndCancellationAreRecheckedAfterATransportReturns() = runTest {
        var now = 0L
        val expired = HttpTransport {
            now = it.deadlineNanos
            HttpResponse(200, body = MeResponse.codec.encode(me))
        }
        assertTransport(HttpTransportError.DeadlineExceeded) {
            SyncHTTPClient(server, expired, credential, MonotonicClock { now }).me()
        }
        var failure: SyncHTTPClientError? = null
        var released = false
        val child = launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                client(HttpTransport {
                    try { awaitCancellation() }
                    finally { released = true }
                }).me()
            } catch (error: SyncHTTPClientError) { failure = error }
        }
        child.cancelAndJoin()
        assertTrue(released)
        assertEquals(HttpTransportError.Cancelled, assertIs<SyncHTTPClientError.Transport>(failure).error)

        var lateFailure: SyncHTTPClientError? = null
        val late = launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                client(HttpTransport {
                    currentCoroutineContext().cancel()
                    HttpResponse(200, body = MeResponse.codec.encode(me))
                }).me()
            } catch (error: SyncHTTPClientError) { lateFailure = error }
        }
        late.join()
        assertEquals(HttpTransportError.Cancelled, assertIs<SyncHTTPClientError.Transport>(lateFailure).error)
    }

    @Test fun anAlreadyCancelledIntentDoesNotDispatch() = runTest {
        val transport = RecordingTransport()
        var captured: SyncHTTPClientError? = null
        launch(start = CoroutineStart.UNDISPATCHED) {
            currentCoroutineContext().cancel()
            try { client(transport).me() }
            catch (error: SyncHTTPClientError) { captured = error }
        }.join()
        assertEquals(HttpTransportError.Cancelled, assertIs<SyncHTTPClientError.Transport>(captured).error)
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun typedTransportFailuresAndCancellationRemainSanitizedWithoutRetries() = runTest {
        val failures = listOf(HttpTransportError.InvalidRequest, HttpTransportError.InvalidURL, HttpTransportError.InsecureURL,
            HttpTransportError.CredentialsInURL, HttpTransportError.ServerMismatch, HttpTransportError.RedirectRefused,
            HttpTransportError.RequestTooLarge, HttpTransportError.ResponseTooLarge, HttpTransportError.DeadlineExceeded,
            HttpTransportError.Cancelled, HttpTransportError.InvalidResponse, HttpTransportError.NetworkFailure)
        for (error in failures) assertTransport(error) { client(HttpTransport { throw error }).me() }
        assertTransport(HttpTransportError.Cancelled) { client(HttpTransport { throw CancellationException("synthetic detail") }).me() }
        assertTransport(HttpTransportError.NetworkFailure) { client(HttpTransport { throw IllegalStateException("synthetic detail") }).me() }
    }

    @Test fun diagnosticsRedactCredentialsRequestsPayloadsAndUnderlyingCauses() = runTest {
        val sentinel = UUID.randomUUID().toString()
        val transport = RecordingTransport(HttpResponse(200, body = AuthResponse.codec.encode(AuthResponse(fakeToken, user))))
        val client = client(transport)
        val authentication = client.login(LoginRequest("test", sentinel, "Test device"))
        val payloadErrors = listOf(SyncHTTPClientError.Conflict(ConflictHead(1, PromptScope.User, "$sentinel.md", sentinel)),
            SyncHTTPClientError.PathTaken(ExistingPrompt(id.rawValue, 1, sentinel)),
            SyncHTTPClientError.SnapshotExpired(listOf(sentinel)))
        val networkError = failure { client(HttpTransport { throw IllegalStateException("$sentinel $fakeToken") }).me() }
        for (value in listOf(credential, authentication, client, transport.requests.single(), transport.response) + payloadErrors + networkError) {
            assertFalse(fakeToken in value.toString())
            assertFalse(sentinel in value.toString())
        }
        for (error in payloadErrors + networkError) {
            assertNull(error.cause)
            assertTrue(error.suppressed.isEmpty())
            for (text in listOf(error.message.orEmpty(), error.localizedMessage.orEmpty(), error.stackTraceToString())) {
                assertFalse(sentinel in text)
                assertFalse(fakeToken in text)
            }
        }
    }

    @Test fun errorCollectionsOwnTheirPayloadLists() {
        val scopes = mutableListOf("user:${id.rawValue}")
        val issues = mutableListOf(Issue("source.too_large", Severity.ERROR))
        val expired = SyncHTTPClientError.SnapshotExpired(scopes)
        val validation = SyncHTTPClientError.Validation(issues)
        scopes.clear()
        issues.clear()
        assertEquals(1, expired.scopes.size)
        assertEquals(1, validation.issues.size)
        assertFailsWith<UnsupportedOperationException> { (expired.scopes as MutableList).clear() }
        assertFailsWith<UnsupportedOperationException> { (validation.issues as MutableList).clear() }
    }

    private suspend fun failure(action: suspend () -> Any?): SyncHTTPClientError = assertFailsWith<SyncHTTPClientError> { action() }
    private suspend fun assertTransport(expected: HttpTransportError, action: suspend () -> Any?) {
        assertEquals(expected, assertIs<SyncHTTPClientError.Transport>(failure(action)).error)
    }

    private fun assertEnvelope(envelope: ErrorResponse, error: SyncHTTPClientError) {
        when (envelope) {
            is ErrorResponse.Conflict -> assertEquals(envelope.head, assertIs<SyncHTTPClientError.Conflict>(error).head)
            is ErrorResponse.PathTaken -> assertEquals(envelope.existing, assertIs<SyncHTTPClientError.PathTaken>(error).existing)
            ErrorResponse.Deleted -> assertEquals(SyncHTTPClientError.Deleted, error)
            is ErrorResponse.Validation -> assertEquals(envelope.issues, assertIs<SyncHTTPClientError.Validation>(error).issues)
            is ErrorResponse.SnapshotExpired -> assertEquals(envelope.scopes, assertIs<SyncHTTPClientError.SnapshotExpired>(error).scopes)
            is ErrorResponse.Failure -> when (envelope.code) {
                FailureCode.MALFORMED_REQUEST -> assertEquals(SyncHTTPClientError.MalformedRequest, error)
                FailureCode.UNAUTHORIZED -> assertEquals(SyncHTTPClientError.Unauthorized, error)
                FailureCode.FORBIDDEN -> assertEquals(SyncHTTPClientError.Forbidden, error)
                FailureCode.NOT_FOUND -> assertEquals(SyncHTTPClientError.NotFound, error)
                FailureCode.ENVELOPE_TOO_LARGE -> assertEquals(SyncHTTPClientError.EnvelopeTooLarge, error)
                FailureCode.INTERNAL_ERROR -> assertEquals(500, assertIs<SyncHTTPClientError.ServerFailure>(error).statusCode)
                FailureCode.RATE_LIMITED -> assertEquals(7, assertIs<SyncHTTPClientError.RateLimited>(error).retryAfter.seconds)
            }
        }
    }

    private fun errorResponse(envelope: ErrorResponse): HttpResponse =
        HttpResponse(envelope.httpStatus, mapOf("Retry-After" to "7"), ErrorResponse.codec.encode(envelope))

    private fun client(transport: HttpTransport): SyncHTTPClient = SyncHTTPClient(server, transport, credential, clock)

    private fun padded(bytes: ByteArray, count: Int): ByteArray = ByteArray(count) { if (it < bytes.size) bytes[it] else 32 }

    private class RecordingTransport(var response: HttpResponse = HttpResponse(200, body = "{}".toByteArray())) : HttpTransport {
        val requests = mutableListOf<HttpRequest>()
        override suspend fun send(request: HttpRequest): HttpResponse { requests += request; return response }
    }

    private companion object {
        val id = ULID.parse("01ARZ3NDEKTSV4RRFFQ69G5FAV")!!
        val group = ULID.parse("01ARZ3NDEKTSV4RRFFQ69G5FAW")!!
        // Deterministic synthetic bytes, never a server-issued credential.
        val fakeToken = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { it.toByte() })
        val server = SyncServerURL("https://example.com/paw")
        val credential = SyncCredential(server, SecretValue(fakeToken))
        val clock = MonotonicClock { 0L }
        val user = User(id.rawValue, "test", null, AccountKind.MEMBER, "2026-10-14T00:00:00.000Z", null)
        val me = MeResponse(user, emptyList(), listOf(Device(id.rawValue, "Test device", user.createdAt, null, null, true)))
        val prompt = Prompt(id.rawValue, 1, PromptScope.User, "p.md", "synthetic content")
        val write = WriteResponse(1, 1)
        val pull = PullResponse("12345678-1234-1234-1234-123456789abc",
            listOf(SyncScope(ScopeIdentity.User(id.rawValue), Mode.SNAPSHOT, 0, "0", false, emptyList())), emptyList())
        val errors = listOf(ErrorResponse.Conflict(ConflictHead(2, PromptScope.Group(group.rawValue), "p.md", "synthetic conflict")),
            ErrorResponse.PathTaken(ExistingPrompt(id.rawValue, 1, "synthetic existing")), ErrorResponse.Deleted,
            ErrorResponse.Validation(listOf(Issue("source.too_large", Severity.ERROR))),
            ErrorResponse.SnapshotExpired(listOf("user:${id.rawValue}"))) + FailureCode.entries.map { ErrorResponse.Failure(it) }
    }
}
