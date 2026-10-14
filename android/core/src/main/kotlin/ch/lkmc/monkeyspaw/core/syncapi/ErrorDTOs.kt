package ch.lkmc.monkeyspaw.core.syncapi

import ch.lkmc.monkeyspaw.core.domain.Limits

enum class FailureCode(val wireValue: String, val httpStatus: Int) {
    UNAUTHORIZED("unauthorized", 401), FORBIDDEN("forbidden", 403), NOT_FOUND("not_found", 404),
    MALFORMED_REQUEST("malformed_request", 400), ENVELOPE_TOO_LARGE("envelope_too_large", 413),
    RATE_LIMITED("rate_limited", 429), INTERNAL_ERROR("internal_error", 500);

    companion object { val codec = enumCodec("FailureCode", entries) { it.wireValue } }
}

/** Status is transport metadata; error envelopes never carry underlying error text. */
sealed interface ErrorResponse {
    val httpStatus: Int
    data class Conflict(val head: ConflictHead) : ErrorResponse { override val httpStatus: Int get() = 409 }
    data class PathTaken(val existing: ExistingPrompt) : ErrorResponse { override val httpStatus: Int get() = 409 }
    data object Deleted : ErrorResponse { override val httpStatus: Int get() = 410 }
    data class Validation(val issues: List<Issue>) : ErrorResponse { override val httpStatus: Int get() = 422 }
    data class Failure(val code: FailureCode) : ErrorResponse { override val httpStatus: Int get() = code.httpStatus }
    data class SnapshotExpired(val scopes: List<String>) : ErrorResponse { override val httpStatus: Int get() = 409 }

    companion object {
        val codec: WireCodec<ErrorResponse> = objectCodec("ErrorResponse", { o ->
            if (o.contains("issues")) {
                o.members(setOf("issues"))
                val issues = o.dtos("issues", Issue.codec)
                wireRequire(issues.isNotEmpty() && issues.all { it.severity == Severity.ERROR })
                Validation(issues)
            } else when (o.string("code")) {
                "conflict" -> {
                    o.members(setOf("code", "head"))
                    Conflict(o.dto("head", ConflictHead.codec))
                }
                "path_taken" -> {
                    o.members(setOf("code", "existing"))
                    PathTaken(o.dto("existing", ExistingPrompt.codec))
                }
                "deleted" -> { o.members(setOf("code")); Deleted }
                "snapshot_expired" -> {
                    o.members(setOf("code", "scopes"))
                    val scopes = o.strings("scopes", WireValidation::scopeKey)
                    wireRequire(scopes.isNotEmpty() && scopes.toSet().size == scopes.size)
                    SnapshotExpired(scopes)
                }
                else -> {
                    o.members(setOf("code"))
                    Failure(o.dto("code", FailureCode.codec))
                }
            }
        }, { error ->
            when (error) {
                is Conflict -> wireObject("code" to wireString("conflict"), "head" to ConflictHead.codec.encodeValue(error.head))
                is PathTaken -> wireObject("code" to wireString("path_taken"), "existing" to ExistingPrompt.codec.encodeValue(error.existing))
                Deleted -> wireObject("code" to wireString("deleted"))
                is Validation -> wireObject("issues" to wireDtos(error.issues, Issue.codec))
                is Failure -> wireObject("code" to FailureCode.codec.encodeValue(error.code))
                is SnapshotExpired -> wireObject("code" to wireString("snapshot_expired"),
                    "scopes" to WireValue.ArrayValue(error.scopes.map(::wireString)))
            }
        })
    }
}

/** Whole seconds for the 429 header; JSON integer representation supports schema tooling. */
data class RetryAfter(val seconds: Long) {
    init { wireRequire(seconds in 1..Limits.maxRetryAfterSeconds) }

    constructor(headerValue: String) : this(parseHeader(headerValue))

    val headerValue: String get() = seconds.toString()

    companion object {
        val codec = WireCodec("RetryAfter", { value -> RetryAfter(value.longValue()) }, { wireLong(it.seconds) })

        private fun parseHeader(header: String): Long {
            val seconds = header.toLongOrNull() ?: throw WireContractException()
            wireRequire(seconds.toString() == header)
            return seconds
        }
    }
}
