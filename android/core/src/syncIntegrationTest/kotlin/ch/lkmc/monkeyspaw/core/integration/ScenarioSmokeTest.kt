package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.sync.SyncServerURL
import ch.lkmc.monkeyspaw.core.syncapi.*
import ch.lkmc.monkeyspaw.data.OkHttpHttpTransport
import kotlinx.coroutines.*
import org.junit.Assume.assumeTrue
import java.net.URI
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import java.time.Instant
import kotlin.test.Test

/** Only row 01 executes here. Z16 extends the runner; Z17 takes semantic corpus ownership. */
class ScenarioSmokeTest {
    @Test fun productionEngineRoundTripAndEcho() {
        val manifest = System.getenv("MONKEYSPAW_SYNC_MANIFEST")?.takeIf { it.isNotEmpty() }
        if (manifest == null && System.getenv("MONKEYSPAW_REQUIRE_SYNC_SERVER") != "1") {
            println("SKIP live Z15 smoke: no server manifest; run scripts/android-sync-ci.py in CI")
            assumeTrue("Live smoke requires the CI server manifest", false)
        }
        scenarioCheck(manifest != null, "required live server manifest missing")
        runBlocking(Dispatchers.IO) {
            withTimeout(300_000) {
                val runtime = SmokeRuntime.read(Path.of(manifest!!))
                val scenario = ScenarioDecoder.decode(Files.readAllBytes(Path.of(System.getProperty("monkeyspaw.fixtures"), "sync/01-round-trip.json"))).single()
                scenarioCheck(scenario.id == "01-round-trip", "unexpected smoke scenario")
                val smoke = SmokeScenario(scenario, runtime)
                try { smoke.run() }
                finally { withContext(NonCancellable) { withTimeout(10_000) { smoke.stop() } } }
            }
        }
        println("PASS Z15 partial proof: 01-round-trip; other sync scenarios remain delegated")
    }
}

internal class SmokeRuntime(val root: Path, val server: SyncServerURL, val users: Map<String, Pair<String, Path>>) {
    companion object {
        fun read(path: Path): SmokeRuntime {
            privateRegularFile(path)
            val fields = ScenarioFields(WireJson.parse(Files.readAllBytes(path)))
            scenarioCheck(fields.required("schema").count() == 1L, "unsupported manifest")
            val root = Path.of(fields.string("root"))
            scenarioCheck(root.isAbsolute && !Files.isSymbolicLink(root) && Files.isDirectory(root, NOFOLLOW_LINKS) &&
                Files.getPosixFilePermissions(root) == PosixFilePermissions.fromString("rwx------"), "invalid runtime root")
            scenarioCheck(path.toAbsolutePath().parent == root, "manifest outside runtime root")
            val servers = fields.required("servers").obj()
            fields.finish()
            scenarioCheck(servers.keys == setOf("main"), "smoke requires one deployment")
            val main = ScenarioFields(servers.getValue("main"))
            val url = main.string("url")
            val uri = URI(url)
            scenarioCheck(uri.scheme == "http" && uri.host == "127.0.0.1" && uri.port in 1..65535 &&
                uri.rawPath.isEmpty() && uri.rawQuery == null && uri.rawFragment == null && uri.userInfo == null, "invalid loopback endpoint")
            main.string("container"); main.string("data")
            val users = main.required("users").obj().mapValues { (_, value) ->
                val user = ScenarioFields(value)
                val id = user.string("id")
                SyncIdentifiers.ulid(id)
                val password = Path.of(user.string("password_file"))
                scenarioCheck(password.parent == root.resolve("secrets"), "password outside private root")
                privateRegularFile(password)
                user.finish()
                id to password
            }
            main.finish()
            scenarioCheck(users.keys == setOf("alice", "bob"), "missing smoke users")
            return SmokeRuntime(root, SyncServerURL(url), users)
        }
    }
}

internal fun privateRegularFile(path: Path) {
    scenarioCheck(!Files.isSymbolicLink(path) && Files.isRegularFile(path, NOFOLLOW_LINKS) &&
        Files.getPosixFilePermissions(path, NOFOLLOW_LINKS) == PosixFilePermissions.fromString("rw-------"), "invalid private file")
}

