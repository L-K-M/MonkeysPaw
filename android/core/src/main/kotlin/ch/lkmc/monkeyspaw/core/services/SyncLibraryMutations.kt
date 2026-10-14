package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathCaseFold
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathValidator
import ch.lkmc.monkeyspaw.core.domain.paths.UnicodeText
import ch.lkmc.monkeyspaw.core.domain.ranking.Utf8Order
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.SyncDirectoryEdit
import ch.lkmc.monkeyspaw.core.sync.SyncDirectoryStep
import ch.lkmc.monkeyspaw.core.sync.syncPathKey
import java.util.UUID
import java.util.concurrent.locks.ReentrantLock

/** Exact immutable baseline. Stamps stay opaque; the journal codec checks their encoding. */
internal class SyncLibraryFile(
    val path: String,
    val stamp: FileStamp,
    bytes: ByteArray,
    val hash: SyncHash = SyncHash.of(bytes),
    val identityKey: String = PromptIdentity.at(path, PromptCodec.parseFile(bytes, LibraryPath.filename(path)).frontMatter.id).storageKey,
) {
    private val saved = SyncBytes(bytes)
    val bytes: ByteArray get() = saved.copyBytes()
    val identity: PromptIdentity get() = SyncIdentifiers.promptIdentity(identityKey)

    fun validate() {
        StorePath.validate(path)
        val document = PromptCodec.parseFile(bytes, LibraryPath.filename(path))
        if (hash != SyncHash.of(bytes) || identityKey != PromptIdentity.at(path, document.frontMatter.id).storageKey) {
            throw SyncError.InvalidState
        }
    }

    override fun toString(): String = "<sync library file>"
}

/** Explicit adoption may replace an assigned ID. Ordinary editor rules remain unchanged. */
internal data class SyncIdentityTransition(val source: String?, val destination: String) {
    constructor(source: PromptIdentity?, destination: PromptIdentity) : this(source?.storageKey, destination.storageKey)
    fun validate() {
        source?.let(SyncIdentifiers::promptIdentity)
        SyncIdentifiers.promptIdentity(destination)
    }
    override fun toString(): String = "<sync identity transition>"
}

