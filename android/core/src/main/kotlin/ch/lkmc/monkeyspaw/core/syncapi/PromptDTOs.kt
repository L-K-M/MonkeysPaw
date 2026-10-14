package ch.lkmc.monkeyspaw.core.syncapi

import ch.lkmc.monkeyspaw.core.domain.Limits

// Prompt scope is flattened into each enclosing contract's closed object.
internal fun WireObject.promptScope(required: Set<String>, optional: Set<String> = emptySet()): PromptScope =
    when (string("scope")) {
        "user" -> {
            members(required + "scope", optional)
            PromptScope.User
        }
        "group" -> {
            members(required + setOf("scope", "group_id"), optional)
            PromptScope.Group(string("group_id", WireValidation::ulid))
        }
        else -> throw WireContractException()
    }

internal fun scopedObject(scope: PromptScope, vararg fields: Pair<String, WireValue>): WireValue =
    WireValue.ObjectValue((PromptScope.codec.encodeValue(scope) as WireValue.ObjectValue).fields + fields)

data class Prompt(val id: String, val rev: Long, val scope: PromptScope, val path: String, val content: String) {
    companion object {
        val codec = objectCodec("Prompt", { o ->
            val scope = o.promptScope(setOf("id", "rev", "path", "content"))
            Prompt(o.string("id", WireValidation::ulid), o.long("rev", minimum = 1), scope,
                o.string("path", WireValidation::path), o.string("content", WireValidation::content))
        }, { scopedObject(it.scope, "id" to wireString(it.id), "rev" to wireLong(it.rev),
            "path" to wireString(it.path), "content" to wireString(it.content)) })
    }
}

data class PutPromptRequest(
    val baseRev: Long,
    val scope: PromptScope,
    val path: String,
    val content: String,
    val origin: WriteOrigin? = null,
) {
    companion object {
        val codec = objectCodec("PutPromptRequest", { o ->
            val scope = o.promptScope(setOf("base_rev", "path", "content"), setOf("origin"))
            PutPromptRequest(o.long("base_rev", minimum = 0), scope, o.string("path", WireValidation::path),
                o.string("content", WireValidation::content), o.optionalDto("origin", WriteOrigin.codec))
        }, { dto ->
            val fields = mutableMapOf("base_rev" to wireLong(dto.baseRev), "path" to wireString(dto.path),
                "content" to wireString(dto.content))
            dto.origin?.let { fields["origin"] = WriteOrigin.codec.encodeValue(it) }
            scopedObject(dto.scope, *fields.toList().toTypedArray())
        })
    }
}

data class DeletePromptQuery(val baseRev: Long) {
    companion object {
        val codec = objectCodec("DeletePromptQuery", { o ->
            o.members(setOf("base_rev"))
            DeletePromptQuery(o.long("base_rev", minimum = 1))
        }, { wireObject("base_rev" to wireLong(it.baseRev)) })
    }
}

data class MovePromptRequest(val baseRev: Long, val scope: PromptScope, val path: String) {
    companion object {
        val codec = objectCodec("MovePromptRequest", { o ->
            val scope = o.promptScope(setOf("base_rev", "path"))
            MovePromptRequest(o.long("base_rev", minimum = 1), scope, o.string("path", WireValidation::path))
        }, { scopedObject(it.scope, "base_rev" to wireLong(it.baseRev), "path" to wireString(it.path)) })
    }
}

data class WriteResponse(val rev: Long, val seq: Long, val warnings: List<Issue>? = null) {
    companion object {
        val codec = objectCodec("WriteResponse", { o ->
            o.members(setOf("rev", "seq"), setOf("warnings"))
            val warnings = if (o.contains("warnings")) o.dtos("warnings", Issue.codec) else null
            wireRequire(warnings == null || warnings.all { it.severity == Severity.WARNING })
            WriteResponse(o.long("rev", minimum = 1), o.long("seq", minimum = 1), warnings)
        }, { dto ->
            val fields = mutableMapOf("rev" to wireLong(dto.rev), "seq" to wireLong(dto.seq))
            dto.warnings?.let { fields["warnings"] = wireDtos(it, Issue.codec) }
            WireValue.ObjectValue(fields)
        })
    }
}

