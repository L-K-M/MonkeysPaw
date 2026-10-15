package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.sync.SyncError
import ch.lkmc.monkeyspaw.core.domain.sync.SyncLibraryIdentity
import kotlinx.coroutines.Job
import java.util.concurrent.CancellationException
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * One graph generation. Retirement and synchronous mutation admission share a lock.
 * An admitted transaction finishes its durable work even after retirement/cancellation.
 * The lock never spans IO, HTTP, or draining the owning coroutine.
 */
internal class SyncWorkPermit(val binding: SyncLibraryIdentity, val epoch: Long, private val job: Job? = null) {
    private val lock = ReentrantLock()
    private var retired = false
    private var admitted = 0

    init { if (epoch < 0) throw SyncError.InvalidState }

    fun check() = lock.withLock { requireAdmission() }

    fun validate(binding: SyncLibraryIdentity) {
        check()
        if (binding != this.binding) throw SyncError.BindingMismatch
    }

    /** True means already drained. False requires the owner to drain off the UI thread. */
    fun revoke(): Boolean = lock.withLock { retired = true; admitted == 0 }
    val isDrained: Boolean get() = lock.withLock { admitted == 0 }

    fun <T> mutate(work: () -> T): T {
        lock.withLock { requireAdmission(); admitted++ }
        try { return work() }
        finally { lock.withLock { admitted-- } }
    }

    private fun requireAdmission() {
        if (retired || job?.isActive == false || Thread.currentThread().isInterrupted) {
            throw CancellationException("Sync work was cancelled.")
        }
    }

    override fun toString(): String = "<sync work permit>"
}
