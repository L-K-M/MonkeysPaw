package ch.lkmc.monkeyspaw.core.ports

/** App-private state: history/<identity>/, usage/<identity>, values.json and logical provider JSON.
 * Android maps provider-settings.json/provider-state.json to records in its single settings DataStore.
 */
interface StateStore : PromptStore {
    /** Set mode 0600 before writing private bytes; atomically replace only after a successful flush. */
    fun writePrivate(bytes: ByteArray, path: String)
}