internal class SyncLibraryEdit(
    val id: UUID,
    val kind: Kind,
    val path: String,
    val expected: SyncLibraryFile?,
    bytes: ByteArray?,
    val hash: SyncHash?,
    val transition: SyncIdentityTransition?,
    val mode: SyncFileMode,
    retainedBytes: ByteArray?,
    val retainedSourcePath: String?,
    val copyID: String? = null,
    val heldIssue: SyncIssueCode? = null,
    val copyOrigin: SyncPromptOrigin? = null,
    val adoptingSource: SyncLibraryFile? = null,
) {
    enum class Kind(val rawValue: String) {
        APPLY("apply"), ADOPT("adopt"), RELOCATE("relocate"), REPAIR_DUPLICATE("repairDuplicate"),
        RESCUE("rescue"), TRASH("trash"), MODE("mode")
    }
    private val saved = bytes?.let(::SyncBytes)
    private val savedRetained = retainedBytes?.let(::SyncBytes)
    val bytes: ByteArray? get() = saved?.copyBytes()
    val retainedBytes: ByteArray? get() = savedRetained?.copyBytes()

    fun validate() {
        StorePath.validate(path)
        expected?.validate()
        adoptingSource?.validate()
        retainedSourcePath?.let(StorePath::validate)
        if (expected != null && expected.path != path) throw SyncError.InvalidState
        if (adoptingSource != null) {
            val alias = kind == Kind.ADOPT && expected?.stamp == adoptingSource.stamp &&
                equalBytes(expected.bytes, adoptingSource.bytes)
            if (kind !in listOf(Kind.ADOPT, Kind.RELOCATE) || expected != null && !alias || adoptingSource.path == path ||
                kind == Kind.ADOPT && pathKey(adoptingSource.path) != pathKey(path) ||
                !equalBytes(retainedBytes, adoptingSource.bytes) || retainedSourcePath != adoptingSource.path) throw SyncError.InvalidState
        }
        if (kind == Kind.RELOCATE && (adoptingSource == null || !equalBytes(bytes, adoptingSource.bytes))) throw SyncError.InvalidState
        if (kind == Kind.MODE) {
            if (expected == null || !equalBytes(bytes, expected.bytes) || hash != expected.hash || transition != null ||
                adoptingSource != null || retainedBytes != null || retainedSourcePath != null || copyID != null ||
                heldIssue != null || copyOrigin != null) throw SyncError.InvalidState
            return
        }
        if (kind == Kind.TRASH) {
            if (expected == null || bytes != null || hash != null || transition != null || adoptingSource != null ||
                !equalBytes(retainedBytes, expected.bytes) || retainedSourcePath != expected.path || copyID != null ||
                heldIssue != null || copyOrigin != null) throw SyncError.InvalidState
            return
        }
        val bytes = bytes ?: throw SyncError.InvalidState
        val transition = transition ?: throw SyncError.InvalidState
        transition.validate()
        if (hash != SyncHash.of(bytes)) throw SyncError.InvalidState
        val assignedExternally = kind == Kind.ADOPT && adoptingSource == null && expected != null &&
            expected.identityKey == transition.destination && transition.source == PromptIdentity.at(path).storageKey
        if (transition.source != (adoptingSource ?: expected)?.identityKey && !assignedExternally) throw SyncError.InvalidState
        val document = PromptCodec.parseFile(bytes, LibraryPath.filename(path))
        val destination = SyncIdentifiers.promptIdentity(transition.destination)
        if (destination != PromptIdentity.at(path, document.frontMatter.id)) throw SyncError.InvalidState
        if (kind == Kind.RESCUE) {
            if (!path.startsWith("Conflicts/") || expected != null || retainedBytes == null || retainedSourcePath == null ||
                syncValidated { SyncPathValidator.validate(path, SyncPathValidator.Scope.USER).path } != path) throw SyncError.InvalidState
            if (heldIssue != null) {
                val nonPrompt = !LibraryPath.isPrompt(retainedSourcePath)
                if (!equalBytes(bytes, retainedBytes) || copyID != null || document.canRender &&
                    !(nonPrompt && heldIssue == SyncIssueCode.LocalVisibility) &&
                    !(heldIssue == SyncIssueCode.Content(PromptIssueCode.INVALID_METADATA_TYPE) &&
                        SyncMutationOrigin.hasInvalidOrigin(document))) throw SyncError.InvalidState
                return
            }
            val original = PromptCodec.parseFile(retainedBytes!!, LibraryPath.filename(retainedSourcePath))
            if (copyID == null || document.frontMatter.id?.rawValue != copyID || original.frontMatter.id?.rawValue == copyID) {
                throw SyncError.InvalidState
            }
        } else {
            LibraryPath.validate(path)
            val source = adoptingSource ?: expected
            if (copyOrigin != null || copyID != null || !equalBytes(retainedBytes, source?.bytes) ||
                retainedSourcePath != source?.path || heldIssue != null &&
                !(heldIssue == SyncIssueCode.Content(PromptIssueCode.INVALID_METADATA_TYPE) &&
                    SyncMutationOrigin.hasInvalidOrigin(document))) throw SyncError.InvalidState
        }
        if (kind == Kind.REPAIR_DUPLICATE && (expected?.identity !is PromptIdentity.Assigned ||
            destination !is PromptIdentity.Assigned || expected.identityKey == transition.destination)) throw SyncError.InvalidState
        if (!document.canRender) throw SyncError.InvalidState
        if (heldIssue == SyncIssueCode.Content(PromptIssueCode.INVALID_METADATA_TYPE) && kind != Kind.RESCUE) return
        val origin = syncValidated { SyncMutationOrigin.origin(document) }
        if (copyOrigin != null && origin != copyOrigin) throw SyncError.InvalidState
    }

    override fun toString(): String = "<sync library edit>"
}

internal enum class SyncLibraryMutationOutcome { APPLIED, REPLAN_AS_CONFLICT }

