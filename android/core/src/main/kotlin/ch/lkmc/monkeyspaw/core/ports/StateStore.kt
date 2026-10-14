package ch.lkmc.monkeyspaw.core.ports

/** App-private data root: history/<identity>/, usage/<identity>, and values.json. */
interface StateStore : PromptStore {
    /** Set mode 0600 before writing private bytes; atomically replace only after a successful flush. */
    fun writePrivate(bytes: ByteArray, path: String)
}
