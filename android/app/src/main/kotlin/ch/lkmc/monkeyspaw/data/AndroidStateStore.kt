package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.StateStore
import java.io.File

/** The graph passes filesDir; enumeration includes unknown history sidecars for migration. */
internal class AndroidStateStore(root: File, publication: AtomicPublication = AtomicPublication()) : StateStore by
    RootedFileStore(root, RootedFileStore.Scan.STATE, publication)
