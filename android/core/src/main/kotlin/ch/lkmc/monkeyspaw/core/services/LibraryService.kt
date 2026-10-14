package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.SyncState
import ch.lkmc.monkeyspaw.core.domain.sync.SyncPromptOrigin
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.library.PromptProvenance
import ch.lkmc.monkeyspaw.core.domain.library.PromptCreation
import ch.lkmc.monkeyspaw.core.domain.ranking.Utf8Order
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.SyncConflictMetadata
import kotlinx.coroutines.Job
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
    private val assistantAccess: AssistantAccess = AssistantAccess.LOCAL,
) {
    internal val mutations = MutationBoundary()
    private val syncGate = SyncRecoveryGate()
    // App callers use library, fill and index intents; keyed stores stay inside Core.
    internal val history = HistoryStore(state, MutationBoundary())
    internal val usage = UsageStore(state, clock, MutationBoundary())
    internal val values = ValuesStore(state, MutationBoundary())
    val index = PromptIndex(this)
    private val keyedStores = listOf<PromptKeyedStore>(history, usage, values)
    private var groupAccess: GroupAccessService? = null
    private val writeAuthority = Any()
    @Volatile var accessSnapshot: GroupAccessSnapshot = GroupAccessSnapshot.local
        private set

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
    fun save(document: PromptDocument, path: String, expectedStamp: FileStamp? = null,
             provenance: PromptProvenance? = null, permit: LibraryWritePermit = currentWritePermit()): LibrarySaveResult = locked {
        saveDocument(document, path, SaveMode.REPLACE, expectedStamp, provenance, permit).also { index.acceptCommitted(it.entry, path) }
    }

    /** Exclusive create never reads or snapshots an occupied prompt destination. */
    fun create(document: PromptDocument, path: String, provenance: PromptProvenance? = null,
               permit: LibraryWritePermit = currentWritePermit()): LibrarySaveResult = locked {
        saveDocument(document, path, SaveMode.CREATE, null, provenance, permit).also { index.acceptCommitted(it.entry, path) }
    }

    /** Checked assistant saves use the existing history/migration/publication path and exact preview. */
    internal fun acceptAssistant(acceptance: AssistantAcceptance, permit: AssistantSavePermit,
                                 writePermit: LibraryWritePermit = currentWritePermit()): LibrarySaveResult = locked {
        permit.check()
        checkAssistantAccess(acceptance)
        val source = acceptance.candidate.context.editor
        val current = checkAssistantSource(source)
        val document = acceptance.candidate.content.document
        PromptCodec.write(document)
        val result = if (acceptance.destination == AssistantSaveDestination.IMPROVE) {
            if (source == null || source.isNew || source.stamp == null) throw LibraryError.InvalidPromptPath
            saveDocument(document, source.relativePath, SaveMode.REPLACE, source.stamp, null, writePermit, acceptance, permit)
        } else {
            val id = document.frontMatter.id ?: throw LibraryError.PreviewMismatch
            if (entries().any { it.document.frontMatter.id == id }) throw LibraryError.IdentityMismatch
            val folder = if (acceptance.destination == AssistantSaveDestination.PRIVATE_COPY) "" else current?.entry?.folder.orEmpty()
            val name = PromptCreation.relativePath(document.frontMatter.title, clock.now())
            val preferred = (if (folder.isEmpty()) "" else "$folder/") + name
            var suffix = 1
            var created: LibrarySaveResult? = null
            for (attempt in 0 until Limits.libraryCreateAttemptCap) {
                val candidate = availablePath(preferred, suffix)
                try {
                    created = saveDocument(document, candidate.first, SaveMode.CREATE, null, null, writePermit, acceptance, permit, source)
                    break
                } catch (_: LibraryError.DestinationOccupied) { suffix = candidate.second + 1 }
            }
            created ?: throw LibraryError.CopyLimitReached
        }
        // Later external replacement/deletion cannot hide the commit or resurrect stale index bytes.
        when (val latest = checkedLoad(result.entry.relativePath)) {
            is PromptLoadResult.Loaded -> index.acceptCommitted(latest.prompt.entry, result.entry.relativePath)
            PromptLoadResult.Missing -> index.acceptDeleted(result.entry.relativePath)
            is PromptLoadResult.Failed -> index.acceptCommitted(result.entry, result.entry.relativePath)
        }
        result
    }

    private fun checkAssistantSource(source: AssistantEditorSnapshot?): LoadedFile? {
        if (source == null) return null
        val current = readCurrent(source.relativePath)
        if (current == null && source.stamp != null) throw AssistantSaveRefusal(
            AssistantAcceptanceOutcome.Conflict(AssistantAcceptanceConflict.Deleted))
        if (current?.entry?.stamp != source.stamp) throw AssistantSaveRefusal(
            AssistantAcceptanceOutcome.Conflict(AssistantAcceptanceConflict.Modified(checkNotNull(current).entry.stamp)))
        if (current == null && !source.isNew) throw AssistantSaveRefusal(
            AssistantAcceptanceOutcome.Conflict(AssistantAcceptanceConflict.Deleted))
        current?.let { LoadedPrompt(it.bytes, it.entry).readOnlyReason }?.let { reason ->
            throw AssistantSaveRefusal(AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.ReadOnly(reason)))
        }
        return current
    }

    private fun checkAssistantAccess(acceptance: AssistantAcceptance) {
        val expected = acceptance.candidate.context.access
        val actual = assistantAccess.current(acceptance.candidate.context.editor?.relativePath)
        if (actual == AssistantAccessState.UNAVAILABLE || expected.mutationAccess != acceptance.candidate.mutationAccess ||
            acceptance.destination == AssistantSaveDestination.IMPROVE && actual.mutationAccess != AssistantMutationAccess.CURRENT_SCOPE ||
            actual.mutationAccess == AssistantMutationAccess.PRIVATE_COPY && acceptance.destination != AssistantSaveDestination.PRIVATE_COPY) {
            throw AssistantSaveRefusal(AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.AccessDenied))
        }
        if (actual != expected) throw AssistantSaveRefusal(
            AssistantAcceptanceOutcome.Failed(AssistantAcceptanceFailure.StaleContext))
    }

    private fun availablePath(path: String, startingSuffix: Int): Pair<String, Int> {
        LibraryPath.validate(path)
        if (startingSuffix == 1 && isAvailable(path)) return path to 1
        val directory = path.substringBeforeLast('/', "").let { if (it.isEmpty()) "" else "$it/" }
        val stem = LibraryPath.filename(path).removeSuffix(".md")
        for (suffix in maxOf(2, startingSuffix) until 2 + Limits.libraryCopyCandidateCap) {
            val candidate = directory + PromptCreation.copyFilename(stem, suffix)
            LibraryPath.validate(candidate)
            if (isAvailable(candidate)) return candidate to suffix
        }
        throw LibraryError.CopyLimitReached
    }

    fun assignIdentity(path: String, expectedStamp: FileStamp? = null, permit: LibraryWritePermit = currentWritePermit()): LibrarySaveResult = locked {
        val loaded = requireCurrent(path)
        requireMutation(path, loaded.entry.identity, permit)
        if (expectedStamp != null && expectedStamp != loaded.entry.stamp) throw LibraryError.Conflict
        if (loaded.entry.document.frontMatter.id != null) return@locked LibrarySaveResult(loaded.entry)
        save(loaded.entry.document, path, loaded.entry.stamp, permit = permit)
    }

    fun toggleFavorite(entry: LibraryEntry): LibrarySaveResult {
        val service = locked {
            if (accessSnapshot.access(entry.relativePath, entry.identity) == PromptAccessState.Local) null
            else groupAccess ?: throw LibraryError.AccessDenied
        }
        if (service != null) return service.toggleFavorite(entry)
        return locked {
            if (entry.accessGeneration != accessSnapshot.generation) throw LibraryError.AccessChanged
            val document = PromptMutations.favorite(!entry.favorite, entry.document, LibraryPath.filename(entry.relativePath))
            save(document, entry.relativePath, entry.stamp)
        }
    }

    fun move(source: String, destination: String, expectedStamp: FileStamp? = null,
             permit: LibraryWritePermit = currentWritePermit()): LibraryMoveResult = locked {
        LibraryPath.validate(destination)
        val loaded = requireCurrent(source)
        requireMutation(source, loaded.entry.identity, permit)
        requireMutation(destination, loaded.entry.identity, permit)
        if (expectedStamp != null && loaded.entry.stamp != expectedStamp) throw LibraryError.Conflict
        if (source == destination) return@locked LibraryMoveResult.Moved(loaded.entry)
        if (!isAvailable(destination)) throw LibraryError.DestinationOccupied
        val targetIdentity = PromptIdentity.at(destination, loaded.entry.document.frontMatter.id)
        val migrated = mutableListOf<PromptKeyedStore>()
        try {
            migrate(loaded.entry.identity, targetIdentity, migrated)
            if (prompts.stamp(source) != loaded.entry.stamp) throw LibraryError.Conflict
            requireMutation(source, loaded.entry.identity, permit)
            requireMutation(destination, loaded.entry.identity, permit)
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
            .projected(accessSnapshot)
        index.acceptRelocated(source, destination, current)
        LibraryMoveResult.Relocated(baseline, current)
    }

    /** Retain history, usage and values so a deleted identity can be restored. */
    fun delete(path: String, expectedStamp: FileStamp? = null, permit: LibraryWritePermit = currentWritePermit()) = locked {
        LibraryPath.validate(path)
        val current = readCurrent(path)
        if (expectedStamp != null) {
            val stamp = prompts.stamp(path) ?: throw StoreError.NotFound
            if (stamp != expectedStamp) throw LibraryError.Conflict
        }
        requireMutation(path, current?.entry?.identity, permit)
        prompts.delete(path)
        index.acceptDeleted(path)
    }

    /** Exact content binding prevents an external replacement inheriting the previous head's origin. */
    fun provenance(path: String, expectedStamp: FileStamp? = null): PromptProvenance? = locked {
        val loaded = requireCurrent(path)
        if (expectedStamp != null && loaded.entry.stamp != expectedStamp) throw LibraryError.Conflict
        history.headProvenance(loaded.entry.identity, loaded.bytes)
    }

    fun provenance(revision: HistoryRevision): PromptProvenance? = locked {
        history.provenance(revision, history.read(revision))
    }

    fun restore(revision: HistoryRevision, path: String, expectedStamp: FileStamp? = null,
                permit: LibraryWritePermit = currentWritePermit()): LibrarySaveResult = locked {
        LibraryPath.validate(path)
        requireMutation(path, revision.identity, permit)
        when (val identity = revision.identity) {
            is PromptIdentity.Local -> if (PromptIdentity.at(path) != identity) throw LibraryError.IdentityMismatch
            is PromptIdentity.Assigned -> if (entries().any { it.identity == identity && it.relativePath != path }) {
                throw LibraryError.IdentityMismatch
            }
        }
        val current = readCurrent(path)
        if (current != null && current.entry.identity != revision.identity) throw LibraryError.IdentityMismatch
        val bytes = history.read(revision)
        var document = PromptCodec.parseFile(bytes, LibraryPath.filename(path))
        if (revision.identity is PromptIdentity.Assigned) {
            document = PromptMutations.assigningIdentity(revision.identity.id, document, LibraryPath.filename(path))
        }
        val provenance = try { history.provenance(revision, bytes) }
        catch (_: LibraryError.InvalidProvenance) {
            // Readable revision bytes still restore; retain the committed result and both warnings.
            return@locked save(document, path, expectedStamp, permit = permit).copy(provenanceMaintenanceFailed = true)
        }
        save(document, path, expectedStamp, provenance, permit)
    }

    /** Validated explicit copies are private and receive a new identity, including viewer drafts. */
    fun createPrivateCopy(document: PromptDocument, source: LibraryEntry, destination: String,
                          permit: LibraryWritePermit = currentWritePermit()): LibrarySaveResult = locked {
        LibraryPath.validate(destination)
        if (SyncPathValidator.validate(destination, SyncPathValidator.Scope.USER).path != destination ||
            accessSnapshot.accessForPath(destination) != PromptAccessState.Local) throw LibraryError.AccessDenied
        checkWritePermit(permit)
        PromptCodec.write(document)
        val id = ULID.generate(clock.now(), entropy.bytes(Limits.ulidEntropyBytes))
        if (id == source.document.frontMatter.id || id == document.frontMatter.id ||
            entries().any { it.document.frontMatter.id == id }) throw LibraryError.IdentityMismatch
        val filename = LibraryPath.filename(destination)
        val copy = PromptMutations.replacingIdentity(id, document, filename)
        val origin = SyncConflictMetadata.origin(document) ?: (source.identity as? PromptIdentity.Assigned)?.let {
            SyncPromptOrigin.ConflictOf(it.id)
        } ?: SyncPromptOrigin.Rescued
        val marked = SyncConflictMetadata.settingOrigin(origin, PromptCodec.write(copy).encodeToByteArray(), filename)
        create(PromptCodec.parseFile(marked, filename), destination, permit = permit)
    }

    /** M11 can carry this generation/cancellation seam without depending on sync or UI classes. */
    fun captureWritePermit(job: Job? = null): LibraryWritePermit = locked {
        currentWritePermit(job)
    }

    /** Capture before a synchronous command waits for the mutation lock. */
    internal fun currentWritePermit(job: Job? = null) = LibraryWritePermit(writeAuthority, accessSnapshot.generation, job)

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
                             expectedStamp: FileStamp?, provenance: PromptProvenance?, writePermit: LibraryWritePermit,
                             acceptance: AssistantAcceptance? = null, permit: AssistantSavePermit? = null,
                             creationSource: AssistantEditorSnapshot? = null): LibrarySaveResult {
        permit?.check()
        LibraryPath.validate(path)
        requireMutation(path, draft.frontMatter.id?.let(PromptIdentity::Assigned), writePermit)
        PromptCodec.write(draft)
        val current = if (mode == SaveMode.REPLACE) readCurrent(path) else null
        requireMutation(path, current?.entry?.identity, writePermit)
        if (expectedStamp != null && current?.entry?.stamp != expectedStamp) throw LibraryError.Conflict
        if (current?.entry?.document?.isReadOnly == true) {
            throw PromptWriteError.UnsupportedFormat(current.entry.document.frontMatter.format)
        }
        val date = clock.now()
        val id = current?.entry?.document?.frontMatter?.id ?: draft.frontMatter.id
            ?: ULID.generate(date, entropy.bytes(Limits.ulidEntropyBytes))
        val document = PromptMutations.assigningIdentity(id, draft, LibraryPath.filename(path))
        val bytes = PromptCodec.write(document).encodeToByteArray(throwOnInvalidSequence = true)
        if (acceptance != null && !bytes.contentEquals(acceptance.candidate.content.canonicalBytes)) throw LibraryError.PreviewMismatch
        val attribution = if (acceptance == null) provenance else {
            val profile = acceptance.candidate.context.profile ?: throw LibraryError.PreviewMismatch
            val authority = profile.baseURL.substringAfter("://").substringBefore('/')
            val host = if (authority.startsWith('[')) authority.substringBefore(']') + "]" else authority.substringBefore(':')
            PromptProvenance(date, host, profile.modelID, acceptance.usage)
        }
        val sourceIdentity = current?.entry?.identity ?: PromptIdentity.at(path)
        val targetIdentity = PromptIdentity.at(path, document.frontMatter.id)
        val migrated = mutableListOf<PromptKeyedStore>()
        var snapshot: HistoryRevision? = null
        var provenanceFailed = false
        try {
            migrate(sourceIdentity, targetIdentity, migrated)
            if (current != null) {
                val previous = try { history.headProvenance(targetIdentity, current.bytes) }
                catch (_: Exception) { provenanceFailed = true; null }
                snapshot = history.snapshot(current.bytes, targetIdentity, date)
                try { history.archiveProvenance(previous, snapshot, current.bytes) }
                catch (_: Exception) { provenanceFailed = true }
            }
            requireMutation(path, current?.entry?.identity ?: targetIdentity, writePermit)
            when (mode) {
                SaveMode.REPLACE -> {
                    if (prompts.stamp(path) != current?.entry?.stamp) throw LibraryError.Conflict
                    if (acceptance != null) checkAssistantAccess(acceptance)
                    permit?.check()
                    requireMutation(path, current?.entry?.identity ?: targetIdentity, writePermit)
                    prompts.write(bytes, path)
                }
                SaveMode.CREATE -> {
                    if (acceptance != null) {
                        checkAssistantSource(creationSource)
                        checkAssistantAccess(acceptance)
                    }
                    permit?.check()
                    requireMutation(path, current?.entry?.identity ?: targetIdentity, writePermit)
                    try { prompts.create(bytes, path) }
                    catch (_: StoreError.AlreadyExists) { throw LibraryError.DestinationOccupied }
                }
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
        // Attribution and retention happen after publication; failures never request another file write.
        try { history.setHeadProvenance(attribution, targetIdentity, bytes) }
        catch (_: Exception) { provenanceFailed = true }
        val maintenanceFailed = try { history.prune(targetIdentity); false } catch (_: Exception) { true }
        return LibrarySaveResult(committed.entry, maintenanceFailed, provenanceFailed)
    }

    private fun readCurrent(path: String): LoadedFile? {
        LibraryPath.validate(path)
        val stamp = prompts.stamp(path) ?: return null
        val bytes = try { prompts.read(path) } catch (_: StoreError.NotFound) { throw LibraryError.Conflict }
        if (prompts.stamp(path) != stamp) throw LibraryError.Conflict
        return LoadedFile(bytes, LibraryEntry(path, PromptCodec.parseFile(bytes, LibraryPath.filename(path)), stamp).projected(accessSnapshot))
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
        groupAccess?.refreshLocked()
        if (accessSnapshot.isBlocked) throw LibraryError.RecoveryRequired
        work()
    }

    internal fun attachGroupAccess(service: GroupAccessService) = mutations.run {
        check(groupAccess == null) { "Group access is already attached." }
        groupAccess = service
    }

    internal fun installGroupAccess(snapshot: GroupAccessSnapshot) {
        accessSnapshot = snapshot
        index.acceptAccess(snapshot)
    }

    internal fun checkedFavoriteEntry(entry: LibraryEntry, generation: Long): LibraryEntry = locked {
        if (accessSnapshot.generation != generation) throw LibraryError.AccessChanged
        val current = requireCurrent(entry.relativePath).entry
        if (current.identity != entry.identity || current.stamp != entry.stamp) throw LibraryError.Conflict
        current
    }

    private fun checkWritePermit(permit: LibraryWritePermit) {
        groupAccess?.refreshLocked()
        if (Thread.currentThread().isInterrupted) throw java.util.concurrent.CancellationException("Library work was cancelled.")
        permit.check(writeAuthority, accessSnapshot.generation)
    }

    private fun requireMutation(path: String, identity: PromptIdentity?, permit: LibraryWritePermit) {
        checkWritePermit(permit)
        if (accessSnapshot.access(path, identity).readOnlyReason != null) throw LibraryError.AccessDenied
    }

    /** Only checked synchronous file work enters here; journal/state/keyed IO stays outside. */
    internal fun <T> withSyncLock(work: (PromptStore) -> T): T = mutations.run { work(prompts) }
    internal fun beginSyncApply(id: UUID, nextState: SyncState) =
        mutations.run { syncGate.begin(id, nextState) }
    internal fun endSyncApply(id: UUID) = mutations.run { syncGate.finish(id) }
    internal fun commitSyncApplyState(id: UUID) = mutations.run { syncGate.stateCommitted(id) }
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
