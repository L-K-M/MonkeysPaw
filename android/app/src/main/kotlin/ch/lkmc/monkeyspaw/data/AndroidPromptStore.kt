package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.PromptStore
import ch.lkmc.monkeyspaw.core.ports.SyncFileOperations
import java.io.File

/** The graph passes filesDir/library; local Groups and Conflicts are ordinary directories. */
internal class AndroidPromptStore private constructor(private val files: RootedFileStore, io: CheckedSyncIO) : PromptStore by files {
    constructor(root: File, publication: AtomicPublication = AtomicPublication(), io: CheckedSyncIO = AndroidCheckedSyncIO()) :
        this(RootedFileStore(root, RootedFileStore.Scan.LIBRARY, publication), io)

    val syncOperations: SyncFileOperations = AndroidSyncFileOperations(files, io)

    fun prepareRoot() = files.prepareRoot()
    fun requireRoot() = files.requireRoot()
}
