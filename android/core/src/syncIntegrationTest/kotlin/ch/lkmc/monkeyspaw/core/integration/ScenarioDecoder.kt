package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.time.Instant

internal class ScenarioFailure(reason: String) : Exception("Sync scenario: $reason", null, false, true)
internal fun scenarioCheck(value: Boolean, reason: String) {
    if (!value) throw ScenarioFailure(reason)
}
internal fun WireValue.obj(): Map<String, WireValue> =
    (this as? WireValue.ObjectValue)?.fields ?: throw ScenarioFailure("expected object")
internal fun WireValue.array(): List<WireValue> =
    (this as? WireValue.ArrayValue)?.values ?: throw ScenarioFailure("expected array")
internal fun WireValue.text(): String =
    (this as? WireValue.Text)?.value ?: throw ScenarioFailure("expected string")
internal fun WireValue.number(): Long = try { longValue() }
    catch (_: IllegalArgumentException) { throw ScenarioFailure("expected integer") }
internal fun WireValue.count(): Long = number().also { scenarioCheck(it >= 0, "expected nonnegative integer") }
internal fun WireValue.bool(): Boolean =
    (this as? WireValue.BooleanValue)?.value ?: throw ScenarioFailure("expected boolean")

/** Removing each member mirrors the Swift decoder's closed, data-only language. */
internal class ScenarioFields(value: WireValue) {
    private val remaining = value.obj().toMutableMap()
    fun take(key: String): WireValue? = remaining.remove(key)
    fun required(key: String): WireValue = take(key) ?: throw ScenarioFailure("missing member")
    fun string(key: String): String = required(key).text()
    fun strings(key: String): List<String> = required(key).array().map { it.text() }
    fun finish() = scenarioCheck(remaining.isEmpty(), "unknown or unconsumed member")
}

internal data class ScenarioDeviceSpec(val name: String, val seed: Long)
internal data class SyncScenario(
    val id: String, val now: Instant, val servers: List<String>, val users: List<String>,
    val devices: List<ScenarioDeviceSpec>, val prompts: Map<String, String>, val steps: List<ScenarioStep>,
)
internal data class ScenarioStep(val action: String, val device: String, val fields: Map<String, WireValue>) {
    fun string(key: String): String = fields.getValue(key).text()
}

internal object ScenarioDecoder {
    private val names = Regex("[a-z0-9_]+")
    private val methods = setOf("GET", "POST", "PUT", "DELETE", "PATCH")
    private val expectationKeys = setOf("files", "absent", "file_count", "status", "blocking_issue", "state",
        "prompt_count", "cursor_count", "held_count", "account_user", "writes", "trash_count", "requests",
        "history_count", "unique_ids", "protected_ids", "state_absent", "groups", "group_count", "pages",
        "database_id", "cursors", "journal_present")

    fun decode(bytes: ByteArray): List<SyncScenario> {
        val value = try { normalize(WireJson.parse(bytes)) }
        catch (_: IllegalArgumentException) { throw ScenarioFailure("invalid JSON value") }
        val envelope = ScenarioFields(value)
        scenarioCheck(envelope.required("schema").count() == 1L && envelope.string("category") == "sync", "unsupported schema or category")
        val cases = envelope.required("cases").array()
        envelope.finish()
        scenarioCheck(cases.isNotEmpty(), "empty case set")
        val result = cases.map { case ->
            val fields = ScenarioFields(case)
            val id = fields.string("id")
            val time = fields.string("now")
            val now = try { Instant.parse(time) } catch (_: Exception) { throw ScenarioFailure("invalid clock") }
            scenarioCheck(Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z").matches(time) && now.toString() == time,
                "clock must use exact UTC seconds")
            val servers = fields.strings("servers")
            val users = fields.strings("users")
            val devices = fields.required("devices").array().map {
                val device = ScenarioFields(it)
                val name = device.string("name")
                val seed = device.required("entropy_seed").count()
                device.finish()
                // Swift's frozen reader uses a strict UInt32.max upper bound.
                scenarioCheck(seed > 0 && seed < 0xffff_ffffL, "entropy seed out of range")
                ScenarioDeviceSpec(name, seed)
            }
            val prompts = fields.required("prompts").obj().mapValues { it.value.text() }
            prompts.values.forEach(::ulid)
            val steps = fields.required("steps").array().map(::decodeStep)
            fields.finish()
            for (symbols in listOf(servers, users, devices.map { it.name }, prompts.keys.toList())) {
                scenarioCheck(symbols.distinct().size == symbols.size && symbols.all(names::matches), "invalid or duplicate symbolic name")
            }
            scenarioCheck(id.isNotEmpty() && servers.isNotEmpty() && users.size >= 2 && devices.size >= 2 &&
                devices.map { it.seed }.distinct().size == devices.size && steps.any { it.action == "expect" },
                "missing scenario participants or checkpoints")
            SyncScenario(id, now, servers, users, devices, prompts, steps)
        }
        scenarioCheck(result.map { it.id }.distinct().size == result.size, "duplicate case ID")
        return result
    }

