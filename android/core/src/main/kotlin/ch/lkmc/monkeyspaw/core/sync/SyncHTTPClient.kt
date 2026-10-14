package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.domain.llm.immutableCopy
import ch.lkmc.monkeyspaw.core.ports.HttpMethod
import ch.lkmc.monkeyspaw.core.ports.HttpRequest
import ch.lkmc.monkeyspaw.core.ports.HttpResponse
import ch.lkmc.monkeyspaw.core.ports.HttpTransport
import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import ch.lkmc.monkeyspaw.core.ports.HttpUrlPolicy
import ch.lkmc.monkeyspaw.core.ports.MonotonicClock
import ch.lkmc.monkeyspaw.core.ports.SyncTLSTrust
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration.Companion.nanoseconds

/** Z14 persists the server/user envelope; this binding prevents token forwarding. */
internal data class SyncCredential(val server: SyncServerURL, val token: SecretValue) {
    fun authorization(forServer: SyncServerURL): String {
        if (server != forServer) throw SyncHTTPClientError.CredentialServerMismatch
        return token.withValue {
            try { WireValidation.token(it) }
            catch (_: IllegalArgumentException) { throw SyncHTTPClientError.InvalidRequest }
            "Bearer $it"
        }
    }

    override fun toString(): String = "<sync credential redacted>"
}

internal data class SyncAuthentication(val credential: SyncCredential, val user: User) {
    override fun toString(): String = "<sync authentication redacted>"
}

/** Payloads are available to the engine, but exceptions retain no cause or diagnostic body. */
internal sealed class SyncHTTPClientError private constructor() : Exception("Sync HTTP failed.", null, false, true) {
    class Conflict(val head: ConflictHead) : SyncHTTPClientError()
    class PathTaken(val existing: ExistingPrompt) : SyncHTTPClientError()
    data object Deleted : SyncHTTPClientError()
    class Validation(issues: List<Issue>) : SyncHTTPClientError() { val issues = issues.immutableCopy() }
    class SnapshotExpired(scopes: List<String>) : SyncHTTPClientError() { val scopes = scopes.immutableCopy() }
    data object MalformedRequest : SyncHTTPClientError()
    data object Unauthorized : SyncHTTPClientError()
    data object Forbidden : SyncHTTPClientError()
    data object NotFound : SyncHTTPClientError()
    data object EnvelopeTooLarge : SyncHTTPClientError()
    class RateLimited(val retryAfter: RetryAfter) : SyncHTTPClientError()
    class ServerFailure(val statusCode: Int) : SyncHTTPClientError()
    class StatusEnvelopeMismatch(val statusCode: Int) : SyncHTTPClientError()
    data object MalformedResponse : SyncHTTPClientError()
    data object InvalidRequest : SyncHTTPClientError()
    data object CredentialServerMismatch : SyncHTTPClientError()
    class Transport(val error: HttpTransportError) : SyncHTTPClientError()

    final override fun toString(): String = "<sync HTTP error redacted>"
}

