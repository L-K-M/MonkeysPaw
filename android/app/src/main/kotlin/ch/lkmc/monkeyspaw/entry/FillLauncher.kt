package ch.lkmc.monkeyspaw.entry

/** Activity navigation boundary; JVM tests supply a launch callback instead of an Android runtime. */
internal class FillLauncher(private val start: (String) -> Unit) {
    private var opening = false

    fun open(path: String) {
        if (opening) return
        opening = true
        try { start(path) }
        catch (error: Exception) { opening = false; throw error }
    }

    // MainActivity can accept another activation after the fill Activity returns.
    fun resumed() { opening = false }
}
