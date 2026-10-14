package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.PromptStore
import java.io.File

/** The graph passes filesDir/library; local Groups and Conflicts are ordinary directories. */
internal class AndroidPromptStore private constructor(private val files: RootedFileStore) : PromptStore by files {
    constructor(root: File, publication: AtomicPublication = AtomicPublication()) :
        this(RootedFileStore(root, RootedFileStore.Scan.LIBRARY, publication))

    fun prepareRoot() = files.prepareRoot()
    fun requireRoot() = files.requireRoot()
}
