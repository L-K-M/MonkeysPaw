package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.domain.llm.SecretReadSource
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.sync.SyncServerURL
import ch.lkmc.monkeyspaw.core.sync.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.*
import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.resume

/** Fire only already-captured callbacks with exactly this delay, once, without advancing clocks. */
@OptIn(InternalCoroutinesApi::class)
internal class ScenarioTimers : CoroutineDispatcher(), Delay {
    private class Waiter(val milliseconds: Long, val continuation: CancellableContinuation<Unit>)
    private val lock = Any()
    private val waiters = mutableListOf<Waiter>()
    override fun isDispatchNeeded(context: CoroutineContext) = false
    override fun dispatch(context: CoroutineContext, block: Runnable) = block.run()
    override fun scheduleResumeAfterDelay(timeMillis: Long, continuation: CancellableContinuation<Unit>) {
        val waiter = Waiter(timeMillis, continuation)
        synchronized(lock) { waiters.add(waiter) }
        continuation.invokeOnCancellation { synchronized(lock) { waiters.remove(waiter) } }
    }
    fun fire(seconds: Long) {
        val ready = synchronized(lock) {
            waiters.filter { it.milliseconds % 1000 == 0L && it.milliseconds / 1000 == seconds }
                .also { waiters.removeAll(it.toSet()) }
        }
        for (waiter in ready) if (waiter.continuation.isActive) waiter.continuation.resume(Unit)
    }
}

internal class ScenarioDevice(val name: String, val directory: Path, val now: Instant, val entropy: Entropy,
                              val transport: ScenarioTransport, secretStore: SecretStore? = null) {
    private val timers = ScenarioTimers()
    private val scope = CoroutineScope(SupervisorJob() + timers)
    val clock = Clock { now }
    private val monotonic = MonotonicClock(System::nanoTime)
    val files = DiskSyncFiles(directory.resolve("library"), library = true)
    val data = DiskSyncFiles(directory.resolve("data"))
    val secrets = secretStore ?: FixtureSecretStore(DiskSyncFiles(directory.resolve("secrets")))
    val library = LibraryService(files, data, clock, entropy)
    val states = SyncStateStore(data, data.operations)
    val accounts = SyncAccountStore(data, data.operations)
    val engine = SyncEngine(library, files.operations, data, data.operations, states, accounts, scope,
        Dispatchers.IO, clock, entropy, monotonic)
    val account = SyncAccountService(engine, accounts, secrets, transport, files.root.toString(), Dispatchers.IO, monotonic)
    init { transport.library = files }

    suspend fun settle() = withTimeout(180_000) {
        do { engine.drain(); yield() } while (engine.reports.value.phase != SyncPhase.IDLE)
    }
    suspend fun login(deployment: ScenarioDeployment, username: String) {
        val passwordFile = deployment.users[username]?.second ?: throw ScenarioFailure("unknown login participant")
        val password = SecretValue(Files.readAllBytes(passwordFile).decodeToString(throwOnInvalidSequence = true))
        val result = account.login(deployment.server.baseURL, username, password, name)
        scenarioCheck(result.enabled && result.cleanup.isComplete, "login activation/cleanup")
        engine.setExecutionMode(SyncExecutionMode.FOREGROUND)
        settle()
    }
    suspend fun request(method: String, path: String, body: WireValue?): HttpResponse {
        val account = accounts.loadAccount() ?: throw ScenarioFailure("HTTP action requires account")
        val value = secrets.read(account.secretAccount, SecretReadSource.PERSISTED) ?: throw ScenarioFailure("missing device secret")
        val token = value.value.withValue { WireJson.parse(it.encodeToByteArray()).at("/token").text() }
        val server = SyncServerURL(account.identity.serverURL)
        return transport.send(HttpRequest(server.baseURL + path, HttpMethod.valueOf(method),
            headers = mapOf("Authorization" to "Bearer $token", "Accept" to "application/json", "Content-Type" to "application/json"),
            body = body?.let(WireJson::canonical), requestByteCap = Limits.httpRequestCap, responseByteCap = Limits.syncResponseCap,
            deadlineNanos = monotonic.nowNanos() + 30_000_000_000, urlPolicy = HttpUrlPolicy.Sync(server)))
    }
    fun watch(path: String) {
        val stamp = files.stamp(path)
        val hash = stamp?.let { SyncHash.of(files.read(path)) }
        engine.committedMutation(if (files.ownsChange(path, stamp, hash)) SyncChangeOrigin.SYNC else SyncChangeOrigin.USER)
    }
    suspend fun fireTimers(seconds: Long) { timers.fire(seconds); settle() }
    suspend fun stop() { engine.stop(); settle(); scope.cancel(); scope.coroutineContext[Job]?.join() }
    fun reopen() = ScenarioDevice(name, directory, now, entropy, transport)
}