    fun decodeStep(value: WireValue): ScenarioStep {
        val fields = ScenarioFields(value)
        val action = fields.string("action")
        val device = fields.string("device")
        fun strings(vararg keys: String) = keys.forEach { fields.string(it) }
        fun network() { method(fields.string("method")); fields.string("path") }
        fun counts(value: WireValue, allowed: Set<String>) {
            val map = value.obj()
            scenarioCheck(map.isNotEmpty() && allowed.containsAll(map.keys), "unknown maintenance checkpoint")
            map.values.forEach { it.count() }
        }
        when (action) {
            "login" -> strings("user", "server")
            "write" -> strings("path", "content")
            "remove", "symlink", "watch", "seed_keyed" -> strings("path")
            "move" -> strings("source", "destination")
            "sync", "restart", "sign_out", "reset_metrics", "resume_client" -> Unit
            "network" -> scenarioCheck(fields.string("mode") in setOf("online", "offline"), "unknown network mode")
            "fire_timers" -> fields.required("delay_seconds").count()
            "bind_prompt" -> strings("path", "name")
            "bind_cursor" -> strings("scope", "name")
            "bind_text" -> {
                fields.string("name")
                val unit = fields.string("unit")
                val count = fields.required("count").count()
                scenarioCheck(unit.isNotEmpty() && count > 0 && count <= Limits.maxPromptBytes / unit.encodeToByteArray().size,
                    "text expansion exceeds prompt budget")
            }
            "favorite" -> { fields.string("id"); fields.required("value").bool() }
            "http", "http_series" -> {
                network()
                fields.take("body")
                fields.required("status").count()
                fields.take("expected")?.obj()
                val bindings = fields.take("bind")?.obj().orEmpty()
                bindings.values.forEach { it.text() }
                if (action == "http_series") {
                    val ids = fields.strings("ids")
                    scenarioCheck(ids.isNotEmpty() && ids.size <= 200 && ids.distinct().size == ids.size && bindings.isEmpty(), "invalid HTTP series")
                    ids.forEach(::ulid)
                }
            }
            "before_next_request", "after_next_response" -> {
                network()
                if (action == "before_next_request") fields.take("skip")?.count()
                val then = fields.required("then")
                val array = action == "after_next_response" && then is WireValue.ArrayValue
                val allowed = if (array) setOf("http", "expect", "advance_server", "retention", "server_expect") else setOf("http", "write", "expect")
                val steps = (if (array) then.array() else listOf(then)).map(::decodeStep)
                scenarioCheck(steps.isNotEmpty() && steps.all { it.action in allowed }, "invalid network hook action")
            }
            "drop_next_response", "fail_next_request" -> network()
            "race_http" -> {
                val writers = fields.required("writers").array().map {
                    val writer = ScenarioFields(it)
                    val name = writer.string("device")
                    method(writer.string("method")); writer.string("path"); writer.required("body")
                    writer.finish()
                    name
                }
                scenarioCheck(writers.size == 2 && writers.distinct().size == 2 && device in writers, "CAS race requires two devices")
            }
            "rewrite_next_request", "rewrite_next_response" -> {
                network()
                scenarioCheck(fields.required("patch").obj().isNotEmpty(), "empty network patch")
            }
            "advance_server" -> {
                fields.string("server")
                scenarioCheck(fields.required("seconds").count() > 0, "clock advance must be positive")
            }
            "retention" -> {
                fields.string("server"); fields.take("clock_offset_seconds")?.count()
                counts(fields.required("expected"), setOf("changes", "floors", "tombstones", "revisions"))
            }
            "server_expect" -> {
                strings("server", "scope")
                counts(fields.required("expected"), setOf("head", "floor", "changes", "tombstones", "revisions", "retired_ids", "snapshots"))
            }
            "backup", "restore" -> {
                fields.string("server")
                scenarioCheck(Regex("[a-z_]+").matches(fields.string("name")), "invalid backup name")
                if (action == "restore") fields.string("bind")
            }
            "set_cursor" -> {
                fields.string("scope")
                val cursor = fields.required("value")
                scenarioCheck(cursor == WireValue.Null || cursor.text().isNotEmpty(), "empty cursor")
            }
            "collect" -> validateCollection(fields.required("expected"))
            "kill_client" -> {
                scenarioCheck(fields.string("checkpoint") in setOf("after_files", "before_state", "after_state"), "unknown kill checkpoint")
                scenarioCheck(fields.required("file_count").count() > 0, "kill requires committed files")
            }
            "expect" -> validateExpectations(fields.required("expected"))
            else -> throw ScenarioFailure("unknown action")
        }
        fields.finish()
        return ScenarioStep(action, device, value.obj() - setOf("action", "device"))
    }

