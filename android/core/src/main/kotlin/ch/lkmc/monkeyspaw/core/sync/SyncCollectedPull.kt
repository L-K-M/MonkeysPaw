package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.SyncScopeKey
import ch.lkmc.monkeyspaw.core.domain.sync.syncListCopy
import ch.lkmc.monkeyspaw.core.domain.sync.syncMapCopy
import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.util.Collections
import java.util.UUID

internal sealed class SyncPullCollectorError private constructor() : Exception("Sync collection failed.", null, false, true) {
    enum class Reason { SNAPSHOT_EXPIRED, DATABASE_CHANGED, STALLED_CONTINUATION, COLLECTION_DEADLINE }
    class NoProgress(val reason: Reason) : SyncPullCollectorError()
    data object InvalidRequest : SyncPullCollectorError()
    data object InvalidResponse : SyncPullCollectorError()
    class StagingFailed(val error: StoreError) : SyncPullCollectorError()

    final override fun toString(): String = "<sync collection error redacted>"
}

internal data class SyncCollectedScope(
    val identity: ScopeIdentity,
    val head: Long,
    val cursor: String,
    /** Null for a delta-only scope; otherwise the complete frozen snapshot head. */
    val snapshotHead: Long?,
    internal val firstPage: Int,
) {
    override fun toString(): String = "<collected sync scope>"
}

internal data class SyncCollectedItem(val scope: SyncScopeKey, val item: FeedItem) {
    val seq: Long get() = item.seq
    override fun toString(): String = "<collected sync item>"
}

internal class SyncCollectedPage(val scope: SyncScopeKey, val mode: Mode, items: List<SyncCollectedItem>) {
    val items = items.syncListCopy()
    override fun toString(): String = "<collected sync page>"
}

/**
 * Only complete collections escape. Read snapshots first, then fold deltas by
 * global seq before planning mutations. Use/close after journal preparation;
 * these private pages are transient and never authorize crash resumption.
 */
internal class SyncCollectedPull internal constructor(
    val databaseID: UUID,
    scopes: Map<SyncScopeKey, SyncCollectedScope>,
    removed: Set<SyncScopeKey>,
    private val staging: SyncPullStaging,
) : AutoCloseable {
    val scopes = scopes.syncMapCopy()
    val removed: Set<SyncScopeKey> = Collections.unmodifiableSet(LinkedHashSet(removed))
    val cursors: Map<SyncScopeKey, String> get() = scopes.mapValues { it.value.cursor }.syncMapCopy()

    /** Load one capped response at a time; omit removed and superseded segments. */
    fun forEachPage(mode: Mode, consume: (SyncCollectedPage) -> Unit) {
        for (index in 0 until staging.pageCount) {
            val response = staging.read(index)
            if (response.databaseID != databaseID.toString()) throw SyncPullCollectorError.InvalidResponse
            for (page in response.scopes) {
                if (page.mode != mode) continue
                val key = SyncScopeKey.parse(page.identity.key)
                val scope = scopes[key] ?: continue
                if (index < scope.firstPage) continue
                consume(SyncCollectedPage(key, mode, page.items.map { SyncCollectedItem(key, it) }))
            }
        }
    }

    fun discard() = staging.discard()
    override fun close() = discard()
    override fun toString(): String = "<collected sync pull>"
}

/** Filenames derive from a UUID and count, without retaining paths or prompt bodies. */
internal class SyncPullStaging(private val files: StateStore) {
    private val id = UUID.randomUUID().toString()
    var pageCount = 0
        private set
    private var discarded = false

    fun append(response: PullResponse) {
        if (discarded) throw SyncPullCollectorError.InvalidResponse
        val bytes = try { PullResponse.codec.encode(response) }
        catch (_: IllegalArgumentException) { throw SyncPullCollectorError.InvalidResponse }
        if (bytes.size > Limits.syncResponseCap) throw SyncPullCollectorError.InvalidResponse
        val path = path(pageCount)
        // Include a failed publication in cleanup even if its driver left a file.
        pageCount++
        operation { files.writePrivate(bytes, path) }
    }

    fun read(index: Int): PullResponse {
        if (discarded) throw SyncPullCollectorError.InvalidResponse
        val bytes = operation { files.read(path(index)) }
        if (bytes.size > Limits.syncResponseCap) throw SyncPullCollectorError.InvalidResponse
        return try { PullResponse.codec.decode(bytes) }
        catch (_: IllegalArgumentException) { throw SyncPullCollectorError.InvalidResponse }
    }

    fun discard() {
        if (discarded) return
        var failure: SyncPullCollectorError.StagingFailed? = null
        for (index in 0 until pageCount) {
            try { operation { files.delete(path(index)) } }
            catch (error: SyncPullCollectorError.StagingFailed) {
                if (error.error != StoreError.NotFound) failure = error
            }
        }
        if (failure != null) throw failure
        discarded = true
    }

    private fun path(index: Int): String = "sync/pull-$id-$index.json"

    private fun <T> operation(body: () -> T): T = try { body() }
    catch (error: StoreError) { throw SyncPullCollectorError.StagingFailed(error) }
    catch (_: Exception) { throw SyncPullCollectorError.StagingFailed(StoreError.IOFailure) }
}