data class ConflictHead(val rev: Long, val scope: PromptScope, val path: String, val content: String) {
    companion object {
        val codec = objectCodec("ConflictHead", { o ->
            val scope = o.promptScope(setOf("rev", "path", "content"))
            ConflictHead(o.long("rev", minimum = 1), scope, o.string("path", WireValidation::path),
                o.string("content", WireValidation::content))
        }, { scopedObject(it.scope, "rev" to wireLong(it.rev), "path" to wireString(it.path), "content" to wireString(it.content)) })
    }
}

data class ExistingPrompt(val id: String, val rev: Long, val content: String) {
    companion object {
        val codec = objectCodec("ExistingPrompt", { o ->
            o.members(setOf("id", "rev", "content"))
            ExistingPrompt(o.string("id", WireValidation::ulid), o.long("rev", minimum = 1),
                o.string("content", WireValidation::content))
        }, { wireObject("id" to wireString(it.id), "rev" to wireLong(it.rev), "content" to wireString(it.content)) })
    }
}

data class RevisionSummary(
    val rev: Long,
    val authorID: String,
    val createdAt: String,
    val origin: RevisionOrigin,
    val scope: PromptScope,
    val path: String,
) {
    companion object {
        val codec = objectCodec("RevisionSummary", { o ->
            val scope = o.promptScope(setOf("rev", "author_id", "created_at", "origin", "path"))
            RevisionSummary(o.long("rev", minimum = 1), o.string("author_id", WireValidation::ulid),
                o.string("created_at", WireValidation::timestamp), o.dto("origin", RevisionOrigin.codec), scope,
                o.string("path", WireValidation::path))
        }, { scopedObject(it.scope, "rev" to wireLong(it.rev), "author_id" to wireString(it.authorID),
            "created_at" to wireString(it.createdAt), "origin" to RevisionOrigin.codec.encodeValue(it.origin),
            "path" to wireString(it.path)) })
    }
}

data class RevisionsResponse(val revisions: List<RevisionSummary>) {
    companion object {
        val codec = objectCodec("RevisionsResponse", { o ->
            o.members(setOf("revisions"))
            val revisions = o.dtos("revisions", RevisionSummary.codec)
            wireRequire(revisions.size <= Limits.revisionListCap)
            RevisionsResponse(revisions)
        }, { wireObject("revisions" to wireDtos(it.revisions, RevisionSummary.codec)) })
    }
}

data class Revision(
    val id: String,
    val rev: Long,
    val authorID: String,
    val createdAt: String,
    val origin: RevisionOrigin,
    val scope: PromptScope,
    val path: String,
    val content: String,
) {
    companion object {
        val codec = objectCodec("Revision", { o ->
            val scope = o.promptScope(setOf("id", "rev", "author_id", "created_at", "origin", "path", "content"))
            Revision(o.string("id", WireValidation::ulid), o.long("rev", minimum = 1),
                o.string("author_id", WireValidation::ulid), o.string("created_at", WireValidation::timestamp),
                o.dto("origin", RevisionOrigin.codec), scope, o.string("path", WireValidation::path),
                o.string("content", WireValidation::content))
        }, { scopedObject(it.scope, "id" to wireString(it.id), "rev" to wireLong(it.rev),
            "author_id" to wireString(it.authorID), "created_at" to wireString(it.createdAt),
            "origin" to RevisionOrigin.codec.encodeValue(it.origin), "path" to wireString(it.path),
            "content" to wireString(it.content)) })
    }
}

data class FeedPrompt(val id: String, val rev: Long, val path: String, val content: String) {
    companion object {
        val codec = objectCodec("FeedPrompt", { o ->
            o.members(setOf("id", "rev", "path", "content"))
            FeedPrompt(o.string("id", WireValidation::ulid), o.long("rev", minimum = 1),
                o.string("path", WireValidation::path), o.string("content", WireValidation::content))
        }, { wireObject("id" to wireString(it.id), "rev" to wireLong(it.rev), "path" to wireString(it.path),
            "content" to wireString(it.content)) })
    }
}