    private fun validateExpectations(value: WireValue) {
        val fields = value.obj()
        scenarioCheck(fields.isNotEmpty() && expectationKeys.containsAll(fields.keys), "unknown or empty expectation")
        for ((key, item) in fields) when (key) {
            "unique_ids", "journal_present" -> item.bool()
            "protected_ids", "state_absent", "absent" -> item.array().forEach { it.text() }
            "status", "blocking_issue", "account_user", "database_id" -> item.text()
            "cursors" -> item.obj().values.forEach { it.text() }
            "files", "state", "requests", "groups", "pages" -> {
                val items = item.array()
                scenarioCheck(items.isNotEmpty(), "empty checkpoint list")
                items.forEach { validateCheckpoint(key, it) }
            }
            else -> item.count()
        }
    }

    private fun validateCheckpoint(kind: String, value: WireValue) {
        val fields = ScenarioFields(value)
        fun strings(vararg keys: String) = keys.forEach { fields.string(it) }
        when (kind) {
            "files" -> { strings("path", "content"); fields.take("mode")?.text() }
            "state" -> {
                strings("id", "scope", "path"); fields.required("rev").count()
                for (key in listOf("hash", "error", "origin")) fields.take(key)?.text()
                for (key in listOf("history", "uses")) fields.take(key)?.count()
                fields.take("favorite")?.bool()
                fields.take("values")?.obj()?.values?.forEach { it.text() }
            }
            "requests" -> {
                strings("method", "path"); fields.required("count").count()
                fields.take("status")?.count(); fields.take("body")?.obj(); fields.take("local_exists")?.text()
            }
            "groups" -> strings("id", "name", "folder", "role")
            "pages" -> {
                fields.required("item_count").count(); fields.required("has_more").bool()
                for (key in listOf("min_bytes", "max_bytes")) fields.take(key)?.count()
                for (key in listOf("removed", "absent_ids")) fields.take(key)?.array()?.forEach { it.text() }
                for ((key, required) in listOf("scopes" to listOf("key", "mode"), "contains" to listOf("id", "scope", "kind"))) {
                    fields.take(key)?.array()?.forEach { entry ->
                        val nested = ScenarioFields(entry)
                        required.forEach { nested.string(it) }
                        nested.finish()
                    }
                }
            }
        }
        fields.finish()
    }

    private fun validateCollection(value: WireValue) {
        val fields = ScenarioFields(value)
        fields.string("scope"); fields.string("cursor")
        fields.required("head").count(); fields.required("item_count").count()
        fields.take("absent")?.array()?.forEach { it.text() }
        fields.take("prompts")?.array()?.forEach {
            val prompt = ScenarioFields(it)
            for (key in listOf("id", "path", "content")) prompt.string(key)
            prompt.required("rev").count()
            prompt.finish()
        }
        fields.finish()
    }

    private fun method(value: String) = scenarioCheck(value in methods, "unknown HTTP method")
    private fun ulid(value: String) {
        scenarioCheck(ULID.parse(value)?.rawValue == value, "invalid ULID")
    }
    private fun normalize(value: WireValue): WireValue = when (value) {
        is WireValue.Number -> wireLong(value.longValue())
        is WireValue.ArrayValue -> WireValue.ArrayValue(value.values.map(::normalize))
        is WireValue.ObjectValue -> WireValue.ObjectValue(value.fields.mapValues { normalize(it.value) })
        else -> value
    }
}

