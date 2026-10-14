package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.SyncState
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.ranking.Utf8Order
import ch.lkmc.monkeyspaw.core.ports.*
import java.util.UUID

/**
 * One local graph per pair of roots. All synchronous operations belong on an IO worker.
 * Keyed state and history stage before prompt publication and roll back on publication failure.
 * Cross-root crash transactions and filesystem drivers belong to later slices.
 */
class LibraryService(
    private val prompts: PromptStore,
    state: StateStore,
    internal val clock: Clock,
    private val entropy: Entropy,
) {
    internal val mutations = MutationBoundary()
    private val syncGate = SyncRecoveryGate()
    // App callers use library, fill and index intents; keyed stores stay inside Core.
    internal val history = HistoryStore(state, MutationBoundary())
    internal val usage = UsageStore(state, clock, MutationBoundary())
    internal val values = ValuesStore(state, MutationBoundary())
    val index = PromptIndex(this)
    private val keyedStores = listOf<PromptKeyedStore>(history, usage, values)

    init {
        syncKeyedStores().forEach { it.bindSyncWriteGate(syncGate) }
        usage.onRecord = { identity, events ->
            mutations.run { index.acceptUsage(identity, usage.cachedEvents(identity) ?: events) }
        }
    }

    private class LoadedFile(val bytes: ByteArray, val entry: LibraryEntry)
    private enum class SaveMode { REPLACE, CREATE }

    fun entries(): List<LibraryEntry> = locked {
        prompts.listFiles().filter { LibraryPath.isPrompt(it.relativePath) }.sortedWith { a, b ->
            Utf8Order.compare(a.relativePath.encodeToByteArray(), b.relativePath.encodeToByteArray())
        }.map { file ->
            val loaded = requireCurrent(file.relativePath)
            if (loaded.entry.stamp != file.stamp) throw LibraryError.Conflict
            loaded.entry
        }
    }

    fun load(path: String): LibraryEntry = locked { requireCurrent(path).entry }

    fun loadForEditing(path: String): LoadedPrompt = locked {
        val loaded = requireCurrent(path)
        LoadedPrompt(loaded.bytes, loaded.entry)
    }

    /** Null explicitly permits replacement/recreation; normal editing supplies the load stamp. */
    fun save(document: PromptDocument, path: String, expectedStamp: FileStamp? = null): LibrarySaveResult = locked {
        saveDocument(document, path, SaveMode.REPLACE, expectedStamp).also { index.acceptCommitted(it.entry, path) }
    }

    /** Exclusive create never reads or snapshots an occupied prompt destination. */
    fun create(document: PromptDocument, path: String): LibrarySaveResult = locked {
        saveDocument(document, path, SaveMode.CREATE, null).also { index.acceptCommitted(it.entry, path) }
    }

    fun assignIdentity(path: String, expectedStamp: FileStamp? = null): LibrarySaveResult = locked {
        val loaded = requireCurrent(path)
        if (expectedStamp != null && expectedStamp != loaded.entry.stamp) throw LibraryError.Conflict
        if (loaded.entry.document.frontMatter.id != null) return@locked LibrarySaveResult(loaded.entry)
        save(loaded.entry.document, path, loaded.entry.stamp)
    }

    fun toggleFavorite(entry: LibraryEntry): LibrarySaveResult = locked {
        val document = PromptMutations.favorite(!entry.document.frontMatter.favorite, entry.document,
            LibraryPath.filename(entry.relativePath))
        save(document, entry.relativePath, entry.stamp)
    }

    fun move(source: String, destination: String, expectedStamp: FileStamp? = null): LibraryMoveResult = locked {
        LibraryPath.validate(destination)
        val loaded = requireCurrent(source)
        if (expectedStamp != null && loaded.entry.stamp != expectedStamp) throw LibraryError.Conflict
        if (source == destination) return@locked LibraryMoveResult.Moved(loaded.entry)
        if (!isAvailable(destination)) throw LibraryError.DestinationOccupied
        val targetIdentity = PromptIdentity.at(destination, loaded.entry.document.frontMatter.id)
        val migrated = mutableListOf<PromptKeyedStore>()
        try {
            migrate(loaded.entry.identity, targetIdentity, migrated)
            if (prompts.stamp(source) != loaded.entry.stamp) throw LibraryError.Conflict
            try { prompts.move(source, destination) }
            catch (_: StoreError.AlreadyExists) { throw LibraryError.DestinationOccupied }
        } catch (error: Exception) {
            rollback(migrated, targetIdentity, loaded.entry.identity)
            throw error
        }

        val current = checkedLoad(destination)
        if (current is PromptLoadResult.Loaded && current.prompt.sourceBytes.contentEquals(loaded.bytes)) {
            index.acceptCommitted(current.prompt.entry, source)
            return@locked LibraryMoveResult.Moved(current.prompt.entry)
        }
        // Publication succeeded; a destination read/replacement failure cannot move state back.
        val baseline = LibraryEntry(destination, PromptCodec.parseFile(loaded.bytes, LibraryPath.filename(destination)), loaded.entry.stamp)
        index.acceptRelocated(source, destination, current)
        LibraryMoveResult.Relocated(baseline, current)
    }

    /** Retain history, usage and values so a deleted identity can be restored. */
    fun delete(path: String, expectedStamp: FileStamp? = null) = locked {
        LibraryPath.validate(path)
        if (expectedStamp != null) {
            val stamp = prompts.stamp(path) ?: throw StoreError.NotFound
            if (stamp != expectedStamp) throw LibraryError.Conflict
        }
        prompts.delete(path)
        index.acceptDeleted(path)
    }

    fun restore(revision: HistoryRevision, path: String, expectedStamp: FileStamp? = null): LibrarySaveResult = locked {
        LibraryPath.validate(path)
        when (val identity = revision.identity) {
            is PromptIdentity.Local -> if (PromptIdentity.at(path) != identity) throw LibraryError.IdentityMismatch
            is PromptIdentity.Assigned -> if (entries().any { it.identity == identity && it.relativePath != path }) {
                throw LibraryError.IdentityMismatch
            }
        }
        val current = readCurrent(path)
        if (current != null && current.entry.identity != revision.identity) throw LibraryError.IdentityMismatch
        var document = PromptCodec.parseFile(history.read(revision), LibraryPath.filename(path))
        if (revision.identity is PromptIdentity.Assigned) {
            document = PromptMutations.assigningIdentity(revision.identity.id, document, LibraryPath.filename(path))
        }
        save(document, path, expectedStamp)
    }

    internal fun checkedLoad(path: String): PromptLoadResult {
        for (attempt in 0..1) {
            try { return PromptLoadResult.Loaded(loadForEditing(path)) }
            catch (_: StoreError.NotFound) { return PromptLoadResult.Missing }
            catch (error: LibraryError.Conflict) { if (attempt == 1) return PromptLoadResult.Failed(error) }
            catch (error: Exception) { return PromptLoadResult.Failed(sanitized(error)) }
        }
        return PromptLoadResult.Failed(LibraryError.Conflict)
    }

    private fun saveDocument(draft: PromptDocument, path: String, mode: SaveMode,
                             expectedStamp: FileStamp?): LibrarySaveResult {
        LibraryPath.validate(path)
        PromptCodec.write(draft)
        val current = if (mode == SaveMode.REPLACE) readCurrent(path) else null
        if (expectedStamp != null && current?.entry?.stamp != expectedStamp) throw LibraryError.Conflict
        if (current?.entry?.document?.isReadOnly == true) {
            throw PromptWriteError.UnsupportedFormat(current.entry.document.frontMatter.format)
        }
        val date = clock.now()
        val id = current?.entry?.document?.frontMatter?.id ?: draft.frontMatter.id
            ?: ULID.generate(date, entropy.bytes(Limits.ulidEntropyBytes))
        val document = PromptMutations.assigningIdentity(id, draft, LibraryPath.filename(path))
        val bytes = PromptCodec.write(document).encodeToByteArray(throwOnInvalidSequence = true)
        val sourceIdentity = current?.entry?.identity ?: PromptIdentity.at(path)
        val targetIdentity = PromptIdentity.at(path, document.frontMatter.id)
        val migrated = mutableListOf<PromptKeyedStore>()
        var snapshot: HistoryRevision? = null
        try {
            migrate(sourceIdentity, targetIdentity, migrated)
            if (current != null) snapshot = history.snapshot(current.bytes, targetIdentity, date)
            when (mode) {
                SaveMode.REPLACE -> {
                    if (prompts.stamp(path) != current?.entry?.stamp) throw LibraryError.Conflict
                    prompts.write(bytes, path)
                }
                SaveMode.CREATE -> try { prompts.create(bytes, path) }
                    catch (_: StoreError.AlreadyExists) { throw LibraryError.DestinationOccupied }
            }
        } catch (error: Exception) {
            var recovered = true
            if (snapshot != null) {
                try { history.remove(snapshot) } catch (_: Exception) { recovered = false }
            }
            try { rollback(migrated, targetIdentity, sourceIdentity) } catch (_: Exception) { recovered = false }
            if (!recovered) throw LibraryError.RecoveryRequired
            throw error
        }

        val committed = try { requireCurrent(path) }
        catch (_: Exception) { throw LibraryError.CommitUnverified }
        if (!committed.bytes.contentEquals(bytes)) throw LibraryError.Conflict
        // Retention happens after publication. Its failure is a committed outcome, never a retryable save.
        val maintenanceFailed = try { history.prune(targetIdentity); false } catch (_: Exception) { true }
        return LibrarySaveResult(committed.entry, maintenanceFailed)
    }

    private fun readCurrent(path: String): LoadedFile? {
        LibraryPath.validate(path)
        val stamp = prompts.stamp(path) ?: return null
        val bytes = try { prompts.read(path) } catch (_: StoreError.NotFound) { throw LibraryError.Conflict }
        if (prompts.stamp(path) != stamp) throw LibraryError.Conflict
        return LoadedFile(bytes, LibraryEntry(path, PromptCodec.parseFile(bytes, LibraryPath.filename(path)), stamp))
    }

    private fun requireCurrent(path: String): LoadedFile = readCurrent(path) ?: throw StoreError.NotFound

    private fun isAvailable(path: String): Boolean = try { prompts.stamp(path) == null }
        catch (_: StoreError.NotRegularFile) { false }

    private fun migrate(source: PromptIdentity, destination: PromptIdentity, completed: MutableList<PromptKeyedStore>) {
        if (source == destination) return
        for (store in keyedStores) {
            if (store.migrateKey(source, destination) == KeyMigration.MIGRATED) completed.add(store)
        }
    }

    private fun rollback(completed: List<PromptKeyedStore>, source: PromptIdentity, destination: PromptIdentity) {
        var recovered = true
        for (store in completed.asReversed()) {
            try { store.migrateKey(source, destination) } catch (_: Exception) { recovered = false }
        }
        if (!recovered) throw LibraryError.RecoveryRequired
    }

    private fun <T> locked(work: () -> T): T = mutations.run {
        syncGate.requireEditable()
        work()
    }

    /** Only checked synchronous file work enters here; journal/state/keyed IO stays outside. */
    internal fun <T> withSyncLock(work: (PromptStore) -> T): T = mutations.run { work(prompts) }
    internal fun beginSyncApply(id: UUID, nextState: SyncState) =
        mutations.run { syncGate.begin(id, nextState) }
    internal fun endSyncApply(id: UUID) = mutations.run { syncGate.finish(id) }
    internal fun replaceSyncApply(previous: UUID, next: UUID, nextState: SyncState) =
        mutations.run { syncGate.replace(previous, next, nextState) }
    internal fun resumeSyncApply(id: UUID, nextState: SyncState) =
        mutations.run { syncGate.resume(id, nextState) }
    internal fun blockSyncApplyForRecovery() = mutations.run { syncGate.blockForRecovery() }
    internal fun finishEmptySyncRecovery() = mutations.run { syncGate.finishEmptyRecovery() }
    internal val pendingSyncApplyPermit: SyncRecoveryGate.Permit? get() = mutations.run { syncGate.pendingPermit }
    internal val hasUnreadableSyncJournal: Boolean get() = mutations.run { syncGate.hasUnreadableJournal }
    internal fun syncKeyedStores(): List<SyncKeyedStore> = listOf(history.sync, usage.sync, values.sync)
}
