package ch.lkmc.monkeyspaw.data

internal interface ImeSwitchGateway {
    val api: Int
    fun previous(): Boolean
    fun windowToken(): Any?
    fun last(token: Any): Boolean
    fun picker(): Boolean
}

/** The platform owns keyboard/subtype history; no foreign keyboard identifier is retained. */
internal class ImeSwitchBack(private val gateway: ImeSwitchGateway) {
    enum class Result { PREVIOUS, PICKER, UNAVAILABLE, STALE }

    fun switch(isCurrent: () -> Boolean): Result {
        if (!isCurrent()) return Result.STALE
        val switched = try {
            if (gateway.api >= 28) gateway.previous() else {
                val token = gateway.windowToken()
                if (!isCurrent()) return Result.STALE
                token != null && gateway.last(token)
            }
        } catch (_: Exception) { false }
        if (switched) return Result.PREVIOUS
        // A failed platform call can reenter the service and start another input session.
        if (!isCurrent()) return Result.STALE
        return try {
            if (gateway.picker()) Result.PICKER else Result.UNAVAILABLE
        } catch (_: Exception) { Result.UNAVAILABLE }
    }
}