internal class SyncLibraryMutationResult(
    val outcome: SyncLibraryMutationOutcome,
    displacedBytes: ByteArray? = null,
    val effect: SyncFileMutationEffect = SyncFileMutationEffect.UNCHANGED,
) {
    private val saved = displacedBytes?.let(::SyncBytes)
    val displacedBytes: ByteArray? get() = saved?.copyBytes()
    override fun toString(): String = "<sync library mutation result>"
}

/** Only checked read/hash/file work uses the library lock. The journal owns transaction serialization. */
internal class SyncLibraryMutations(private val library: LibraryService, private val operations: SyncFileOperations) {
    enum class Attempt { FIRST, REPLAY }
    /** Replacement journal objects share serialization on this graph. Never the library IO lock. */
    val journalLock = ReentrantLock()

    fun read(path: String): SyncLibraryFile? = library.withSyncLock { read(it, path) }

    fun listedFiles(): List<SyncLibraryFile> = library.withSyncLock { files ->
        operations.listFiles().sortedWith { a, b ->
            Utf8Order.compare(a.relativePath.encodeToByteArray(), b.relativePath.encodeToByteArray())
        }.map { listed ->
            val file = read(files, listed.relativePath) ?: throw LibraryError.Conflict
            if (file.stamp != listed.stamp) throw LibraryError.Conflict
            file
        }
    }

    fun directoryIdentities(): Map<String, FileStamp> = library.withSyncLock { directoryIdentitiesLocked() }

    private fun directoryIdentitiesLocked(): Map<String, FileStamp> {
        val result = linkedMapOf<String, FileStamp>()
        val parents = mutableListOf<String?>(null)
        try {
            while (parents.isNotEmpty()) {
                val parent = parents.removeAt(parents.lastIndex)
                for (child in operations.directories(parent)) {
                    StorePath.validate(child)
                    if (parent(child) != parent || child in result) throw SyncError.InvalidState
                    result[child] = operations.directoryIdentity(child) ?: throw LibraryError.Conflict
                    parents.add(child)
                }
            }
        } catch (error: SyncFileOperationError) {
            if (error.effect == SyncFileMutationEffect.UNCHANGED &&
                error.code in listOf(SyncFileFailureCode.NOT_FOUND, SyncFileFailureCode.CHANGED)) throw LibraryError.Conflict
            throw error
        }
        return result.toMap()
    }

    fun apply(edit: SyncDirectoryEdit): SyncLibraryMutationOutcome {
        edit.validate()
        return library.withSyncLock { files ->
            val directories = try { directoryIdentitiesLocked() }
            catch (_: LibraryError.Conflict) { return@withSyncLock SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT }
            if (edit.kind == SyncDirectoryEdit.Kind.RESERVE) {
                return@withSyncLock if (vacantDirectory(edit.source, files, directories)) SyncLibraryMutationOutcome.APPLIED
                    else SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT
            }
            if (edit.kind == SyncDirectoryEdit.Kind.REMOVE_EMPTY) {
                val identity = directories[edit.source]
                if (identity == null) {
                    if (files.stamp(edit.source) != null) return@withSyncLock SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT
                    flushSurvivingParents(edit.source)
                    return@withSyncLock SyncLibraryMutationOutcome.APPLIED
                }
                if (identity != edit.identity) return@withSyncLock SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT
                try { operations.removeEmptyDirectory(edit.source, identity) }
                catch (error: SyncFileOperationError) {
                    if (error.effect == SyncFileMutationEffect.UNCHANGED && error.code in
                        setOf(SyncFileFailureCode.CHANGED, SyncFileFailureCode.OCCUPIED)) {
                        return@withSyncLock SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT
                    }
                    throw error
                }
                return@withSyncLock SyncLibraryMutationOutcome.APPLIED
            }
            val destination = edit.destination ?: throw SyncError.InvalidState
            val positions = listOf(edit.source) + listOfNotNull(edit.intermediate) + destination
            val matches = positions.filter { directories[it] == edit.identity }
            if (matches.size != 1) return@withSyncLock SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT
            val current = matches.single()
            if (positions.any { it != current && directories[it] != null }) return@withSyncLock SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT
            val targets = positions.drop(positions.indexOf(current) + 1)
            if (targets.isNotEmpty()) {
                val paths = operations.listFiles().map { it.relativePath } + directories.keys
                for (target in targets) {
                    if (paths.any { it != current && syncPathKey(it) == syncPathKey(target) } || files.stamp(target) != null) {
                        return@withSyncLock SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT
                    }
                }
                // Check every descendant against every wrapper, including the longest final spelling.
                paths.filter { it.startsWith("$current/") }.forEach { child ->
                    targets.forEach { StorePath.validate(it + child.removePrefix(current)) }
                }
                var source = current
                for (target in targets) {
                    try { operations.renameDirectory(source, target) }
                    catch (error: SyncFileOperationError) {
                        if (error.effect == SyncFileMutationEffect.UNCHANGED && error.code in
                            setOf(SyncFileFailureCode.CHANGED, SyncFileFailureCode.OCCUPIED)) {
                            return@withSyncLock SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT
                        }
                        throw error
                    }
                    if (operations.directoryIdentity(target) != edit.identity) return@withSyncLock SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT
                    source = target
                }
            }
            operations.flushDirectory(destination)
            flushSurvivingParents(edit.source)
            SyncLibraryMutationOutcome.APPLIED
        }
    }

