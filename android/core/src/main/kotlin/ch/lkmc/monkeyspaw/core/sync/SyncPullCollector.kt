package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator
import ch.lkmc.monkeyspaw.core.domain.sync.SyncError
import ch.lkmc.monkeyspaw.core.domain.sync.SyncIdentifiers
import ch.lkmc.monkeyspaw.core.domain.sync.SyncScopeKey
import ch.lkmc.monkeyspaw.core.domain.sync.syncMapCopy
import ch.lkmc.monkeyspaw.core.ports.MonotonicClock
import ch.lkmc.monkeyspaw.core.ports.StateStore
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.util.UUID

/** Collects only, with no library, persistent sync-state or journal capability. */
internal class SyncPullCollector(
    private val client: SyncHTTPClient,
    private val files: StateStore,
    private val userID: ULID,
    private val clock: MonotonicClock = MonotonicClock(System::nanoTime),
) {
    /** Initial opaque cursors must come from completed, committed application, never an in-flight snapshot. */
    suspend fun collect(initial: PullRequest, deadlineNanos: Long? = null): SyncCollectedPull {
        val start = clock.nowNanos()
        val remaining = deadlineNanos?.let { (it - start).coerceAtMost(Limits.syncCollectionBudgetNanos) }
            ?: Limits.syncCollectionBudgetNanos
        val deadline = start + remaining
        val original = PullRequest(initial.databaseID, initial.cursors.syncMapCopy())
        validate(original)
        var request = original
        var staging = SyncPullStaging(files)
        val scopes = linkedMapOf<SyncScopeKey, ScopeProgress>()
        val removed = mutableSetOf<SyncScopeKey>()
        val initialKeys = original.cursors.keys.map(SyncScopeKey::parse).toSet()
        var databaseID: UUID? = null
        var restarts = 0

        try {
            while (true) {
                check(deadline)
                val response: PullResponse
                try { response = client.pull(request, deadline) }
                catch (error: SyncHTTPClientError.SnapshotExpired) {
                    check(deadline)
                    val keys = error.scopes
                    if (keys.isEmpty() || keys.toSet().size != keys.size || keys.any { it !in request.cursors }) {
                        throw SyncPullCollectorError.InvalidResponse
                    }
                    if (restarts >= Limits.syncCollectionRestartLimit) {
                        throw SyncPullCollectorError.NoProgress(SyncPullCollectorError.Reason.SNAPSHOT_EXPIRED)
                    }
                    restarts++
                    // Advanced cursors from discarded pages would lose their deltas.
                    request = PullRequest(original.databaseID, original.cursors - keys.toSet())
                    staging.discard()
                    staging = SyncPullStaging(files)
                    scopes.clear()
                    removed.clear()
                    databaseID = null
                    continue
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    check(deadline)
                    throw error
                }
                check(deadline)
                val responseID = validate(response, request)
                if (databaseID != null && databaseID != responseID) {
                    if (restarts >= Limits.syncCollectionRestartLimit) {
                        throw SyncPullCollectorError.NoProgress(SyncPullCollectorError.Reason.DATABASE_CHANGED)
                    }
                    restarts++
                    // Old signed continuations cannot name a new database's manifests.
                    request = PullRequest(null, emptyMap())
                    staging.discard()
                    staging = SyncPullStaging(files)
                    scopes.clear()
                    removed.clear()
                    // Never stage the response that detected the change.
                    databaseID = null
                    continue
                }
                databaseID = responseID

                for (raw in response.removed) {
                    val key = SyncScopeKey.parse(raw)
                    scopes.remove(key)
                    removed.add(key)
                }
                var completedScope = false
                for (page in response.scopes) {
                    val key = SyncScopeKey.parse(page.identity.key)
                    removed.remove(key)
                    val previous = scopes[key]
                    completedScope = completedScope || previous?.hasMore == true && !page.hasMore
                    scopes[key] = progress(page, previous, staging.pageCount, request.cursors[key.rawValue])
                }
                val cursors = scopes.entries.associate { it.key.rawValue to it.value.scope.cursor }
                val hasMore = response.scopes.any { it.hasMore }
                // JVM String equality preserves exact UTF-8 spelling, without normalization.
                if (hasMore && !completedScope && cursors == request.cursors) {
                    throw SyncPullCollectorError.NoProgress(SyncPullCollectorError.Reason.STALLED_CONTINUATION)
                }
                check(deadline)
                staging.append(response)
                check(deadline)
                if (!hasMore) {
                    removed.addAll(initialKeys - scopes.keys)
                    return SyncCollectedPull(responseID, scopes.mapValues { it.value.scope }, removed, staging)
                }
                request = PullRequest(response.databaseID, cursors)
            }
        } catch (error: Exception) {
            staging.discard()
            throw error
        }
    }

    private data class ScopeProgress(
        val scope: SyncCollectedScope,
        val mode: Mode,
        val hasMore: Boolean,
        val lastSnapshotID: String?,
        val lastDeltaSeq: Long,
    )

    private fun progress(page: SyncScope, previous: ScopeProgress?, index: Int, requestCursor: String?): ScopeProgress {
        val continuingSnapshot = previous?.mode == Mode.SNAPSHOT && previous.hasMore
        if (continuingSnapshot && (page.mode != Mode.SNAPSHOT || page.head != previous.scope.snapshotHead)) {
            throw SyncPullCollectorError.InvalidResponse
        }
        val newSnapshot = page.mode == Mode.SNAPSHOT && !continuingSnapshot
        var lastID = if (newSnapshot) null else previous?.lastSnapshotID
        var lastSeq = if (newSnapshot) page.head else previous?.lastDeltaSeq ?: 0
        for (item in page.items) {
            if (page.mode == Mode.SNAPSHOT) {
                if (item !is FeedItem.Upsert || lastID?.let { it >= item.prompt.id } == true) {
                    throw SyncPullCollectorError.InvalidResponse
                }
                lastID = item.prompt.id
            } else {
                if (item.seq <= lastSeq) throw SyncPullCollectorError.InvalidResponse
                lastSeq = item.seq
            }
        }
        if (page.mode == Mode.DELTA && page.items.isNotEmpty() && page.cursor == requestCursor) {
            throw SyncPullCollectorError.InvalidResponse
        }
        val scope = SyncCollectedScope(page.identity, page.head, page.cursor,
            if (newSnapshot) page.head else previous?.scope?.snapshotHead,
            if (newSnapshot) index else previous?.scope?.firstPage ?: index)
        return ScopeProgress(scope, page.mode, page.hasMore, lastID, lastSeq)
    }

    private fun validate(request: PullRequest) {
        try {
            PullRequest.codec.decodeValue(PullRequest.codec.encodeValue(request))
            for (raw in request.cursors.keys) {
                val key = SyncScopeKey.parse(raw)
                if (key is SyncScopeKey.User && key.id != userID) throw SyncPullCollectorError.InvalidRequest
            }
        } catch (_: IllegalArgumentException) { throw SyncPullCollectorError.InvalidRequest }
        catch (_: SyncError) { throw SyncPullCollectorError.InvalidRequest }
    }

    private fun validate(response: PullResponse, request: PullRequest): UUID {
        try {
            val databaseID = SyncIdentifiers.uuid(response.databaseID)
            val keys = response.scopes.map { it.identity.key }.toSet()
            if (request.cursors.keys.any { it !in keys && it !in response.removed }) {
                throw SyncPullCollectorError.InvalidResponse
            }
            if (response.removed.any { SyncScopeKey.parse(it) !is SyncScopeKey.Group }) {
                throw SyncPullCollectorError.InvalidResponse
            }
            for (page in response.scopes) {
                val key = SyncScopeKey.parse(page.identity.key)
                if (key is SyncScopeKey.User && key.id != userID) throw SyncPullCollectorError.InvalidResponse
                if (page.mode == Mode.DELTA && (key.rawValue !in request.cursors || request.databaseID != response.databaseID)) {
                    throw SyncPullCollectorError.InvalidResponse
                }
                for (item in page.items) {
                    if (item is FeedItem.Upsert) {
                        SyncIdentifiers.ulid(item.prompt.id)
                        if (SyncPathValidator.validate(item.prompt.path, key.pathScope).path != item.prompt.path) {
                            throw SyncPullCollectorError.InvalidResponse
                        }
                    } else {
                        SyncIdentifiers.ulid(when (item) {
                            is FeedItem.Delete -> item.id
                            is FeedItem.MoveOut -> item.id
                        })
                    }
                }
            }
            return databaseID
        } catch (_: IllegalArgumentException) { throw SyncPullCollectorError.InvalidResponse }
        catch (_: SyncError) { throw SyncPullCollectorError.InvalidResponse }
    }

    private suspend fun check(deadline: Long) {
        currentCoroutineContext().ensureActive()
        if (deadline - clock.nowNanos() <= 0) {
            throw SyncPullCollectorError.NoProgress(SyncPullCollectorError.Reason.COLLECTION_DEADLINE)
        }
    }
}
