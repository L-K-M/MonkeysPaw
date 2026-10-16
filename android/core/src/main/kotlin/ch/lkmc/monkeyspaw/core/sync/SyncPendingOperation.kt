package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.util.Base64

/** Exact account/root-bound sent facts, independent of subsequent disk edits. */
internal class SyncPendingOperation(
    val binding: SyncLibraryIdentity,
    val intent: SyncConflictIntent,
    val libraryPath: String,
    val file: SyncLibraryFile?,
    val recorded: SyncPromptState?,
) {
    init {
        StorePath.validate(libraryPath)
        file?.validate()
        if (intent.baseRev != (recorded?.rev ?: 0) ||
            intent.operation == SyncOperation.MOVE && intent.sentBytes == null ||
            (if (intent.operation == SyncOperation.DELETE) file != null else file?.path != libraryPath) ||
            file != null && file.identityKey != intent.id.rawValue ||
            intent.fingerprint.contentHash != SyncHash.of(file?.bytes ?: byteArrayOf())) throw SyncError.InvalidState
        if (intent.scope is SyncScopeKey.User && intent.scope.id != binding.account.userID) throw SyncError.BindingMismatch
    }

    override fun toString(): String = "<pending sync push>"
}

/** Checked private publication precedes HTTP; uncertain IO blocks ordinary use. */
internal class SyncPendingOperationStore(private val files: StateStore, private val operations: SyncFileFlushing) {
    private val persistence = SyncPersistence(files, operations, "sync/push.json", SyncPendingOperationJson.codec)

    val snapshot: SyncStoreSnapshot<SyncPendingOperation> get() = persistence.snapshot

    fun load(binding: SyncLibraryIdentity): SyncPendingOperation? = persistence.load().also {
        if (it != null && it.binding != binding) throw SyncError.BindingMismatch
    }

    fun recoverForAccountTransition(): SyncPendingOperation? = persistence.recover()

    fun recover(binding: SyncLibraryIdentity): SyncPendingOperation? = persistence.recover {
        if (it != null && it.binding != binding) throw SyncError.BindingMismatch
    }

    fun save(pending: SyncPendingOperation) = persistence.update { old ->
        if (old != null) throw SyncError.InvalidState
        pending
    }

    fun clear() = persistence.reset(null)

    /** A new hold stops sending but must not erase a possibly committed request. */
    fun retainHeld(request: SyncPendingOperation) {
        val bytes = syncDocumentBytes(SyncPendingOperationJson.codec.encode(request))
        if (bytes.size > Limits.syncRecordMaxBytes) throw SyncError.InvalidState
        val path = "sync/retained/push-${SyncHash.of(bytes).rawValue}.json"
        try {
            if (files.stamp(path) == null) files.writePrivate(bytes, path)
            else if (!files.read(path).contentEquals(bytes)) throw SyncError.InvalidState
            SyncDurability.flushFileAndParents(path, operations)
        } catch (error: SyncError) { throw error }
        catch (error: SyncFileOperationError) { throw error }
        catch (error: Exception) { throw SyncError.WriteFailed(error as? StoreError ?: StoreError.IOFailure) }
    }
}

/** Swift version-1 push.json shape; exact bytes are base64 and stamps remain opaque. */
internal object SyncPendingOperationJson {
    val codec = SyncDocumentCodec(Limits.syncPushJournalVersion, ::decode, ::encode)

    private fun decode(value: SyncObject): SyncPendingOperation {
        val o = WireObject(value)
        SyncIdentifiers.version(o.long("version"), Limits.syncPushJournalVersion)
        val binding = SyncLibraryIdentity(SyncAccountJson.identity(value.required("account").objectValue()),
            SyncLibraryRoot(value.required("root").stringValue()))
        val file = value.optional("file")?.objectValue()?.let { f ->
            val fields = WireObject(f)
            SyncLibraryFile(fields.string("path"), FileStamp.fromJournalToken(WireObject(f.required("stamp")).string("token")),
                bytes(f.required("bytes")), SyncHash(fields.string("hash")), fields.string("identityKey"))
        }
        val fingerprint = fingerprint(value.required("fingerprint").objectValue())
        val intent = SyncConflictIntent(SyncIdentifiers.ulid(o.string("id")), operation(o.string("operation")),
            o.long("baseRev"), SyncScopeKey.parse(o.string("scope")), o.string("path"),
            value.optional("sentBytes")?.let(::bytes), file?.bytes ?: byteArrayOf(), fingerprint.accessGeneration)
        if (intent.fingerprint != fingerprint || intent.sentHash != value.optional("sentHash")?.stringValue()?.let(::SyncHash)) {
            throw SyncError.InvalidState
        }
        return SyncPendingOperation(binding, intent, o.string("libraryPath"), file,
            value.optional("recorded")?.objectValue()?.let(::prompt))
    }