    fun verify(edit: SyncDirectoryEdit): SyncLibraryMutationOutcome {
        edit.validate()
        return library.withSyncLock { files ->
            val directories = try { directoryIdentitiesLocked() }
            catch (_: LibraryError.Conflict) { return@withSyncLock SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT }
            val verified = if (edit.kind == SyncDirectoryEdit.Kind.RESERVE) vacantDirectory(edit.source, files, directories)
            else {
                if (edit.kind == SyncDirectoryEdit.Kind.REMOVE_EMPTY) directories[edit.source] == null && files.stamp(edit.source) == null
                else directories[edit.destination] == edit.identity && directories[edit.source] == null &&
                    (edit.intermediate == null || directories[edit.intermediate] == null)
            }
            if (verified) SyncLibraryMutationOutcome.APPLIED else SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT
        }
    }

    private fun vacantDirectory(path: String, files: PromptStore, directories: Map<String, FileStamp>): Boolean {
        val paths = operations.listFiles().map { it.relativePath } + directories.keys
        return paths.none { syncPathKey(it) == syncPathKey(path) } && files.stamp(path) == null
    }

    fun publication(bytes: ByteArray, path: String, expected: SyncLibraryFile?, transition: SyncIdentityTransition,
                    mode: SyncFileMode = SyncFileMode.NORMAL, kind: SyncLibraryEdit.Kind = SyncLibraryEdit.Kind.APPLY,
                    markerIssue: SyncIssueCode? = null, adoptingSource: SyncLibraryFile? = null,
                    id: UUID = UUID.randomUUID()): SyncLibraryEdit {
        val source = adoptingSource ?: expected
        return SyncLibraryEdit(id, kind, path, expected, bytes, SyncHash.of(bytes), transition, mode,
            source?.bytes, source?.path, heldIssue = markerIssue, adoptingSource = adoptingSource).also { it.validate() }
    }

    fun trash(file: SyncLibraryFile, id: UUID = UUID.randomUUID()): SyncLibraryEdit =
        SyncLibraryEdit(id, SyncLibraryEdit.Kind.TRASH, file.path, file, null, null, null, SyncFileMode.NORMAL,
            file.bytes, file.path).also { it.validate() }

    fun mode(mode: SyncFileMode, file: SyncLibraryFile, id: UUID = UUID.randomUUID()): SyncLibraryEdit =
        SyncLibraryEdit(id, SyncLibraryEdit.Kind.MODE, file.path, file, file.bytes, file.hash, null, mode, null, null)
            .also { it.validate() }