/** Structural enumeration only. Z17 owns semantic full-corpus accounting. */
internal object SyncScenarioCorpus {
    private val required = setOf("01-round-trip.json", "02-offline-conflict.json", "03-edit-delete.json", "04-viewer-denied.json",
        "05-scope-transfers.json", "06-removed-offline.json", "06-removed-retention.json", "07-added-member.json",
        "08-snapshot-triggers.json", "09-paired-move.json", "10-group-lifecycle.json", "11-path-clashes.json",
        "12-untrusted-paths.json", "13-copied-library.json", "14-account-change.json", "15-group-favourite.json",
        "16-invalid-content.json", "17-crash-apply.json", "18-rename-edit.json", "19-racing-moves.json",
        "20-move-echo-pages.json", "21-remote-rename.json", "22-restore-lower-head.json", "23-quiet-scope-retention.json")
    fun load(directory: Path): Pair<Set<String>, List<SyncScenario>> {
        scenarioCheck(!Files.isSymbolicLink(directory) && Files.isDirectory(directory, NOFOLLOW_LINKS), "invalid corpus directory")
        val files = Files.list(directory).use { stream -> stream.filter { !it.fileName.toString().startsWith('.') }.sorted().toList() }
        scenarioCheck(files.isNotEmpty(), "empty sync corpus")
        scenarioCheck(files.map { it.fileName.toString() }.toSet().containsAll(required), "missing acceptance fixture")
        val ids = mutableSetOf<String>()
        val cases = files.flatMap { file ->
            val name = file.fileName.toString()
            scenarioCheck(Files.isRegularFile(file, NOFOLLOW_LINKS) && !Files.isSymbolicLink(file) &&
                Regex("[0-9]{2}-.+\\.json").matches(name), "unknown sync corpus file")
            ScenarioDecoder.decode(Files.readAllBytes(file)).onEach {
                scenarioCheck(it.id.startsWith(name.take(2) + "-") && ids.add(it.id), "orphan or duplicate case ID")
            }
        }
        return files.map { it.fileName.toString() }.toSet() to cases
    }
}

internal class ScenarioSymbols {
    private val symbols = mutableMapOf<String, String>()
    fun bind(name: String, value: String) {
        scenarioCheck(symbols[name] == null || symbols[name] == value, "symbol rebound")
        symbols[name] = value
    }
    fun expand(text: String): String {
        val result = Regex("\\$\\{([^}]*)}").replace(text) { match ->
            val value = symbols[match.groupValues[1]] ?: throw ScenarioFailure("unknown symbolic reference")
            scenarioCheck(!value.contains("\${"), "recursive symbolic reference")
            value
        }
        scenarioCheck(!result.contains("\${"), "unterminated symbolic reference")
        return result
    }
    fun expand(value: WireValue): WireValue = when (value) {
        is WireValue.Text -> wireString(expand(value.value))
        is WireValue.ArrayValue -> WireValue.ArrayValue(value.values.map(::expand))
        is WireValue.ObjectValue -> {
            val result = linkedMapOf<String, WireValue>()
            for ((key, item) in value.fields) scenarioCheck(result.put(expand(key), expand(item)) == null, "duplicate expanded member")
            WireValue.ObjectValue(result)
        }
        else -> value
    }
}

internal fun WireValue.at(pointer: String): WireValue = replacing(pointer, null).second
internal fun WireValue.patching(patches: Map<String, WireValue>): WireValue =
    patches.keys.sorted().fold(this) { value, pointer -> value.replacing(pointer, patches.getValue(pointer)).first }
private fun WireValue.replacing(pointer: String, replacement: WireValue?): Pair<WireValue, WireValue> {
    scenarioCheck(pointer.isEmpty() || pointer.startsWith('/'), "invalid JSON pointer")
    val parts = if (pointer.isEmpty()) emptyList() else pointer.drop(1).split('/').map { it.replace("~1", "/").replace("~0", "~") }
    fun visit(value: WireValue, index: Int): Pair<WireValue, WireValue> {
        if (index == parts.size) return (replacement ?: value) to value
        return when (value) {
            is WireValue.ObjectValue -> {
                val key = parts[index]
                val child = value.fields[key] ?: throw ScenarioFailure("missing JSON pointer target")
                val (next, old) = visit(child, index + 1)
                WireValue.ObjectValue(value.fields + (key to next)) to old
            }
            is WireValue.ArrayValue -> {
                val offset = parts[index].toIntOrNull() ?: throw ScenarioFailure("invalid array pointer")
                scenarioCheck(offset in value.values.indices, "invalid array pointer")
                val (next, old) = visit(value.values[offset], index + 1)
                WireValue.ArrayValue(value.values.toMutableList().also { it[offset] = next }) to old
            }
            else -> throw ScenarioFailure("noncontainer JSON pointer")
        }
    }
    return visit(this, 0)
}