internal class ScenarioEntropy(seed: Long) : Entropy {
    private var sequence = seed shl 32
    @Synchronized override fun bytes(count: Int): ByteArray {
        sequence++
        val bytes = ByteArray(count)
        for (index in maxOf(0, count - 8) until count) bytes[index] = (sequence ushr ((count - 1 - index) * 8)).toByte()
        return bytes
    }
}

/** Full shared-language executor; every registered action must actually finish. */
internal class ScenarioRunner(private val scenario: SyncScenario, val root: Path,
                              private val deployments: Map<String, ScenarioDeployment>) {
    val symbols = ScenarioSymbols()
    private val devices = linkedMapOf<String, ScenarioDevice>()
    private val transports = mutableListOf<ScenarioTransport>()
    val checkpoints = ScenarioCheckpoints(symbols)
    private val consumed = mutableMapOf<ScenarioStep, Int>()
    private val crashPlans = mutableMapOf<String, SyncApplyRecord>()
    private val backups = mutableSetOf<String>()
    var actions = 0
        private set
    var expectations = 0
        private set
    init {
        scenario.prompts.forEach { (name, id) -> symbols.bind("prompt.$name", id) }
        deployments.forEach { (server, deployment) -> deployment.users.forEach { (user, value) -> symbols.bind("user.$server.$user", value.first) } }
        for (spec in scenario.devices) {
            val directory = root.resolve("device-${spec.name}")
            privateDirectory(directory)
            val transport = ScenarioTransport().also { transports.add(it) }
            devices[spec.name] = ScenarioDevice(spec.name, directory, scenario.now, ScenarioEntropy(spec.seed), transport)
        }
    }
    suspend fun run() {
        for ((index, step) in scenario.steps.withIndex()) {
            try {
                execute(step)
                transports.firstNotNullOfOrNull { it.mutationFailure }?.let { throw it }
            } catch (error: Throwable) {
                val failure = transports.firstNotNullOfOrNull { it.mutationFailure } ?: error
                val reason = if (failure is ScenarioFailure) failure.message else "operation failed (${failure.javaClass.simpleName})"
                println("FAIL ${scenario.id} step ${index + 1}: $reason")
                throw ScenarioFailure("${scenario.id} step ${index + 1}: $reason")
            }
        }
        scenarioCheck(checkpoints.count > 0, "scenario did not execute checkpoints")
        scenarioCheck(transports.all { it.pending == 0 }, "unused network mutation")
        scenarioCheck(crashPlans.isEmpty(), "unrecovered killed client")
        scenarioCheck(consumed == scenario.steps.flatMap(::scenarioActions).groupingBy { it }.eachCount(), "unconsumed or repeated action")
        scenarioCheck(transports.sumOf { it.traces.count { trace -> trace.status > 0 } } > 0, "scenario issued no real HTTP")
    }
    fun device(name: String): ScenarioDevice = devices[symbols.expand(name)] ?: throw ScenarioFailure("unknown device")
    suspend fun execute(step: ScenarioStep) {
        val device = device(step.device)
        fun text(key: String) = symbols.expand(step.string(key))
        when (step.action) {
            "login" -> {
                scenarioCheck(step.string("user") in scenario.users && step.string("server") in scenario.servers, "unknown login participant")
                device.login(deployments[step.string("server")] ?: throw ScenarioFailure("missing deployment"), step.string("user"))
            }
            "write" -> device.files.externalWrite(text("content").encodeToByteArray(), text("path"))
            "remove" -> device.files.delete(text("path"))
            "move" -> device.files.move(text("source"), text("destination"))
            "symlink" -> {
                val outside = root.resolve("outside")
                privateDirectory(outside)
                device.files.symlink(text("path"), outside)
            }
            "sync" -> { device.engine.syncNow(); device.settle() }
            "restart" -> {
                device.stop()
                val replacement = device.reopen()
                devices[device.name] = replacement
                val result = replacement.account.startup()
                scenarioCheck(result.cleanup.isComplete, "restart cleanup")
                if (result.enabled) replacement.engine.setExecutionMode(SyncExecutionMode.FOREGROUND)
                replacement.settle()
            }
            "sign_out" -> {
                val cleanup = device.account.signOut()
                scenarioCheck(cleanup.isComplete && cleanup.remote == SyncRemoteRevocation.REVOKED, "sign-out cleanup/revocation")
            }
            "reset_metrics" -> { device.files.resetMetrics(); device.transport.resetMetrics() }
            "network" -> device.transport.network(ScenarioTransport.Network.valueOf(step.string("mode").uppercase()))
            "watch" -> device.watch(text("path"))
            "fire_timers" -> device.fireTimers(step.fields.getValue("delay_seconds").count())
            "bind_prompt" -> {
                val id = device.library.load(text("path")).identity as? PromptIdentity.Assigned ?: throw ScenarioFailure("idless prompt binding")
                symbols.bind("prompt.${step.string("name")}", id.id.rawValue)
            }
            "bind_cursor" -> {
                val cursor = device.states.loadForAccountTransition()?.cursors?.get(SyncScopeKey.parse(text("scope"))) ?: throw ScenarioFailure("missing cursor binding")
                symbols.bind("cursor.${step.string("name")}", cursor)
            }
            "bind_text" -> symbols.bind("text.${step.string("name")}", step.string("unit").repeat(step.fields.getValue("count").count().toInt()))
            "seed_keyed" -> {
                val id = device.library.load(text("path")).identity
                device.library.history.snapshot(device.files.read(text("path")), id, device.now)
                device.library.usage.recordUse(id)
                device.library.values.record(id, mapOf("field" to "remembered locally"))
            }
            "favorite" -> {
                val state = device.states.loadForAccountTransition() ?: throw ScenarioFailure("favourite without state")
                device.states.update(state.binding) { it.applyGroupFavorite(step.fields.getValue("value").bool(), SyncIdentifiers.promptIdentity(text("id"))) }
            }
            "set_cursor" -> {
                val state = device.states.loadForAccountTransition() ?: throw ScenarioFailure("cursor without state")
                val scope = SyncScopeKey.parse(text("scope"))
                val value = step.fields.getValue("value")
                device.states.update(state.binding) { it.copy(cursors = if (value == WireValue.Null) it.cursors - scope else it.cursors + (scope to symbols.expand(value.text()))) }
            }
            "http" -> http(step)
            "http_series" -> {
                for ((index, id) in step.fields.getValue("ids").array().withIndex()) {
                    fun substitute(value: WireValue): WireValue = when (value) {
                        is WireValue.Text -> wireString(value.value.replace("\${item.id}", id.text()).replace("\${item.index}", index.toString()))
                        is WireValue.ArrayValue -> WireValue.ArrayValue(value.values.map(::substitute))
                        is WireValue.ObjectValue -> WireValue.ObjectValue(value.fields.mapValues { substitute(it.value) })
                        else -> value
                    }
                    try { http(ScenarioStep("http", step.device, step.fields.filterKeys { it != "ids" }.mapValues { substitute(it.value) })) }
                    catch (error: ScenarioFailure) { throw ScenarioFailure("HTTP series item $index: ${error.message}") }
                }
            }
            "race_http" -> raceHTTP(step.fields.getValue("writers").array())
            "before_next_request", "after_next_response" -> {
                val then = step.fields.getValue("then")
                val actions = (if (then is WireValue.ArrayValue) then.values else listOf(then)).map(ScenarioDecoder::decodeStep)
                device.transport.hook(if (step.action == "after_next_response") ScenarioTransport.Phase.RESPONSE else ScenarioTransport.Phase.REQUEST,
                    step.string("method"), text("path"), step.fields["skip"]?.count() ?: 0) {
                    for (action in actions) execute(action)
                }
            }
            "rewrite_next_request", "rewrite_next_response" -> device.transport.patch(if (step.action == "rewrite_next_response") ScenarioTransport.Phase.RESPONSE else ScenarioTransport.Phase.REQUEST,
                step.string("method"), text("path"), symbols.expand(step.fields.getValue("patch")).obj())
            "drop_next_response", "fail_next_request" -> device.transport.interrupt(if (step.action == "drop_next_response") ScenarioTransport.Phase.RESPONSE else ScenarioTransport.Phase.REQUEST,
                step.string("method"), text("path"))
            "expect" -> checkpoints.check(device, step.fields.getValue("expected").obj())
            "advance_server", "retention", "server_expect", "backup", "restore" -> {
                val server = step.string("server")
                val deployment = deployments[server] ?: throw ScenarioFailure("unknown deployment")
                if (step.action == "backup") scenarioCheck(backups.add("$server.${step.string("name")}"), "backup name reused")
                if (step.action == "restore") {
                    scenarioCheck("$server.${step.string("name")}" in backups, "unknown backup")
                    for (graph in devices.values) graph.engine.stop()
                    for (graph in devices.values) graph.settle()
                }
                val oldID = if (step.action == "restore") deployment.control(mapOf("action" to wireString("inspect"))).at("/database_id").text() else null
                val result = deployment.control(symbols.expand(WireValue.ObjectValue(step.fields - setOf("bind", "expected")))
                    .obj() + ("action" to wireString(if (step.action == "server_expect") "inspect" else step.action)))
                if (step.action != "server_expect") for (transport in transports) transport.serverRestarted()
                if (step.action == "restore") {
                    scenarioCheck(result.at("/database_id").text() != oldID, "restore must rotate database identity")
                    symbols.bind(step.string("bind"), result.at("/database_id").text())
                }
                step.fields["expected"]?.obj()?.forEach { (key, expected) ->
                    scenarioCheck(result.obj()[key]?.count() == expected.count(), "server $key checkpoint")
                }
            }
            "collect" -> collect(device, step.fields.getValue("expected").obj())
            "kill_client" -> killClient(device, step.string("checkpoint"), step.fields.getValue("file_count").count().toInt())
            "resume_client" -> resumeClient(device)
            else -> throw ScenarioFailure("unknown action")
        }
        consumed[step] = (consumed[step] ?: 0) + 1
        actions++
        expectations += scenarioExpectations(step)
    }
    private suspend fun collect(device: ScenarioDevice, fields: Map<String, WireValue>) {
        val account = device.accounts.loadAccount() ?: throw ScenarioFailure("collection requires account")
        val state = device.states.loadForAccountTransition() ?: throw ScenarioFailure("collection requires state")
        val secret = device.secrets.read(account.secretAccount, SecretReadSource.PERSISTED) ?: throw ScenarioFailure("collection requires secret")
        val server = SyncServerURL(account.identity.serverURL)
        val token = secret.value.withValue { WireJson.parse(it.encodeToByteArray()).at("/token").text() }
        val collection = SyncPullCollector(SyncHTTPClient(server, device.transport, SyncCredential(server, SecretValue(token))),
            device.data, account.identity.userID).collect(PullRequest(state.databaseID?.toString(), state.cursors.mapKeys { it.key.rawValue }),
                System.nanoTime() + 60_000_000_000)
        collection.use {
            val expected = ScenarioFields(symbols.expand(WireValue.ObjectValue(fields)))
            val key = SyncScopeKey.parse(expected.string("scope"))
            val scope = collection.scopes[key] ?: throw ScenarioFailure("missing collected scope")
            scenarioCheck(scope.head == expected.required("head").count() && scope.cursor == expected.string("cursor"), "collected head/cursor")
            val items = mutableMapOf<String, FeedPrompt>()
            collection.forEachPage(Mode.SNAPSHOT) { page ->
                if (page.scope == key) for (value in page.items) {
                    val prompt = (value.item as? FeedItem.Upsert)?.prompt ?: throw ScenarioFailure("non-upsert snapshot item")
                    scenarioCheck(items.put(prompt.id, prompt) == null, "duplicate collected identity")
                }
            }
            scenarioCheck(items.size.toLong() == expected.required("item_count").count(), "collected item count")
            expected.take("prompts")?.array()?.forEach {
                val prompt = ScenarioFields(it)
                val actual = items[prompt.string("id")] ?: throw ScenarioFailure("missing collected prompt")
                scenarioCheck(actual.rev == prompt.required("rev").count() && actual.path == prompt.string("path") &&
                    actual.content == prompt.string("content"), "exact collected prompt")
                prompt.finish()
            }
            expected.take("absent")?.array()?.forEach { scenarioCheck(it.text() !in items, "discarded snapshot item") }
            expected.finish()
            scenarioCheck(device.states.loadForAccountTransition() == state, "collection never commits state")
        }
        scenarioCheck(device.data.listFiles().none { it.relativePath.startsWith("sync/pull-") }, "collection staging cleanup")
    }
    private suspend fun killClient(device: ScenarioDevice, checkpoint: String, fileCount: Int) {
        scenarioCheck(device.name !in crashPlans, "client already killed")
        device.engine.stop(); device.settle()
        val before = device.states.loadForAccountTransition() ?: throw ScenarioFailure("kill requires state")
        ScenarioDeviceProcess.launch(workerInput(device, checkpoint, fileCount), "paused").use { child ->
            scenarioCheck(child.alive, "checkpoint must belong to live child")
            val record = SyncApplyJson.codec.decode(WireJson.parse(device.data.read("sync/apply.json")) as WireValue.ObjectValue)
            val state = device.states.loadForAccountTransition()
            val publications = record.steps.filter { it.edit.bytes != null && it.edit.kind != SyncLibraryEdit.Kind.MODE }
            val installed = publications.count { step -> device.files.stamp(step.edit.path) != null &&
                device.files.read(step.edit.path).contentEquals(step.edit.bytes!!) }
            scenarioCheck(record.expectedState == before && record.nextState.cursors != before.cursors, "crash journal new cursor intent")
            if (checkpoint == "after_files") scenarioCheck(installed == fileCount && installed < publications.size && state == before,
                "partial files with uncommitted state")
            else {
                scenarioCheck(installed == publications.size && installed >= fileCount, "all files precede state commit")
                val committed = checkpoint in setOf("after_state", "before_state_file_flush", "before_state_directory_flush")
                scenarioCheck(state == if (committed) record.nextState else before, "state commit boundary")
            }
            child.kill()
            crashPlans[device.name] = record
        }
    }
    private suspend fun resumeClient(old: ScenarioDevice) {
        val record = crashPlans[old.name] ?: throw ScenarioFailure("resume requires killed client")
        ScenarioDeviceProcess.launch(workerInput(old, "none", 1), "complete").use { it.requireSuccess() }
        val recovered = old.states.loadForAccountTransition() ?: throw ScenarioFailure("recovery lost state")
        val bytes = old.files.listFiles().associate { it.relativePath to old.files.read(it.relativePath).toList() }
        ScenarioDeviceProcess.launch(workerInput(old, "replay", 1), "complete").use { it.requireSuccess() }
        scenarioCheck(old.states.loadForAccountTransition() == recovered &&
            old.files.listFiles().associate { it.relativePath to old.files.read(it.relativePath).toList() } == bytes, "second replay changed recovered bytes/state")
        old.stop()
        val replacement = old.reopen()
        devices[old.name] = replacement
        scenarioCheck(replacement.data.stamp("sync/apply.json") == null && recovered.databaseID == record.nextState.databaseID &&
            recovered.cursors == record.nextState.cursors, "recovered journal UUID/cursors")
        for (step in record.steps.filter { it.edit.copyID != null }) scenarioCheck(replacement.files.read(step.edit.path).contentEquals(step.edit.bytes!!),
            "stable losing-copy identity and bytes")
        crashPlans.remove(old.name)
    }
    private suspend fun workerInput(device: ScenarioDevice, checkpoint: String, files: Int): ByteArray {
        val account = device.accounts.loadAccount() ?: throw ScenarioFailure("worker requires account")
        val secret = device.secrets.read(account.secretAccount, SecretReadSource.PERSISTED) ?: throw ScenarioFailure("worker requires secret")
        return secret.value.withValue { WireJson.canonical(wireObject("directory" to wireString(device.directory.toString()),
            "name" to wireString(device.name), "secret" to wireString(it), "now" to wireString(device.now.toString()),
            "checkpoint" to wireString(checkpoint), "file_count" to wireLong(files.toLong()))) }
    }
    private suspend fun http(step: ScenarioStep) {
        val response = device(step.device).request(step.string("method"), symbols.expand(step.string("path")), step.fields["body"]?.let(symbols::expand))
        scenarioCheck(response.statusCode.toLong() == step.fields.getValue("status").count(), "HTTP status (actual ${response.statusCode})")
        val expected = step.fields["expected"]?.obj().orEmpty()
        val bindings = step.fields["bind"]?.obj().orEmpty()
        if (expected.isEmpty() && bindings.isEmpty()) return
        val body = WireJson.parse(response.body)
        for ((pointer, value) in expected) scenarioCheck(body.at(symbols.expand(pointer)) == symbols.expand(value), "HTTP JSON checkpoint")
        for ((name, pointer) in bindings) symbols.bind(name, body.at(pointer.text()).text())
    }
    private suspend fun raceHTTP(writers: List<WireValue>) = coroutineScope {
        val fields = writers.map { it.obj() }
        val paths = fields.map { symbols.expand(it.getValue("path").text()) }
        val bodies = fields.map { symbols.expand(it.getValue("body")) }
        scenarioCheck(fields.all { it.getValue("method").text() == "PUT" } && paths.distinct().size == 1, "race must update one prompt")
        scenarioCheck(bodies[0].at("/base_rev") == bodies[1].at("/base_rev"), "race CAS baseline")
        val barrier = CompletableDeferred<Unit>()
        val lock = Any()
        var arrived = 0
        val participants = fields.map { device(it.getValue("device").text()) }
        participants.forEach { participant -> participant.transport.hook(ScenarioTransport.Phase.REQUEST, "PUT", paths[0]) {
            synchronized(lock) { arrived++; if (arrived == 2) barrier.complete(Unit) }
            withTimeout(30_000) { barrier.await() }
        } }
        val replies = participants.mapIndexed { index, participant -> async { participant.request("PUT", paths[index], bodies[index]) } }.awaitAll()
        scenarioCheck(replies.map { it.statusCode }.sorted() == listOf(200, 409), "overlapping CAS requires one winner")
        val winner = if (replies[0].statusCode == 200) 0 else 1
        val loser = 1 - winner
        val accepted = WireJson.parse(replies[winner].body)
        val conflict = WireJson.parse(replies[loser].body)
        scenarioCheck(conflict.at("/code").text() == "conflict" && conflict.at("/head/rev") == accepted.at("/rev"), "race conflict revision")
        for (field in listOf("scope", "path", "content")) scenarioCheck(conflict.at("/head/$field") == bodies[winner].at("/$field"), "race conflict head")
        symbols.bind("race.winner", participants[winner].name)
        symbols.bind("race.loser", participants[loser].name)
        symbols.bind("race.content", bodies[winner].at("/content").text())
        symbols.bind("race.losing_content", bodies[loser].at("/content").text())
    }
    suspend fun stop() {
        try { for (device in devices.values) device.stop() }
        finally { for (transport in transports) transport.close() }
    }
}