/** One attempt over the shared port/codecs. No persistence or engine decisions. */
internal class SyncHTTPClient(
    val server: SyncServerURL,
    private val transport: HttpTransport,
    private val credential: SyncCredential? = null,
    private val clock: MonotonicClock = MonotonicClock(System::nanoTime),
    private val trust: SyncTLSTrust = SyncTLSTrust.SYSTEM,
) {
    fun permitting(permit: SyncWorkPermit): SyncHTTPClient =
        SyncHTTPClient(server, SyncPermittedTransport(transport, permit), credential, clock, trust)

    suspend fun login(request: LoginRequest, deadlineNanos: Long? = null): SyncAuthentication =
        authentication(send(HttpMethod.POST, "/auth/login", AuthResponse.codec, encode(request, LoginRequest.codec),
            authentication = Authentication.NONE, deadlineNanos = deadlineNanos))

    suspend fun register(request: RegisterRequest, deadlineNanos: Long? = null): SyncAuthentication =
        authentication(send(HttpMethod.POST, "/auth/register", AuthResponse.codec, encode(request, RegisterRequest.codec),
            authentication = Authentication.NONE, deadlineNanos = deadlineNanos))

    suspend fun logout(deadlineNanos: Long? = null) {
        send(HttpMethod.POST, "/auth/logout", EmptyResponse.codec, deadlineNanos = deadlineNanos)
    }

    suspend fun me(deadlineNanos: Long? = null): MeResponse =
        send(HttpMethod.GET, "/me", MeResponse.codec, deadlineNanos = deadlineNanos)

    suspend fun devices(deadlineNanos: Long? = null): List<Device> = me(deadlineNanos).devices

    suspend fun revokeDevice(id: ULID, deadlineNanos: Long? = null) {
        send(HttpMethod.DELETE, "/me/devices/${id.rawValue}", EmptyResponse.codec, deadlineNanos = deadlineNanos)
    }

    suspend fun prompt(id: ULID, deadlineNanos: Long? = null): Prompt =
        send(HttpMethod.GET, "/prompts/${id.rawValue}", Prompt.codec, deadlineNanos = deadlineNanos)

    suspend fun putPrompt(id: ULID, request: PutPromptRequest, deadlineNanos: Long? = null): WriteResponse =
        send(HttpMethod.PUT, "/prompts/${id.rawValue}", WriteResponse.codec, encode(request, PutPromptRequest.codec),
            deadlineNanos = deadlineNanos)

    suspend fun deletePrompt(id: ULID, baseRev: Long, deadlineNanos: Long? = null): WriteResponse {
        encode(DeletePromptQuery(baseRev), DeletePromptQuery.codec)
        return send(HttpMethod.DELETE, "/prompts/${id.rawValue}?base_rev=$baseRev", WriteResponse.codec,
            deadlineNanos = deadlineNanos)
    }

    suspend fun movePrompt(id: ULID, request: MovePromptRequest, deadlineNanos: Long? = null): WriteResponse =
        send(HttpMethod.POST, "/prompts/${id.rawValue}/move", WriteResponse.codec, encode(request, MovePromptRequest.codec),
            deadlineNanos = deadlineNanos)

    suspend fun pull(request: PullRequest, deadlineNanos: Long? = null): PullResponse =
        send(HttpMethod.POST, "/sync/pull", PullResponse.codec, encode(request, PullRequest.codec), deadlineNanos = deadlineNanos)

    suspend fun joinGroup(request: JoinGroupRequest, deadlineNanos: Long? = null): GroupMembership =
        send(HttpMethod.POST, "/groups/join", GroupMembership.codec, encode(request, JoinGroupRequest.codec), deadlineNanos = deadlineNanos)

    private enum class Authentication { NONE, BEARER }

    private fun authentication(response: AuthResponse): SyncAuthentication =
        SyncAuthentication(SyncCredential(server, SecretValue(response.deviceToken)), response.user)

    private fun <T> encode(value: T, codec: WireCodec<T>): ByteArray {
        val bytes = try { codec.encode(value) }
        catch (_: IllegalArgumentException) { throw SyncHTTPClientError.InvalidRequest }
        if (bytes.size > Limits.httpRequestCap) throw SyncHTTPClientError.Transport(HttpTransportError.RequestTooLarge)
        return bytes
    }

    private suspend fun checkActive(deadline: Long) {
        currentCoroutineContext().ensureActive()
        if (deadline - clock.nowNanos() <= 0) throw HttpTransportError.DeadlineExceeded
    }

    private suspend fun <T : Any> send(
        method: HttpMethod,
        relative: String,
        codec: WireCodec<T>,
        body: ByteArray? = null,
        authentication: Authentication = Authentication.BEARER,
        deadlineNanos: Long?,
    ): T = try {
        currentCoroutineContext().ensureActive()
        val now = clock.nowNanos()
        val remaining = deadlineNanos?.let { (it - now).coerceAtMost(Limits.syncRequestTimeoutNanos) }
            ?: Limits.syncRequestTimeoutNanos
        if (remaining <= 0) throw HttpTransportError.DeadlineExceeded
        val deadline = now + remaining
        withTimeoutOrNull(remaining.nanoseconds) {
            val url = server.validatedRequestURL(server.apiURL + relative)
            val headers = linkedMapOf("Accept" to "application/json")
            if (body != null) headers["Content-Type"] = "application/json"
            if (authentication == Authentication.BEARER) {
                headers["Authorization"] = (credential ?: throw SyncHTTPClientError.Unauthorized).authorization(server)
            }
            val request = HttpRequest(url, method, headers, body, requestByteCap = Limits.httpRequestCap,
                responseByteCap = if (codec === PullResponse.codec) Limits.syncResponseCap else Limits.responseCap,
                deadlineNanos = deadline, urlPolicy = HttpUrlPolicy.Sync(server, trust))
            checkActive(deadline)
            val response = try { transport.send(request) }
            catch (error: CancellationException) {
                // A timeout scope can replace cancellation causes; surface its recorded failure first.
                val failure = generateSequence<Throwable>(error) { it.cause }.filterIsInstance<HttpTransportError>().firstOrNull()
                if (failure != null && failure != HttpTransportError.Cancelled) throw failure
                throw error
            }
            checkActive(deadline)
            if (response.bodyByteCount > request.responseByteCap) throw HttpTransportError.ResponseTooLarge
            if (response.statusCode in 300..399) throw HttpTransportError.RedirectRefused
            val bytes = response.body
            if (response.statusCode != 200) {
                val error = if (decodes(bytes, codec)) SyncHTTPClientError.StatusEnvelopeMismatch(response.statusCode)
                    else responseError(response, bytes)
                checkActive(deadline)
                throw error
            }
            val decoded = try { codec.decode(bytes) }
            catch (_: IllegalArgumentException) {
                if (decodes(bytes, ErrorResponse.codec)) throw SyncHTTPClientError.StatusEnvelopeMismatch(response.statusCode)
                throw SyncHTTPClientError.MalformedResponse
            }
            checkActive(deadline)
            decoded
        } ?: throw HttpTransportError.DeadlineExceeded
    } catch (error: CancellationException) { throw error }
    catch (error: HttpTransportError) {
        // A queued failure can resume after caller cancellation; retain its cause without failing the launch.
        if (error == HttpTransportError.Cancelled || !currentCoroutineContext().isActive) {
            throw CancellationException(error.message, error)
        }
        throw SyncHTTPClientError.Transport(error)
    } catch (error: SyncHTTPClientError) {
        if (!currentCoroutineContext().isActive) throw CancellationException("Sync HTTP cancelled.", error)
        throw error
    } catch (_: Exception) {
        currentCoroutineContext().ensureActive()
        throw SyncHTTPClientError.Transport(HttpTransportError.NetworkFailure)
    }

    private fun <T> decodes(bytes: ByteArray, codec: WireCodec<T>): Boolean = try { codec.decode(bytes); true }
    catch (_: IllegalArgumentException) { false }

    private fun responseError(response: HttpResponse, bytes: ByteArray): SyncHTTPClientError {
        val envelope = try { ErrorResponse.codec.decode(bytes) }
        catch (_: IllegalArgumentException) {
            return if (response.statusCode in 500..599) SyncHTTPClientError.ServerFailure(response.statusCode)
                else SyncHTTPClientError.MalformedResponse
        }
        if (envelope.httpStatus != response.statusCode) return SyncHTTPClientError.StatusEnvelopeMismatch(response.statusCode)
        return when (envelope) {
            is ErrorResponse.Conflict -> SyncHTTPClientError.Conflict(envelope.head)
            is ErrorResponse.PathTaken -> SyncHTTPClientError.PathTaken(envelope.existing)
            ErrorResponse.Deleted -> SyncHTTPClientError.Deleted
            is ErrorResponse.Validation -> SyncHTTPClientError.Validation(envelope.issues)
            is ErrorResponse.SnapshotExpired -> SyncHTTPClientError.SnapshotExpired(envelope.scopes)
            is ErrorResponse.Failure -> when (envelope.code) {
                FailureCode.MALFORMED_REQUEST -> SyncHTTPClientError.MalformedRequest
                FailureCode.UNAUTHORIZED -> SyncHTTPClientError.Unauthorized
                FailureCode.FORBIDDEN -> SyncHTTPClientError.Forbidden
                FailureCode.NOT_FOUND -> SyncHTTPClientError.NotFound
                FailureCode.ENVELOPE_TOO_LARGE -> SyncHTTPClientError.EnvelopeTooLarge
                FailureCode.INTERNAL_ERROR -> SyncHTTPClientError.ServerFailure(response.statusCode)
                FailureCode.RATE_LIMITED -> {
                    val headers = response.headers.entries.filter { it.key.equals("retry-after", ignoreCase = true) }
                    val retry = try { headers.singleOrNull()?.let { RetryAfter(it.value) } }
                    catch (_: IllegalArgumentException) { null }
                    retry?.let { SyncHTTPClientError.RateLimited(it) } ?: SyncHTTPClientError.MalformedResponse
                }
            }
        }
    }

    override fun toString(): String = "<sync HTTP client redacted>"
}
