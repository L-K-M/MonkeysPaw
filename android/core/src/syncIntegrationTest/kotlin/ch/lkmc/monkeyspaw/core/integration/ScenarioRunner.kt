package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.SecretValue
import ch.lkmc.monkeyspaw.core.domain.llm.SecretReadSource
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.sync.SyncServerURL
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant

@OptIn(ExperimentalCoroutinesApi::class)
internal class ScenarioDevice(val name: String, val directory: Path, val now: Instant, val entropy: Entropy,
                              val transport: ScenarioTransport) {
    private val timers = TestCoroutineScheduler()
    private val scope = CoroutineScope(SupervisorJob() + UnconfinedTestDispatcher(timers))
    val clock = Clock { now }
    private val monotonic = MonotonicClock(System::nanoTime)
    val files = DiskSyncFiles(directory.resolve("library"), library = true)
    val data = DiskSyncFiles(directory.resolve("data"))
    val secrets = FixtureSecretStore(DiskSyncFiles(directory.resolve("secrets")))
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
    suspend fun fireTimers(seconds: Long) { timers.advanceTimeBy(seconds * 1000); timers.runCurrent(); settle() }
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

/** Y12/Y13 partial executor. Unsupported Y14 controls fail until Z17 supplies their real adapters. */
internal class ScenarioRunner(private val scenario: SyncScenario, val root: Path,
                              private val deployments: Map<String, ScenarioDeployment>) {
    val symbols = ScenarioSymbols()
    private val devices = linkedMapOf<String, ScenarioDevice>()
    private val transports = mutableListOf<ScenarioTransport>()
    val checkpoints = ScenarioCheckpoints(symbols)
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
                throw ScenarioFailure("${scenario.id} step ${index + 1}: $reason")
            }
        }
        scenarioCheck(checkpoints.count > 0, "scenario did not execute checkpoints")
        scenarioCheck(transports.all { it.pending == 0 }, "unused network mutation")
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
            "network" -> device.transport.network(step.string("mode") == "online")
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
                device.transport.hook(step.action == "after_next_response", step.string("method"), text("path"), step.fields["skip"]?.count() ?: 0) {
                    for (action in actions) execute(action)
                }
            }
            "rewrite_next_request", "rewrite_next_response" -> device.transport.patch(step.action == "rewrite_next_response",
                step.string("method"), text("path"), symbols.expand(step.fields.getValue("patch")).obj())
            "drop_next_response", "fail_next_request" -> device.transport.interrupt(step.action == "drop_next_response", step.string("method"), text("path"))
            "expect" -> checkpoints.check(device, step.fields.getValue("expected").obj())
            else -> throw ScenarioFailure("action requires Z17 adapter: ${step.action}")
        }
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
        participants.forEach { participant -> participant.transport.hook(false, "PUT", paths[0]) {
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
