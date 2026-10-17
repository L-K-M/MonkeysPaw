package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.domain.sync.SyncIdentifiers
import ch.lkmc.monkeyspaw.core.sync.SyncServerURL
import ch.lkmc.monkeyspaw.core.syncapi.WireJson
import kotlinx.coroutines.*
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import java.time.Duration
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors

internal class ScenarioDeployment(val server: SyncServerURL, val users: Map<String, Pair<String, Path>>)

internal fun privateRegularFile(path: Path) {
    scenarioCheck(!Files.isSymbolicLink(path) && Files.isRegularFile(path, NOFOLLOW_LINKS) &&
        Files.getPosixFilePermissions(path, NOFOLLOW_LINKS) == PosixFilePermissions.fromString("rw-------"), "invalid private file")
}

/** Fresh databases are necessary: independent fixtures deliberately reuse immutable prompt IDs. */
internal class ScenarioRuntime private constructor(val root: Path, private val templateContainer: String,
                                                   private val passwords: Map<String, Path>) {
    companion object {
        fun read(path: Path): ScenarioRuntime {
            privateRegularFile(path)
            val fields = ScenarioFields(WireJson.parse(Files.readAllBytes(path)))
            scenarioCheck(fields.required("schema").count() == 1L, "unsupported manifest")
            val root = Path.of(fields.string("root"))
            scenarioCheck(root.isAbsolute && !Files.isSymbolicLink(root) && Files.isDirectory(root, NOFOLLOW_LINKS) &&
                Files.getPosixFilePermissions(root) == PosixFilePermissions.fromString("rwx------"), "invalid runtime root")
            scenarioCheck(path.toAbsolutePath().parent == root, "manifest outside runtime root")
            val servers = fields.required("servers").obj()
            fields.finish()
            scenarioCheck(servers.keys == setOf("main"), "template requires one deployment")
            val main = ScenarioFields(servers.getValue("main"))
            val uri = URI(main.string("url"))
            scenarioCheck(uri.scheme == "http" && uri.host == "127.0.0.1" && uri.port in 1..65535 && uri.rawPath.isEmpty() &&
                uri.rawQuery == null && uri.rawFragment == null && uri.userInfo == null, "invalid loopback endpoint")
            val container = main.string("container")
            main.string("data")
            val users = main.required("users").obj().mapValues { (_, value) ->
                val user = ScenarioFields(value)
                SyncIdentifiers.ulid(user.string("id"))
                val password = Path.of(user.string("password_file"))
                scenarioCheck(password.parent == root.resolve("secrets"), "password outside private root")
                privateRegularFile(password)
                user.finish()
                password
            }
            main.finish()
            scenarioCheck(users.keys == setOf("alice", "bob"), "missing scenario users")
            return ScenarioRuntime(root, container, users)
        }
    }

    suspend fun run(scenario: SyncScenario, operation: suspend (Path, Map<String, ScenarioDeployment>) -> Unit) {
        val ownedRoot = root.resolve("case-" + UUID.randomUUID())
        privateDirectory(ownedRoot)
        val servers = mutableListOf<LocalServer>()
        try {
            val deployments = linkedMapOf<String, ScenarioDeployment>()
            for (name in scenario.servers) {
                val directory = ownedRoot.resolve("server-$name")
                privateDirectory(directory)
                val server = LocalServer(directory)
                servers.add(server)
                deployments[name] = server.start(scenario.users)
            }
            operation(ownedRoot, deployments)
        } finally {
            withContext(NonCancellable) {
                var failed = false
                for (server in servers.asReversed()) try { server.close() } catch (_: Throwable) { failed = true }
                try { Files.walk(ownedRoot).use { paths -> paths.sorted(Comparator.reverseOrder()).forEach(Files::delete) } }
                catch (_: Exception) { failed = true }
                scenarioCheck(!failed, "scenario server cleanup failed")
            }
        }
    }

    private inner class LocalServer(private val data: Path) {
        private val native = System.getenv("MONKEYSPAW_SYNC_SERVER_EXECUTABLE")?.takeIf { it.isNotEmpty() }?.let { executable(Path.of(it)) }
        private var process: Process? = null
        private var container: String? = null
        private val environment = mapOf("MONKEYSPAW_DATA_DIR" to data.toString(), "MONKEYSPAW_HTTP_HOST" to "127.0.0.1",
            "MONKEYSPAW_LOG_LEVEL" to "critical", "MONKEYSPAW_ADMIN_PASSWORD_FILE" to passwords.getValue("alice").toString())
        suspend fun start(users: List<String>): ScenarioDeployment {
            val port: Int
            val adminCommand: List<String>
            if (native != null) {
                port = ServerSocket(0, 0, InetAddress.getByName("127.0.0.1")).use { it.localPort }
                process = builder(listOf(native, "serve"), environment + ("MONKEYSPAW_HTTP_PORT" to port.toString()))
                    .redirectOutput(ProcessBuilder.Redirect.DISCARD).start()
                adminCommand = listOf(native)
            } else {
                val docker = findExecutable("docker")
                val image = command(listOf(docker, "inspect", "--format", "{{.Image}}", templateContainer)).decodeToString().trim()
                scenarioCheck(Regex("sha256:[a-f0-9]{64}").matches(image), "invalid server image identity")
                val name = "monkeyspaw-z16-" + UUID.randomUUID().toString()
                container = name
                command(listOf(docker, "run", "--detach", "--name", name, "--user", Files.getAttribute(root, "unix:uid").toString() + ":" + Files.getAttribute(root, "unix:gid"),
                    "--publish", "127.0.0.1::8080", "--volume", "$data:/data", "--volume", "${root.resolve("secrets")}:/run/secrets:ro",
                    "--env", "MONKEYSPAW_ADMIN_PASSWORD_FILE=/run/secrets/alice", image))
                val bindings = WireJson.parse(command(listOf(docker, "inspect", "--format", "{{json .NetworkSettings.Ports}}", name))).obj().getValue("8080/tcp").array()
                scenarioCheck(bindings.size == 1 && bindings[0].at("/HostIp").text() == "127.0.0.1", "invalid loopback publication")
                port = bindings[0].at("/HostPort").text().toInt()
                scenarioCheck(port in 1..65535, "invalid server port")
                adminCommand = listOf(docker, "exec", name, "/usr/local/bin/monkeyspaw-server")
            }
            val url = "http://127.0.0.1:$port"
            waitHealthy(url)
            val seeded = users.associateWith { user ->
                val password = passwords[user] ?: throw ScenarioFailure("unknown provisioned user")
                val path = if (native != null) password.toString() else "/run/secrets/$user"
                val created = WireJson.parse(command(adminCommand + listOf("user", "add", user, "--password-file", path, "--json"), environment))
                val id = SyncIdentifiers.ulid(created.at("/id").text()).rawValue
                id to password
            }
            return ScenarioDeployment(SyncServerURL(url), seeded)
        }
        suspend fun close() {
            process?.let { child ->
                child.destroy()
                if (!child.waitFor(5, TimeUnit.SECONDS)) child.destroyForcibly()
                scenarioCheck(child.waitFor(5, TimeUnit.SECONDS), "native server did not stop")
            }
            container?.let { command(listOf(findExecutable("docker"), "rm", "--force", it)) }
        }
    }
}

