package ch.lkmc.monkeyspaw.core.ports

interface Clipboard {
    /** On the driver's UI thread. A failed write must throw before the caller records any learning. */
    fun writeText(text: String)
    /** On the driver's UI thread; complete exactly once there, inline or later. Null means unavailable. */
    fun readText(completion: (String?) -> Unit)
}