    fun rescue(file: SyncLibraryFile, destination: String, freshID: ULID, origin: SyncPromptOrigin = SyncPromptOrigin.Rescued,
               id: UUID = UUID.randomUUID()): SyncLibraryEdit {
        val document = PromptCodec.parseFile(file.bytes, LibraryPath.filename(file.path))
        var issue: SyncIssueCode? = document.issues.firstOrNull { it.severity == PromptIssueSeverity.ERROR }?.let { SyncIssueCode.Content(it.code) }
        if (document.isReadOnly) issue = SyncIssueCode.Content(PromptIssueCode.UNSUPPORTED_FORMAT)
        if (issue == null && SyncMutationOrigin.hasInvalidOrigin(document)) issue = SyncIssueCode.Content(PromptIssueCode.INVALID_METADATA_TYPE)
        if (!LibraryPath.isPrompt(file.path)) issue = SyncIssueCode.LocalVisibility
        var bytes = file.bytes
        var copyID: String? = null
        if (issue == null) {
            if (document.frontMatter.id == freshID) throw SyncError.InvalidState
            bytes = SyncMutationOrigin.copyBytes(document, freshID, origin, LibraryPath.filename(destination))
            copyID = freshID.rawValue
        }
        val target = PromptCodec.parseFile(bytes, LibraryPath.filename(destination))
        return SyncLibraryEdit(id, SyncLibraryEdit.Kind.RESCUE, destination, null, bytes, SyncHash.of(bytes),
            SyncIdentityTransition(null as PromptIdentity?, PromptIdentity.at(destination, target.frontMatter.id)),
            SyncFileMode.NORMAL, file.bytes, file.path, copyID, issue, origin).also { it.validate() }
    }

    fun begin(id: UUID, nextState: SyncState) = library.beginSyncApply(id, nextState)
    fun finish(id: UUID) = library.endSyncApply(id)
    fun stateCommitted(id: UUID) = library.commitSyncApplyState(id)
    fun replacePermit(previous: UUID, next: UUID, nextState: SyncState) = library.replaceSyncApply(previous, next, nextState)
    fun resume(id: UUID, nextState: SyncState) = library.resumeSyncApply(id, nextState)
    fun blockForRecovery() = library.blockSyncApplyForRecovery()
    fun finishEmptyRecovery() = library.finishEmptySyncRecovery()
    val pendingPermit: SyncRecoveryGate.Permit? get() = library.pendingSyncApplyPermit
    val hasUnreadableJournal: Boolean get() = library.hasUnreadableSyncJournal

    fun prepareMigrations(edit: SyncLibraryEdit): List<SyncKeyedMigration> {
        edit.validate()
        if (edit.kind == SyncLibraryEdit.Kind.REPAIR_DUPLICATE) return emptyList()
        val transition = edit.transition ?: return emptyList()
        val source = transition.source ?: return emptyList()
        if (source == transition.destination) return emptyList()
        return library.syncKeyedStores().flatMap {
            it.prepareSyncMigration(SyncIdentifiers.promptIdentity(source), SyncIdentifiers.promptIdentity(transition.destination),
                if (edit.kind == SyncLibraryEdit.Kind.ADOPT) edit.bytes else null, (edit.adoptingSource ?: edit.expected)?.bytes)
        }
    }

    fun prepareMigrations(edit: SyncDirectoryEdit): List<SyncKeyedMigration> {
        edit.validate()
        return edit.identityTransitions().flatMap { transition ->
            val source = SyncIdentifiers.promptIdentity(transition.source ?: throw SyncError.InvalidState)
            val destination = SyncIdentifiers.promptIdentity(transition.destination)
            library.syncKeyedStores().flatMap { it.prepareSyncMigration(source, destination) }
        }
    }

    fun canReplan(step: SyncDirectoryStep): Boolean {
        if (step.completed || step.edit.kind != SyncDirectoryEdit.Kind.RENAME) return true
        val directories = try { directoryIdentities() } catch (_: LibraryError.Conflict) { return false }
        if (directories[step.edit.source] != step.edit.identity) return false
        val stores = library.syncKeyedStores()
        return step.migrations.all { migration -> stores.firstOrNull { it.syncKind == migration.store }
            ?.isSyncMigrationUnstarted(migration) == true }
    }

    fun migrate(migration: SyncKeyedMigration, operations: SyncFileFlushing) {
        val store = library.syncKeyedStores().firstOrNull { it.syncKind == migration.store } ?: throw SyncError.InvalidState
        store.applySyncMigration(migration, operations)
    }

