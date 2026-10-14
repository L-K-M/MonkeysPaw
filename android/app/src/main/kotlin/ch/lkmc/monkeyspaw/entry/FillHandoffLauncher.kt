package ch.lkmc.monkeyspaw.entry

/** End the source form after a successful launch; cancel only failed or abandoned transfers. */
internal class FillHandoffLauncher(
    private val handoffs: FillHandoffStore,
    private val launch: (String) -> Unit,
) {
    private var token: String? = null

    fun open(handoff: FillHandoff): Boolean {
        if (token != null) return false
        val offered = handoffs.offer(handoff)
        token = offered
        return try {
            launch(offered)
            token == offered
        } catch (_: Exception) {
            handoffs.clear(offered)
            if (token == offered) token = null
            false
        }
    }

    fun cancel() {
        token?.let(handoffs::clear)
        token = null
    }
}
