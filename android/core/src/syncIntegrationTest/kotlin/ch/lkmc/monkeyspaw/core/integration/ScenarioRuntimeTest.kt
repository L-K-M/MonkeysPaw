package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.runBlocking
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import java.time.Instant
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess
import kotlin.test.*

class ScenarioRuntimeTest {
    /** Fake health/control processes isolate ownership, without claiming sync scenario execution. */
    @Test fun aFailedRetentionPollCannotOrphanTheNativeServer(): Unit = withPrivateTestRoot { root ->
        val python = System.getenv("PATH").split(':').map { Path.of(it, "python3") }
            .first { it.isAbsolute && Files.isExecutable(it) }.toRealPath()
        val native = root.resolve("server")
        Files.writeString(native, """
            #!$python
            import http.server, os, pathlib
            class Health(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'{"status":"ok"}')
                def log_message(self, *args): pass
            server = http.server.HTTPServer(('127.0.0.1', int(os.environ['MONKEYSPAW_HTTP_PORT'])), Health)
            with pathlib.Path(__file__).with_name('pids').open('a') as ledger:
                ledger.write(str(os.getpid()) + '\n')
            server.serve_forever()
        """.trimIndent() + "\n")
        Files.setPosixFilePermissions(native, PosixFilePermissions.fromString("rwx------"))
        val control = root.resolve("control.py")
        Files.writeString(control, """
            import json, pathlib, sys
            action = json.load(sys.stdin)['action']
            if action == 'retention_begin':
                print('{}')
            elif action == 'inspect':
                pathlib.Path(__file__).with_name('poll-failed').touch()
                sys.exit(1)
            else:
                sys.exit(2)
        """.trimIndent())
        privateDirectory(root.resolve("secrets"))
        val users = listOf("alice", "bob").associateWith { user ->
            val password = root.resolve("secrets").resolve(user)
            Files.writeString(password, "fixture-only")
            Files.setPosixFilePermissions(password, PosixFilePermissions.fromString("rw-------"))
            wireObject("id" to wireString("01ARZ3NDEKTSV4RRFFQ69G5FAZ"), "password_file" to wireString(password.toString()))
        }
        val manifest = root.resolve("manifest.json")
        Files.write(manifest, WireJson.canonical(wireObject("schema" to wireLong(1), "root" to wireString(root.toString()),
            "servers" to wireObject("main" to wireObject("url" to wireString("http://127.0.0.1:1"),
                "container" to wireString("native"), "data" to wireString(root.toString()), "users" to WireValue.ObjectValue(users))))))
        Files.setPosixFilePermissions(manifest, PosixFilePermissions.fromString("rw-------"))
        val java = Path.of(System.getProperty("java.home"), "bin", "java").toRealPath().toString()
        val specification = ProcessBuilder(java, "-cp", System.getProperty("monkeyspaw.workerClasspath"),
            "ch.lkmc.monkeyspaw.core.integration.ScenarioRuntimeFailureWorker", root.toString())
            .redirectOutput(ProcessBuilder.Redirect.DISCARD).redirectError(ProcessBuilder.Redirect.DISCARD)
        val environment = specification.environment()
        environment.clear()
        environment["PATH"] = System.getenv("PATH")
        System.getenv("LD_LIBRARY_PATH")?.let { environment["LD_LIBRARY_PATH"] = it }
        environment["MONKEYSPAW_SYNC_SERVER_EXECUTABLE"] = native.toString()
        val child = specification.start()
        child.outputStream.close()
        try {
            assertTrue(child.waitFor(30, TimeUnit.SECONDS), "runtime cleanup worker timed out")
            assertTrue(Files.exists(root.resolve("poll-failed")), "retention poll failure was not reached")
            assertEquals(0, child.exitValue(), "native server remained alive after runtime cleanup")
        } finally {
            child.descendants().use { descendants -> descendants.forEach { it.destroyForcibly() } }
            if (child.isAlive) child.destroyForcibly()
            assertTrue(child.waitFor(5, TimeUnit.SECONDS), "runtime cleanup worker was not reaped")
            val ledger = root.resolve("pids")
            if (Files.exists(ledger)) for (pid in Files.readAllLines(ledger)) {
                ProcessHandle.of(pid.toLong()).ifPresent { if (it.isAlive) it.destroyForcibly() }
            }
        }
    }
}

internal object ScenarioRuntimeFailureWorker {
    @JvmStatic fun main(arguments: Array<String>) {
        var status = 1
        try {
            val root = Path.of(arguments.single())
            System.setProperty("monkeyspaw.syncControl", root.resolve("control.py").toString())
            val scenario = SyncScenario("retention-cleanup", Instant.EPOCH, listOf("main"), emptyList(), emptyList(), emptyMap(), emptyList())
            runBlocking {
                assertFailsWith<ScenarioFailure> {
                    ScenarioRuntime.read(root.resolve("manifest.json")).run(scenario) { _, deployments ->
                        deployments.getValue("main").control(mapOf("action" to wireString("retention")))
                    }
                }
            }
            val servers = Files.readAllLines(root.resolve("pids")).mapNotNull { ProcessHandle.of(it.toLong()).orElse(null) }
            try { status = if (servers.any { it.isAlive }) 2 else 0 }
            finally { for (server in servers) if (server.isAlive) { server.destroyForcibly(); server.onExit().get(5, TimeUnit.SECONDS) } }
        } catch (_: Throwable) { status = 1 }
        exitProcess(status)
    }
}