private fun executable(path: Path): String {
    scenarioCheck(path.isAbsolute && Files.isRegularFile(path) && Files.isExecutable(path), "required executable unavailable")
    return path.toRealPath().toString()
}
private fun findExecutable(name: String): String {
    val path = System.getenv("PATH").split(':').map { Path.of(it, name) }.firstOrNull { it.isAbsolute && Files.isExecutable(it) }
        ?: throw ScenarioFailure("required executable unavailable")
    return executable(path)
}
private fun builder(arguments: List<String>, environment: Map<String, String>): ProcessBuilder = ProcessBuilder(arguments)
    .redirectInput(ProcessBuilder.Redirect.from(Path.of("/dev/null").toFile())).redirectError(ProcessBuilder.Redirect.DISCARD)
    .also { it.environment().putAll(environment) }

/** Drain bounded output before awaiting exit; every timeout reaps the owned process. */
private suspend fun command(arguments: List<String>, environment: Map<String, String> = emptyMap()): ByteArray = withContext(Dispatchers.IO) {
    val child = builder(arguments, environment).start()
    val reader = Executors.newSingleThreadExecutor()
    try {
        val output = reader.submit<ByteArray> { child.inputStream.use { it.readNBytes(65_537) } }.get(55, TimeUnit.SECONDS)
        scenarioCheck(output.size <= 65_536, "command output exceeded limit")
        scenarioCheck(child.waitFor(5, TimeUnit.SECONDS) && child.exitValue() == 0, "scenario server command failed")
        output
    } catch (error: Exception) {
        throw (error as? ScenarioFailure ?: ScenarioFailure("scenario server command failed or timed out"))
    } finally {
        child.descendants().use { descendants -> descendants.forEach { it.destroyForcibly() } }
        if (child.isAlive) child.destroyForcibly()
        scenarioCheck(child.waitFor(5, TimeUnit.SECONDS), "scenario command did not stop")
        reader.shutdownNow()
    }
}
private suspend fun waitHealthy(url: String) {
    val http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).followRedirects(HttpClient.Redirect.NEVER).build()
    withTimeout(120_000) {
        while (true) {
            val healthy = try {
                val response = http.send(HttpRequest.newBuilder(URI("$url/api/health")).timeout(Duration.ofSeconds(5)).build(), HttpResponse.BodyHandlers.ofInputStream())
                val bytes = response.body().use { it.readNBytes(4097) }
                response.statusCode() == 200 && bytes.size <= 4096 && WireJson.parse(bytes).at("/status").text() == "ok"
            } catch (_: Exception) { false }
            if (healthy) break
            delay(100)
        }
    }
}
