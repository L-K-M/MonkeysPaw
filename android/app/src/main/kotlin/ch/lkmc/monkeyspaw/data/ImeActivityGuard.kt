package ch.lkmc.monkeyspaw.data

import javax.inject.Inject
import javax.inject.Singleton

/** Local lifecycle state only: the IME never identifies our editors through target metadata. */
@Singleton
internal class ImeActivityGuard @Inject constructor() {
    private var foreground: Any? = null
    val inFillActivity: Boolean get() = foreground != null

    fun resume(owner: Any) { foreground = owner }
    fun pause(owner: Any) { if (foreground === owner) foreground = null }
}
