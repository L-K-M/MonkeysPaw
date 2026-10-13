package ch.lkmc.monkeyspaw.core.syncapi

import ch.lkmc.monkeyspaw.core.domain.Limits

data class PullRequest(val databaseID: String?, val cursors: Map<String, String>) {
    companion object {
        val codec = objectCodec("PullRequest", { o ->
            o.members(setOf("database_id", "cursors"))
            PullRequest(o.nullableString("database_id", WireValidation::uuid),
                o.stringMap("cursors", WireValidation::scopeKey, WireValidation::nonempty))
        }, { wireObject("database_id" to wireNullable(it.databaseID),
            "cursors" to WireValue.ObjectValue(it.cursors.mapValues { (_, cursor) -> wireString(cursor) })) })
    }
}

sealed interface FeedItem {
    val seq: Long
    data class Upsert(override val seq: Long, val prompt: FeedPrompt) : FeedItem
    data class Delete(override val seq: Long, val id: String) : FeedItem
    data class MoveOut(override val seq: Long, val id: String) : FeedItem

    companion object {
        val codec: WireCodec<FeedItem> = objectCodec("FeedItem", { o ->
            when (o.string("kind")) {
                "upsert" -> {
                    o.members(setOf("seq", "kind", "prompt"))
                    Upsert(o.long("seq", minimum = 1), o.dto("prompt", FeedPrompt.codec))
                }
                "delete" -> {
                    o.members(setOf("seq", "kind", "id"))
                    Delete(o.long("seq", minimum = 1), o.string("id", WireValidation::ulid))
                }
                "move_out" -> {
                    o.members(setOf("seq", "kind", "id"))
                    MoveOut(o.long("seq", minimum = 1), o.string("id", WireValidation::ulid))
                }
                else -> throw WireContractException()
            }
        }, { item ->
            when (item) {
                is Upsert -> wireObject("seq" to wireLong(item.seq), "kind" to wireString("upsert"),
                    "prompt" to FeedPrompt.codec.encodeValue(item.prompt))
                is Delete -> wireObject("seq" to wireLong(item.seq), "kind" to wireString("delete"), "id" to wireString(item.id))
                is MoveOut -> wireObject("seq" to wireLong(item.seq), "kind" to wireString("move_out"), "id" to wireString(item.id))
            }
        })
    }
}

sealed interface ScopeIdentity {
    val key: String
    data class User(val userID: String) : ScopeIdentity { override val key: String get() = "user:$userID" }
    data class Group(val groupID: String, val name: String, val role: Role) : ScopeIdentity {
        override val key: String get() = "group:$groupID"
    }

    companion object {
        val codec: WireCodec<ScopeIdentity> = objectCodec("ScopeIdentity", { read(it) }, { write(it) })

        internal fun read(o: WireObject, required: Set<String> = emptySet()): ScopeIdentity = when (o.string("kind")) {
            "user" -> {
                o.members(required + setOf("key", "kind"))
                val key = o.string("key", WireValidation::scopeKey)
                wireRequire(key.startsWith("user:"))
                User(key.removePrefix("user:"))
            }
            "group" -> {
                o.members(required + setOf("key", "kind", "group_id", "name", "role"))
                val key = o.string("key", WireValidation::scopeKey)
                val id = o.string("group_id", WireValidation::ulid)
                wireRequire(key == "group:$id")
                Group(id, o.string("name", WireValidation::name), o.dto("role", Role.codec))
            }
            else -> throw WireContractException()
        }

        private fun write(identity: ScopeIdentity): WireValue = when (identity) {
            is User -> wireObject("key" to wireString(identity.key), "kind" to wireString("user"))
            is Group -> wireObject("key" to wireString(identity.key), "kind" to wireString("group"),
                "group_id" to wireString(identity.groupID), "name" to wireString(identity.name),
                "role" to Role.codec.encodeValue(identity.role))
        }
    }
}

data class SyncScope(
    val identity: ScopeIdentity,
    val mode: Mode,
    val head: Long,
    val cursor: String,
    val hasMore: Boolean,
    val items: List<FeedItem>,
) {
    companion object {
        val codec = objectCodec("SyncScope", { o ->
            val identity = ScopeIdentity.read(o, setOf("mode", "head", "cursor", "has_more", "items"))
            val mode = o.dto("mode", Mode.codec)
            val head = o.long("head", minimum = 0)
            val items = o.dtos("items", FeedItem.codec)
            wireRequire(items.size <= Limits.syncPageItemCap)
            wireRequire(items.all { it.seq <= head && (mode != Mode.SNAPSHOT || it is FeedItem.Upsert && it.seq == head) })
            SyncScope(identity, mode, head, o.string("cursor", WireValidation::nonempty), o.boolean("has_more"), items)
        }, { dto ->
            val identity = ScopeIdentity.codec.encodeValue(dto.identity) as WireValue.ObjectValue
            WireValue.ObjectValue(identity.fields + mapOf("mode" to Mode.codec.encodeValue(dto.mode), "head" to wireLong(dto.head),
                "cursor" to wireString(dto.cursor), "has_more" to wireBoolean(dto.hasMore), "items" to wireDtos(dto.items, FeedItem.codec)))
        })
    }
}

data class PullResponse(val databaseID: String, val scopes: List<SyncScope>, val removed: List<String>) {
    companion object {
        val codec = objectCodec("PullResponse", { o ->
            o.members(setOf("database_id", "scopes", "removed"))
            val scopes = o.dtos("scopes", SyncScope.codec)
            val removed = o.strings("removed", WireValidation::scopeKey)
            val keys = scopes.map { it.identity.key }.toSet()
            // Count in Long: many individually bounded scopes still share one page budget.
            wireRequire(scopes.sumOf { it.items.size.toLong() } <= Limits.syncPageItemCap)
            wireRequire(keys.size == scopes.size && scopes.count { it.identity is ScopeIdentity.User } == 1)
            wireRequire(removed.toSet().size == removed.size && removed.none { it in keys })
            PullResponse(o.string("database_id", WireValidation::uuid), scopes, removed)
        }, { wireObject("database_id" to wireString(it.databaseID), "scopes" to wireDtos(it.scopes, SyncScope.codec),
            "removed" to WireValue.ArrayValue(it.removed.map(::wireString))) })
    }
}