    /** The journal may replace only untouched preparations; it must finish any published migration. */
    fun canReplan(edit: SyncLibraryEdit, migrations: List<SyncKeyedMigration>, completed: Boolean): Boolean {
        if (completed || migrations.isEmpty()) return true
        val current = read(edit.path)
        if (current?.identityKey == edit.transition?.destination &&
            (edit.adoptingSource ?: edit.expected)?.identityKey != edit.transition?.destination) return false
        val stores = library.syncKeyedStores()
        return migrations.all { migration -> stores.firstOrNull { it.syncKind == migration.store }
            ?.isSyncMigrationUnstarted(migration) == true }
    }

    fun apply(edit: SyncLibraryEdit, attempt: Attempt): SyncLibraryMutationResult {
        edit.validate()
        return library.withSyncLock { files ->
            val current = try { read(files, edit.path) }
            catch (_: LibraryError.Conflict) { return@withSyncLock SyncLibraryMutationResult(SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT) }
            if (attempt == Attempt.REPLAY && isPublished(edit, current)) {
                if (edit.kind == SyncLibraryEdit.Kind.TRASH) flushSurvivingParents(edit.path)
                else {
                    operations.setMode(edit.mode, edit.path)
                    SyncDurability.flushFileAndParents(edit.path, operations)
                }
                return@withSyncLock SyncLibraryMutationResult(verify(edit, files), effect = SyncFileMutationEffect.APPLIED)
            }
            if (!matches(edit.expected, current)) return@withSyncLock SyncLibraryMutationResult(SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT)
            if (edit.adoptingSource != null) {
                val matches = try { matches(edit.adoptingSource, read(files, edit.adoptingSource.path)) }
                    catch (_: LibraryError.Conflict) { false }
                if (!matches) return@withSyncLock SyncLibraryMutationResult(SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT)
            }
            val expectation = current?.let { SyncFileExpectation.Matching(it.stamp, it.bytes) } ?: SyncFileExpectation.Absent
            var displaced: ByteArray? = null
            try {
                when (edit.kind) {
                    SyncLibraryEdit.Kind.TRASH -> operations.trash(edit.path, expectation)
                    SyncLibraryEdit.Kind.MODE -> operations.setMode(edit.mode, edit.path)
                    else -> displaced = operations.publish(edit.bytes!!, edit.path, expectation, edit.mode).displacedBytes
                }
            } catch (error: SyncFileOperationError) {
                if (error.code == SyncFileFailureCode.CHANGED ||
                    error.effect == SyncFileMutationEffect.UNCHANGED && error.code == SyncFileFailureCode.OCCUPIED) {
                    return@withSyncLock SyncLibraryMutationResult(SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT, error.displacedBytes, error.effect)
                }
                throw error
            }
            SyncLibraryMutationResult(verify(edit, files), displaced, SyncFileMutationEffect.APPLIED)
        }
    }

    fun verify(edit: SyncLibraryEdit): SyncLibraryMutationOutcome {
        edit.validate()
        return library.withSyncLock { verify(edit, it) }
    }

    private fun verify(edit: SyncLibraryEdit, files: PromptStore): SyncLibraryMutationOutcome = try {
        if (isPublished(edit, read(files, edit.path))) SyncLibraryMutationOutcome.APPLIED else SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT
    } catch (_: LibraryError.Conflict) { SyncLibraryMutationOutcome.REPLAN_AS_CONFLICT }

    private fun flushSurvivingParents(path: String) {
        var parent = parent(path)
        while (parent != null) {
            if (operations.directoryIdentity(parent) != null) operations.flushDirectory(parent)
            parent = parent(parent)
        }
        operations.flushDirectory(null)
    }

    private fun matches(expected: SyncLibraryFile?, current: SyncLibraryFile?): Boolean =
        if (expected == null) current == null else current != null && current.stamp == expected.stamp &&
            current.identityKey == expected.identityKey && current.hash == expected.hash && equalBytes(current.bytes, expected.bytes)

