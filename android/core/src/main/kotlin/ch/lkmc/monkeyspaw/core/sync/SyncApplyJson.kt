package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.util.Base64

/** Version-1 Swift storage shapes, including base64 bytes and opaque stamp objects. */
internal object SyncApplyJson {
    val codec = SyncDocumentCodec(Limits.syncApplyJournalVersion, ::decode, ::encode)

    private fun decode(value: SyncObject): SyncApplyRecord {
        val o = WireObject(value)
        SyncIdentifiers.version(o.long("version"), Limits.syncApplyJournalVersion)
        return SyncApplyRecord(SyncIdentifiers.uuid(o.string("id")),
            value.optional("expectedState")?.objectValue()?.let(SyncStateJson.codec.decode),
            SyncStateJson.codec.decode(value.required("nextState").objectValue()),
            value.required("steps").arrayValue().map { item ->
                val step = item.objectValue()
                SyncApplyStep(edit(step.required("edit").objectValue()),
                    step.required("migrations").arrayValue().map { migration(it.objectValue()) },
                    boolean(step.required("started")), boolean(step.required("completed")))
            }, value.optional("directorySteps")?.arrayValue().orEmpty().map { item ->
                val step = item.objectValue()
                SyncDirectoryStep(directory(step.required("edit").objectValue()),
                    step.optional("migrations")?.arrayValue().orEmpty().map { migration(it.objectValue()) },
                    boolean(step.required("started")), boolean(step.required("completed")))
            }, value.optional("bindingChange")?.objectValue()?.let { change ->
                SyncBindingChange(change.optional("expected")?.objectValue()?.let(SyncAccountJson::binding),
                    SyncAccountJson.binding(change.required("next").objectValue()))
            }).also { it.validate() }
    }

    private fun encode(record: SyncApplyRecord): SyncObject {
        record.validate()
        return syncObject("version" to wireLong(record.version.toLong()), "id" to wireString(record.id.toString()),
            "expectedState" to (record.expectedState?.let(SyncStateJson.codec.encode) ?: WireValue.Null),
            "nextState" to SyncStateJson.codec.encode(record.nextState),
            "steps" to WireValue.ArrayValue(record.steps.map {
                syncObject("edit" to edit(it.edit), "migrations" to WireValue.ArrayValue(it.migrations.map(::migration)),
                    "started" to wireBoolean(it.started), "completed" to wireBoolean(it.completed))
            }), "directorySteps" to WireValue.ArrayValue(record.directorySteps.map {
                syncObject("edit" to directory(it.edit), "migrations" to WireValue.ArrayValue(it.migrations.map(::migration)),
                    "started" to wireBoolean(it.started), "completed" to wireBoolean(it.completed))
            }), "bindingChange" to (record.bindingChange?.let {
                syncObject("expected" to (it.expected?.let(SyncAccountJson::binding) ?: WireValue.Null),
                    "next" to SyncAccountJson.binding(it.next))
            } ?: WireValue.Null))
    }

    private fun file(value: SyncObject): SyncLibraryFile = WireObject(value).let {
        SyncLibraryFile(it.string("path"), stamp(value.required("stamp")), bytes(value.required("bytes")),
            SyncHash(it.string("hash")), it.string("identityKey"))
    }

    private fun file(value: SyncLibraryFile): SyncObject = syncObject("path" to wireString(value.path),
        "stamp" to stamp(value.stamp), "identityKey" to wireString(value.identityKey), "bytes" to bytes(value.bytes),
        "hash" to wireString(value.hash.rawValue))

    private fun edit(value: SyncObject): SyncLibraryEdit = WireObject(value).let { o ->
        SyncLibraryEdit(SyncIdentifiers.uuid(o.string("id")),
            SyncLibraryEdit.Kind.entries.firstOrNull { it.rawValue == o.string("kind") } ?: throw SyncError.InvalidState,
            o.string("path"), value.optional("expected")?.objectValue()?.let(::file), value.optional("bytes")?.let(::bytes),
            value.optional("hash")?.stringValue()?.let(::SyncHash), value.optional("transition")?.objectValue()?.let {
                SyncIdentityTransition(it.optional("source")?.stringValue(), WireObject(it).string("destination"))
            }, SyncFileMode.entries.firstOrNull { it.rawValue == o.string("mode") } ?: throw SyncError.InvalidState,
            value.optional("retainedBytes")?.let(::bytes), value.optional("retainedSourcePath")?.stringValue(),
            value.optional("copyID")?.stringValue(), value.optional("heldIssue")?.stringValue()?.let(SyncIssueCode::parse),
            value.optional("copyOrigin")?.objectValue()?.let(SyncStateJson::origin),
            value.optional("adoptingSource")?.objectValue()?.let(::file))
    }

