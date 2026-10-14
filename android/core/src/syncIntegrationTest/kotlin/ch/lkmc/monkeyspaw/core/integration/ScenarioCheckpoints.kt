package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.services.LibraryPath
import ch.lkmc.monkeyspaw.core.services.PromptIdentity
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.nio.file.attribute.PosixFilePermissions

/** Each supplied field is checked against disk, persisted stores or pre-mutation HTTP traces. */
internal class ScenarioCheckpoints(private val symbols: ScenarioSymbols) {
    var count = 0
        private set
    suspend fun check(device: ScenarioDevice, fields: Map<String, WireValue>) {
        val state = device.states.loadForAccountTransition()
        for ((key, value) in fields) {
            when (key) {
                "files" -> value.array().forEach {
                    val file = ScenarioFields(it)
                    val path = symbols.expand(file.string("path"))
                    scenarioCheck(device.files.read(path).contentEquals(symbols.expand(file.string("content")).encodeToByteArray()), "exact file bytes")
                    file.take("mode")?.text()?.let { mode ->
                        scenarioCheck(mode in setOf("normal", "readOnly"), "unknown file mode")
                        scenarioCheck(device.files.mode(path) == PosixFilePermissions.fromString(if (mode == "readOnly") "r--r--r--" else "rw-------"), "file mode")
                    }
                    file.finish()
                }
                "absent" -> value.array().forEach { scenarioCheck(device.files.stamp(symbols.expand(it.text())) == null, "file must be absent") }
                "file_count" -> equalCount(device.files.listFiles().size, value, "file count")
                "prompt_count" -> equalCount(state?.prompts?.size ?: 0, value, "prompt count")
                "cursor_count" -> equalCount(state?.cursors?.size ?: 0, value, "cursor count")
                "held_count" -> equalCount(device.account.heldPrompts().size, value, "held count")
                "group_count" -> equalCount(state?.groups?.size ?: 0, value, "group count")
                "history_count" -> equalCount(device.data.listFiles().count { it.relativePath.startsWith("history/") && it.relativePath.endsWith(".md") }, value, "history count")
                "writes" -> equalCount(device.files.writes, value, "file publication count")
                "trash_count" -> equalCount(device.files.trashCount, value, "trash count")
                "status" -> scenarioCheck(status(device.engine.reports.value.status) == value.text(), "sync status (${status(device.engine.reports.value.status)})")
                "blocking_issue" -> scenarioCheck((device.engine.reports.value.blockingIssue?.name?.lowercase()?.split('_')?.let(::camelCase) ?: "none") == value.text(), "blocking issue")
                "account_user" -> scenarioCheck((device.account.snapshot.account?.identity?.userID?.rawValue ?: "none") == symbols.expand(value.text()), "account user")
                "database_id" -> scenarioCheck((state?.databaseID?.toString() ?: "none") == symbols.expand(value.text()), "database identity")
                "cursors" -> for ((scope, cursor) in value.obj()) scenarioCheck(state?.cursors?.get(SyncScopeKey.parse(symbols.expand(scope))) == symbols.expand(cursor.text()), "scope cursor")
                "journal_present" -> scenarioCheck((device.data.stamp("sync/apply.json") != null) == value.bool(), "apply journal presence")
                "unique_ids" -> {
                    val ids = device.files.listFiles().mapNotNull { PromptCodec.parseFile(device.files.read(it.relativePath), LibraryPath.filename(it.relativePath)).frontMatter.id?.rawValue }
                    scenarioCheck((ids.distinct().size == ids.size) == value.bool(), "unique live identities")
                }
                "protected_ids" -> value.array().forEach {
                    val id = checkedID(it.text())
                    scenarioCheck(id.rawValue !in device.files.unprotectedTrashIDs, "winning identity retired before publication")
                }
                "state_absent" -> value.array().forEach {
                    val id = PromptIdentity.Assigned(checkedID(it.text()))
                    scenarioCheck(state?.prompts?.get(id) == null, "retired identity still in state")
                }
                "state" -> value.array().forEach { checkState(it, state, device) }
                "groups" -> value.array().forEach {
                    val group = ScenarioFields(it)
                    val id = SyncIdentifiers.ulid(symbols.expand(group.string("id")))
                    val actual = state?.groups?.get(id) ?: throw ScenarioFailure("missing group state")
                    scenarioCheck(actual.name == symbols.expand(group.string("name")), "group name")
                    scenarioCheck(actual.folder == symbols.expand(group.string("folder")), "group folder")
                    scenarioCheck(actual.role.wireValue == group.string("role"), "group role")
                    group.finish()
                }
                "pages" -> checkPages(value.array(), device.transport.traces.filter { it.pull != null })
                "requests" -> value.array().forEach { checkRequests(it, device.transport.traces) }
                else -> throw ScenarioFailure("unconsumed expectation")
            }
            count++
        }
    }
    private fun checkState(value: WireValue, state: SyncState?, device: ScenarioDevice) {
        val fields = ScenarioFields(value)
        val id = PromptIdentity.Assigned(SyncIdentifiers.ulid(symbols.expand(fields.string("id"))))
        val actual = state?.prompts?.get(id) ?: throw ScenarioFailure("missing prompt state")
        scenarioCheck(actual.scope.rawValue == symbols.expand(fields.string("scope")), "prompt scope")
        scenarioCheck(actual.path == symbols.expand(fields.string("path")), "prompt path")
        scenarioCheck(actual.rev == fields.required("rev").count(), "prompt revision")
        fields.take("hash")?.let { scenarioCheck(actual.canonicalHash?.rawValue == it.text(), "canonical hash") }
        fields.take("favorite")?.let { scenarioCheck((state.favorites[id] == true) == it.bool(), "favourite overlay") }
        fields.take("error")?.let { scenarioCheck((actual.lastError?.code?.rawValue ?: "none") == it.text(), "per-file issue") }
        fields.take("origin")?.let {
            val origin = when (val origin = actual.origin) {
                is SyncPromptOrigin.ConflictOf -> "conflict_of ${origin.promptID.rawValue}"
                SyncPromptOrigin.Rescued -> "rescued"
                null -> "none"
            }
            scenarioCheck(origin == symbols.expand(it.text()), "prompt origin")
        }
        fields.take("history")?.let { equalCount(device.library.history.revisions(id).size, it, "identity history migration") }
        fields.take("uses")?.let { equalCount(device.library.usage.useEvents(id).size, it, "identity usage migration") }
        fields.take("values")?.let { scenarioCheck(device.library.values.rememberedValues(id) == it.obj().mapValues { entry -> entry.value.text() }, "identity values migration") }
        fields.finish()
    }
    private fun checkRequests(value: WireValue, traces: List<ScenarioTransport.Trace>) {
        val fields = ScenarioFields(value)
        val method = fields.string("method")
        val path = symbols.expand(fields.string("path"))
        val count = fields.required("count")
        val status = fields.take("status")?.count()
        val body = fields.take("body")?.let(symbols::expand)?.obj().orEmpty()
        val local = fields.take("local_exists")?.text()?.let(symbols::expand)
        val matching = traces.count { trace ->
            (method == "*" || trace.method == method) && (path == "*" || trace.path == path) &&
                (status == null || trace.status.toLong() == status) && (local == null || local in trace.localPaths) &&
                body.all { (pointer, expected) -> trace.body?.let { runCatching { it.at(pointer) }.getOrNull() } == expected }
        }
        equalCount(matching, count, "request count ($method)")
        fields.finish()
    }
    private fun checkPages(values: List<WireValue>, traces: List<ScenarioTransport.Trace>) {
        scenarioCheck(values.size == traces.size, "pull page count")
        for ((value, trace) in values.zip(traces)) {
            val fields = ScenarioFields(value)
            val pull = trace.pull ?: throw ScenarioFailure("missing real pull")
            equalCount(pull.scopes.sumOf { it.items.size }, fields.required("item_count"), "page item budget")
            scenarioCheck(pull.scopes.any { it.hasMore } == fields.required("has_more").bool(), "page continuation")
            fields.take("min_bytes")?.let { scenarioCheck(trace.responseBytes >= it.count(), "page byte lower bound") }
            fields.take("max_bytes")?.let { scenarioCheck(trace.responseBytes <= it.count(), "page byte upper bound") }
            fields.take("removed")?.let { scenarioCheck(pull.removed.sorted() == it.array().map { id -> symbols.expand(id.text()) }.sorted(), "removed scopes") }
            fields.take("scopes")?.array()?.forEach {
                val scope = ScenarioFields(it)
                val key = symbols.expand(scope.string("key"))
                scenarioCheck(pull.scopes.firstOrNull { actual -> actual.identity.key == key }?.mode?.wireValue == scope.string("mode"), "scope feed mode")
                scope.finish()
            }
            fields.take("contains")?.array()?.forEach {
                val item = ScenarioFields(it)
                val id = symbols.expand(item.string("id"))
                val scope = symbols.expand(item.string("scope"))
                val kind = item.string("kind")
                scenarioCheck(pull.scopes.firstOrNull { actual -> actual.identity.key == scope }?.items?.any { event ->
                    eventID(event) == id && eventKind(event) == kind
                } == true, "required move/feed event")
                item.finish()
            }
            fields.take("absent_ids")?.array()?.forEach {
                val id = checkedID(it.text()).rawValue
                scenarioCheck(pull.scopes.flatMap { scope -> scope.items }.none { event -> eventID(event) == id }, "unauthorized feed identity")
            }
            fields.finish()
        }
    }
    private fun eventID(item: FeedItem): String = when (item) { is FeedItem.Upsert -> item.prompt.id; is FeedItem.Delete -> item.id; is FeedItem.MoveOut -> item.id }
    private fun checkedID(raw: String) = try { SyncIdentifiers.ulid(symbols.expand(raw)) }
        catch (_: SyncError) { throw ScenarioFailure("invalid checkpoint identity") }
    private fun eventKind(item: FeedItem): String = when (item) { is FeedItem.Upsert -> "upsert"; is FeedItem.Delete -> "delete"; is FeedItem.MoveOut -> "move_out" }
    private fun equalCount(actual: Int, expected: WireValue, reason: String) = scenarioCheck(actual.toLong() == expected.count(), "$reason (actual $actual, expected ${expected.count()})")
    private fun camelCase(parts: List<String>) = parts.first() + parts.drop(1).joinToString("") { it.replaceFirstChar(Char::uppercaseChar) }
    private fun status(status: SyncStatus) = camelCase(status.name.lowercase().split('_'))
}