    private fun encode(value: SyncPendingOperation): SyncObject {
        val intent = value.intent
        return syncObject("version" to wireLong(Limits.syncPushJournalVersion.toLong()),
            "account" to SyncAccountJson.identity(value.binding.account), "root" to wireString(value.binding.root.path),
            "id" to wireString(intent.id.rawValue), "operation" to wireString(intent.operation.rawValue),
            "baseRev" to wireLong(intent.baseRev), "scope" to wireString(intent.scope.rawValue), "path" to wireString(intent.path),
            "sentBytes" to (intent.sentBytes?.let(::bytes) ?: WireValue.Null), "sentHash" to wireNullable(intent.sentHash?.rawValue),
            "fingerprint" to fingerprint(intent.fingerprint), "libraryPath" to wireString(value.libraryPath),
            "file" to (value.file?.let { file ->
                syncObject("path" to wireString(file.path), "stamp" to syncObject("token" to wireString(file.stamp.journalToken())),
                    "identityKey" to wireString(file.identityKey), "bytes" to bytes(file.bytes), "hash" to wireString(file.hash.rawValue))
            } ?: WireValue.Null), "recorded" to (value.recorded?.let(::prompt) ?: WireValue.Null))
    }

    private fun prompt(value: SyncObject): SyncPromptState = WireObject(value).let { o ->
        SyncPromptState(SyncScopeKey.parse(o.string("scope_key")), o.string("path"), o.long("rev"),
            value.optional("canonical_hash")?.stringValue()?.let(::SyncHash),
            value.optional("origin")?.objectValue()?.let(SyncStateJson::origin),
            value.optional("last_error")?.objectValue()?.let {
                SyncPromptError(SyncIssueCode.parse(WireObject(it).string("code")), fingerprint(it.required("fingerprint").objectValue()))
            })
    }

    private fun prompt(value: SyncPromptState): SyncObject = syncObject(
        "scope_key" to wireString(value.scope.rawValue), "path" to wireString(value.path), "rev" to wireLong(value.rev),
        "canonical_hash" to wireNullable(value.canonicalHash?.rawValue),
        "origin" to (value.origin?.let(SyncStateJson::origin) ?: WireValue.Null),
        "last_error" to (value.lastError?.let {
            syncObject("code" to wireString(it.code.rawValue), "fingerprint" to fingerprint(it.fingerprint))
        } ?: WireValue.Null))

    private fun fingerprint(value: SyncObject): SyncInputFingerprint = WireObject(value).let {
        SyncInputFingerprint(SyncHash(it.string("content_hash")), SyncHash(it.string("path_hash")),
            SyncScopeKey.parse(it.string("scope_key")), it.long("access_generation"), operation(it.string("operation")))
    }

    private fun fingerprint(value: SyncInputFingerprint): SyncObject = syncObject(
        "content_hash" to wireString(value.contentHash.rawValue), "path_hash" to wireString(value.pathHash.rawValue),
        "scope_key" to wireString(value.scope.rawValue), "access_generation" to wireLong(value.accessGeneration),
        "operation" to wireString(value.operation.rawValue))

    private fun operation(raw: String): SyncOperation = SyncOperation.entries.firstOrNull { it.rawValue == raw } ?: throw SyncError.InvalidState
    private fun bytes(value: WireValue): ByteArray = syncValidated { Base64.getDecoder().decode(value.stringValue()) }
    private fun bytes(value: ByteArray): WireValue = wireString(Base64.getEncoder().encodeToString(value))
}