    private fun isPublished(edit: SyncLibraryEdit, current: SyncLibraryFile?): Boolean {
        if (edit.kind == SyncLibraryEdit.Kind.TRASH) return current == null
        return current != null && current.identityKey == (if (edit.kind == SyncLibraryEdit.Kind.MODE) edit.expected?.identityKey
            else edit.transition?.destination) && current.hash == edit.hash && equalBytes(current.bytes, edit.bytes)
    }

    private fun read(files: PromptStore, path: String): SyncLibraryFile? {
        StorePath.validate(path)
        val stamp = files.stamp(path) ?: return null
        val bytes = try { files.read(path) } catch (_: StoreError.NotFound) { throw LibraryError.Conflict }
        if (files.stamp(path) != stamp) throw LibraryError.Conflict
        return SyncLibraryFile(path, stamp, bytes).also { it.validate() }
    }
}

private fun parent(path: String): String? = path.substringBeforeLast('/', "").ifEmpty { null }
private fun equalBytes(left: ByteArray?, right: ByteArray?): Boolean = if (left == null) right == null else right != null && left.contentEquals(right)
private fun pathKey(path: String): String = UnicodeText.nfc(SyncPathCaseFold.fold(UnicodeText.nfc(path)))

/** Only marker validation/copy construction needed by checked mutations; naming/policy belongs to Z9. */
internal object SyncMutationOrigin {
    private const val conflictKey = "x-monkeyspaw-conflict-of"
    private const val rescuedKey = "x-monkeyspaw-rescued"
    private class InvalidOrigin : Exception("Invalid sync origin.", null, false, true)

    fun origin(document: PromptDocument): SyncPromptOrigin? {
        if (!document.canRender) throw SyncError.InvalidState
        fun value(key: String) = document.preservedHeader?.entries?.firstOrNull { PortableYaml.string(it.key) == key }?.value
        val original = value(conflictKey)?.let {
            val id = try { SyncIdentifiers.ulid(PortableYaml.string(it) ?: throw InvalidOrigin()) }
                catch (_: Exception) { throw InvalidOrigin() }
            if (id == document.frontMatter.id) throw InvalidOrigin()
            id
        }
        val rescued = value(rescuedKey)?.let { PortableYaml.boolean(it) ?: throw InvalidOrigin() } ?: false
        if (original != null && rescued) throw InvalidOrigin()
        return original?.let(SyncPromptOrigin::ConflictOf) ?: if (rescued) SyncPromptOrigin.Rescued else null
    }

    fun hasInvalidOrigin(document: PromptDocument): Boolean = try { origin(document); false }
        catch (_: InvalidOrigin) { true } catch (_: SyncError.InvalidState) { false }

    fun copyBytes(document: PromptDocument, id: ULID, origin: SyncPromptOrigin, filename: String): ByteArray {
        if (origin is SyncPromptOrigin.ConflictOf && origin.promptID == id) throw SyncError.InvalidState
        val keys = setOf("id", conflictKey, rescuedKey)
        val entries = document.preservedHeader?.entries.orEmpty().filterNot { PortableYaml.string(it.key) in keys }.toMutableList()
        entries.add(YamlNode.Entry(YamlNode.Scalar("id", YamlTag.STR), YamlNode.Scalar(id.rawValue, YamlTag.STR)))
        entries.add(when (origin) {
            is SyncPromptOrigin.ConflictOf -> YamlNode.Entry(YamlNode.Scalar(conflictKey, YamlTag.STR), YamlNode.Scalar(origin.promptID.rawValue, YamlTag.STR))
            SyncPromptOrigin.Rescued -> YamlNode.Entry(YamlNode.Scalar(rescuedKey, YamlTag.STR), YamlNode.Scalar("true", YamlTag.BOOL))
        })
        val changed = PromptDocument(document.source, document.body, document.frontMatter.copy(id = id), document.template,
            document.decodingIssues, YamlNode.Mapping(entries), document.declarationLocations)
        val bytes = PromptCodec.write(changed).encodeToByteArray(throwOnInvalidSequence = true)
        val checked = PromptCodec.parseFile(bytes, filename)
        if (!checked.canRender || checked.frontMatter.id != id || origin(checked) != origin) throw SyncError.InvalidState
        return bytes
    }
}