    private fun edit(value: SyncLibraryEdit): SyncObject = syncObject("id" to wireString(value.id.toString()),
        "kind" to wireString(value.kind.rawValue), "path" to wireString(value.path),
        "expected" to (value.expected?.let(::file) ?: WireValue.Null), "bytes" to (value.bytes?.let(::bytes) ?: WireValue.Null),
        "hash" to wireNullable(value.hash?.rawValue), "transition" to (value.transition?.let {
            syncObject("source" to wireNullable(it.source), "destination" to wireString(it.destination))
        } ?: WireValue.Null), "mode" to wireString(value.mode.rawValue),
        "retainedBytes" to (value.retainedBytes?.let(::bytes) ?: WireValue.Null),
        "retainedSourcePath" to wireNullable(value.retainedSourcePath), "copyID" to wireNullable(value.copyID),
        "heldIssue" to wireNullable(value.heldIssue?.rawValue),
        "copyOrigin" to (value.copyOrigin?.let(SyncStateJson::origin) ?: WireValue.Null),
        "adoptingSource" to (value.adoptingSource?.let(::file) ?: WireValue.Null))

    private fun directory(value: SyncObject): SyncDirectoryEdit = WireObject(value).let { o ->
        SyncDirectoryEdit(SyncDirectoryEdit.Kind.entries.firstOrNull { it.rawValue == o.string("kind") } ?: throw SyncError.InvalidState,
            o.string("source"), value.optional("identity")?.let(::stamp), value.optional("destination")?.stringValue(),
            value.optional("intermediate")?.stringValue(), value.optional("localFiles")?.arrayValue().orEmpty().map { file(it.objectValue()) },
            SyncIdentifiers.uuid(o.string("id")))
    }

    private fun directory(value: SyncDirectoryEdit): SyncObject = syncObject("id" to wireString(value.id.toString()),
        "kind" to wireString(value.kind.rawValue), "source" to wireString(value.source),
        "identity" to (value.identity?.let(::stamp) ?: WireValue.Null), "destination" to wireNullable(value.destination),
        "intermediate" to wireNullable(value.intermediate), "localFiles" to WireValue.ArrayValue(value.localFiles.map(::file)))

    private fun migration(value: SyncObject): SyncKeyedMigration {
        val o = WireObject(value)
        val store = SyncKeyedStoreKind.entries.firstOrNull { it.rawValue == o.string("store") } ?: throw SyncError.InvalidState
        val change = value.required("change").objectValue()
        if (change.fields.size != 1) throw SyncError.InvalidState
        val payload = change.fields.values.single().objectValue()
        val decoded = when (change.fields.keys.single()) {
            "file" -> {
                val move = payload.required("_0").objectValue()
                val m = WireObject(move)
                SyncKeyedMigration.Change.File(SyncKeyedFileMove(m.string("source"), m.string("destination"),
                    bytes(move.required("bytes")), bytes(move.required("destinationBytes")),
                    SyncHash(m.string("hash")), SyncHash(m.string("destinationHash"))))
            }
            "values" -> SyncKeyedMigration.Change.Values(WireObject(payload).string("source"),
                WireObject(payload).string("destination"), payload.map("fields") { key, item -> key to item.stringValue() })
            else -> throw SyncError.InvalidState
        }
        return SyncKeyedMigration(store, decoded)
    }

    private fun migration(value: SyncKeyedMigration): SyncObject = syncObject("store" to wireString(value.store.rawValue),
        "change" to when (val change = value.change) {
            is SyncKeyedMigration.Change.File -> change.move.let { move ->
                syncObject("file" to syncObject("_0" to syncObject("source" to wireString(move.source),
                    "destination" to wireString(move.destination), "bytes" to bytes(move.bytes),
                    "destinationBytes" to bytes(move.destinationBytes), "hash" to wireString(move.hash.rawValue),
                    "destinationHash" to wireString(move.destinationHash.rawValue))))
            }
            is SyncKeyedMigration.Change.Values -> syncObject("values" to syncObject("source" to wireString(change.source),
                "destination" to wireString(change.destination), "fields" to SyncObject(change.fields.mapValues { wireString(it.value) })))
        })

    private fun stamp(value: WireValue): FileStamp = FileStamp.fromJournalToken(WireObject(value).string("token"))
    private fun stamp(value: FileStamp): SyncObject = syncObject("token" to wireString(value.journalToken()))
    private fun bytes(value: WireValue): ByteArray = syncValidated { Base64.getDecoder().decode(value.stringValue()) }
    private fun bytes(value: ByteArray): WireValue = wireString(Base64.getEncoder().encodeToString(value))
    private fun boolean(value: WireValue): Boolean = (value as? WireValue.BooleanValue)?.value ?: throw SyncError.InvalidState
}
