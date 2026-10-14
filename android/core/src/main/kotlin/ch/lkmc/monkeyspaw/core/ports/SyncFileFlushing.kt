package ch.lkmc.monkeyspaw.core.ports

/** Checked durability for the same private root as the supplied StateStore.
 * Calls throw on failure, including unsupported directory flushes. Atomic writes
 * alone do not establish this contract. Later sync file operations extend it.
 */
interface SyncFileFlushing {
    fun flushFile(path: String)
    /** Null names the store root, otherwise an exact relative directory path. */
    fun flushDirectory(path: String?)
}