private class SmokeDevice(val name: String, private val directory: Path, now: Instant, private val entropy: Entropy) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val clock = Clock { now }
    private val monotonic = MonotonicClock(System::nanoTime)
    val files = DiskSyncFiles(directory.resolve("library"), library = true)
    val data = DiskSyncFiles(directory.resolve("data"))
    val secrets = FixtureSecretStore(DiskSyncFiles(directory.resolve("secrets")))
    private val driver = OkHttpHttpTransport(monotonic, scope)
    data class Trace(val method: String, val path: String, val status: Int)
    private val recorded = mutableListOf<Trace>()
    val traces: List<Trace> get() = synchronized(recorded) { recorded.toList() }
    private val transport = HttpTransport { request ->
        val response = driver.send(request)
        val uri = URI(request.url)
        synchronized(recorded) { recorded.add(Trace(request.method.rawValue, uri.rawPath + (uri.rawQuery?.let { "?$it" } ?: ""), response.statusCode)) }
        response
    }
    private val library = LibraryService(files, data, clock, entropy)
    val states = SyncStateStore(data, data.operations)
    private val accounts = SyncAccountStore(data, data.operations)
    val engine = SyncEngine(library, files.operations, data, data.operations, states, accounts, scope, Dispatchers.IO, clock, entropy, monotonic)
    val account = SyncAccountService(engine, accounts, secrets, transport, files.root.toString(), Dispatchers.IO, monotonic)

    suspend fun login(runtime: SmokeRuntime, username: String) {
        val (_, passwordFile) = runtime.users[username] ?: throw ScenarioFailure("unknown smoke user")
        val password = SecretValue(Files.readAllBytes(passwordFile).decodeToString(throwOnInvalidSequence = true))
        scenarioCheck(account.login(runtime.server.baseURL, username, password, name).enabled, "account activation failed")
        pass()
    }
    suspend fun pass() {
        engine.syncNow()
        withTimeout(180_000) { engine.drain() }
        scenarioCheck(engine.reports.value.status == SyncStatus.IDLE && engine.reports.value.lastSuccess != null, "sync pass failed")
    }
    suspend fun request(path: String): HttpResponse {
        val account = accounts.loadAccount() ?: throw ScenarioFailure("HTTP action requires account")
        val value = secrets.read(account.secretAccount, SecretReadSource.PERSISTED) ?: throw ScenarioFailure("missing device secret")
        val token = value.value.withValue { WireJson.parse(it.encodeToByteArray()).at("/token").text() }
        val server = SyncServerURL(account.identity.serverURL)
        return transport.send(HttpRequest(server.baseURL + path, HttpMethod.GET,
            headers = mapOf("Authorization" to "Bearer $token", "Accept" to "application/json"),
            requestByteCap = 1024, responseByteCap = 8 * 1024 * 1024,
            deadlineNanos = monotonic.nowNanos() + 30_000_000_000, urlPolicy = HttpUrlPolicy.Sync(server)))
    }
    fun resetMetrics() { files.resetMetrics(); synchronized(recorded) { recorded.clear() } }
    suspend fun stop() { engine.stop(); engine.drain(); scope.cancel(); scope.coroutineContext[Job]?.join() }
    fun reopen(now: Instant): SmokeDevice = SmokeDevice(name, directory, now, entropy)
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

