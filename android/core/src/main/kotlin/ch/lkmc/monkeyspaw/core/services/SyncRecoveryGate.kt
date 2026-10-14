package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.sync.SyncState
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Library admission takes its lock first; keyed writers check under their own store lock. */
internal class SyncRecoveryGate {
    data class Permit(val id: UUID, val nextState: SyncState)
    private val lock = ReentrantLock()
    private var owner: Permit? = null
    private var recoveryBlocked = false

    fun requireEditable() = lock.withLock {
        if (owner != null || recoveryBlocked) throw LibraryError.RecoveryRequired
    }

    fun begin(id: UUID, nextState: SyncState) = lock.withLock {
        if (recoveryBlocked || owner?.id?.let { it != id } == true) throw LibraryError.RecoveryRequired
        owner = Permit(id, nextState)
    }

    fun finish(id: UUID) = lock.withLock {
        if (!recoveryBlocked && owner?.id == id) owner = null
    }

    fun replace(previous: UUID, next: UUID, nextState: SyncState) = lock.withLock {
        if (recoveryBlocked || owner?.id != previous) throw LibraryError.RecoveryRequired
        owner = Permit(next, nextState)
    }

    /** Only serialized replay may adopt a validated on-disk intent and clear the read-failure latch. */
    fun resume(id: UUID, nextState: SyncState) = lock.withLock {
        owner = Permit(id, nextState)
        recoveryBlocked = false
    }

    val pendingPermit: Permit? get() = lock.withLock { owner }
    val hasUnreadableJournal: Boolean get() = lock.withLock { recoveryBlocked }

    /** Keep live intended-state evidence after an uncertain journal deletion or failed read. */
    fun blockForRecovery() = lock.withLock { recoveryBlocked = true }

    /** Validated durable empty recovery cannot discard an owner's uncommitted intent. */
    fun finishEmptyRecovery() = lock.withLock { if (owner == null) recoveryBlocked = false }
}

/** A shared keyed store must honor every live graph, without retaining retired graphs. */
internal class SyncKeyedWriteGates {
    private val references = mutableListOf<WeakReference<SyncRecoveryGate>>()

    fun bind(gate: SyncRecoveryGate) {
        references.removeAll { it.get() == null }
        if (references.none { it.get() === gate }) references.add(WeakReference(gate))
    }

    fun requireEditable() {
        references.removeAll { it.get() == null }
        references.forEach { it.get()?.requireEditable() }
    }
}