private class SmokeScenario(private val scenario: SyncScenario, private val runtime: SmokeRuntime) {
    private val symbols = ScenarioSymbols()
    private val devices = linkedMapOf<String, SmokeDevice>()
    init {
        scenario.prompts.forEach { (name, id) -> symbols.bind("prompt.$name", id) }
        runtime.users.forEach { (name, user) -> symbols.bind("user.main.$name", user.first) }
        for (spec in scenario.devices) {
            val directory = runtime.root.resolve("devices").resolve(spec.name)
            privateDirectory(directory)
            devices[spec.name] = SmokeDevice(spec.name, directory, scenario.now, ScenarioEntropy(spec.seed))
        }
    }
    suspend fun run() {
        for (step in scenario.steps) {
            val device = devices[symbols.expand(step.device)] ?: throw ScenarioFailure("unknown device")
            when (step.action) {
                "write" -> device.files.externalWrite(symbols.expand(step.string("content")).encodeToByteArray(), symbols.expand(step.string("path")))
                "login" -> {
                    scenarioCheck(step.string("server") == "main", "unknown deployment")
                    device.login(runtime, step.string("user"))
                }
                "sync" -> device.pass()
                "http" -> {
                    scenarioCheck(step.string("method") == "GET" && step.fields.keys.all { it in setOf("method", "path", "status", "expected") }, "unsupported smoke HTTP")
                    val response = device.request(symbols.expand(step.string("path")))
                    scenarioCheck(response.statusCode.toLong() == step.fields.getValue("status").count(), "HTTP status checkpoint")
                    val body = WireJson.parse(response.body)
                    for ((pointer, value) in step.fields["expected"]?.obj().orEmpty()) {
                        scenarioCheck(body.at(symbols.expand(pointer)) == symbols.expand(value), "HTTP JSON checkpoint")
                    }
                }
                "reset_metrics" -> device.resetMetrics()
                "restart" -> {
                    device.stop()
                    val replacement = device.reopen(scenario.now)
                    devices[device.name] = replacement
                    scenarioCheck(replacement.account.startup().enabled, "account restart failed")
                    replacement.pass()
                }
                "expect" -> checkpoint(device, step.fields.getValue("expected").obj())
                else -> throw ScenarioFailure("action outside Z15 smoke")
            }
        }
        scenarioCheck(devices.values.sumOf { it.traces.size } > 0, "smoke issued no real HTTP")
    }
    suspend fun stop() { for (device in devices.values) device.stop() }
    private fun checkpoint(device: SmokeDevice, fields: Map<String, WireValue>) {
        val state = device.states.loadForAccountTransition()
        for ((key, value) in fields) when (key) {
            "files" -> value.array().forEach {
                val file = ScenarioFields(it)
                val path = symbols.expand(file.string("path"))
                val content = symbols.expand(file.string("content")).encodeToByteArray()
                scenarioCheck(device.files.read(path).contentEquals(content), "file byte checkpoint")
                file.take("mode")?.text()?.let { mode ->
                    scenarioCheck(mode in setOf("normal", "readOnly"), "unknown file mode")
                    scenarioCheck(device.files.mode(path) == PosixFilePermissions.fromString(if (mode == "readOnly") "r--r--r--" else "rw-------"), "file mode checkpoint")
                }
                file.finish()
            }
            "file_count" -> scenarioCheck(device.files.operations.listFiles().size.toLong() == value.count(), "file count checkpoint")
            "status" -> scenarioCheck(value.text() == "idle" && device.engine.reports.value.status == SyncStatus.IDLE, "status checkpoint")
            "writes" -> scenarioCheck(device.files.writes.toLong() == value.count(), "write count checkpoint")
            "history_count" -> scenarioCheck(device.data.listFiles().count { it.relativePath.startsWith("history/") }.toLong() == value.count(), "history count checkpoint")
            "state" -> value.array().forEach {
                val prompt = ScenarioFields(it)
                val id = PromptIdentity.Assigned(SyncIdentifiers.ulid(symbols.expand(prompt.string("id"))))
                val actual = state?.prompts?.get(id) ?: throw ScenarioFailure("missing state prompt")
                scenarioCheck(actual.scope.rawValue == symbols.expand(prompt.string("scope")), "state scope checkpoint")
                scenarioCheck(actual.path == symbols.expand(prompt.string("path")), "state path checkpoint")
                scenarioCheck(actual.rev == prompt.required("rev").count(), "state revision checkpoint")
                prompt.take("hash")?.text()?.let { scenarioCheck(actual.canonicalHash?.rawValue == it, "state hash checkpoint") }
                prompt.finish()
            }
            "requests" -> value.array().forEach {
                val request = ScenarioFields(it)
                val method = request.string("method")
                val path = symbols.expand(request.string("path"))
                val count = request.required("count").count()
                val status = request.take("status")?.count()
                scenarioCheck(device.traces.count { trace -> (method == "*" || trace.method == method) &&
                    (path == "*" || trace.path == path) && (status == null || trace.status.toLong() == status) }.toLong() == count, "request count checkpoint")
                request.finish()
            }
            else -> throw ScenarioFailure("checkpoint outside Z15 smoke")
        }
    }
}
