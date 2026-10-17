package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.SyncApplyJson
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.*
import java.nio.file.Path
import java.time.Instant
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess

/** Closed stdin carries the bound envelope. Only fixed markers can leave the child. */
internal class ScenarioDeviceProcess private constructor(private val process: Process,
    private val watchdog: java.util.concurrent.ScheduledExecutorService) : AutoCloseable {
    val alive: Boolean get() = process.isAlive
    companion object {
        fun launch(input: ByteArray, marker: String, timeoutMillis: Long = 120_000): ScenarioDeviceProcess {
            scenarioCheck(input.size <= 65_536, "worker input cap")
            val java = Path.of(System.getProperty("java.home"), "bin", "java").toRealPath().toString()
            val specification = ProcessBuilder(java, "-cp", System.getProperty("monkeyspaw.workerClasspath"),
                "ch.lkmc.monkeyspaw.core.integration.ScenarioDeviceWorker")
                .redirectError(ProcessBuilder.Redirect.DISCARD)
            specification.environment().clear()
            System.getenv("LD_LIBRARY_PATH")?.let { specification.environment()["LD_LIBRARY_PATH"] = it }
            val process = specification.start()
            val timer = Executors.newSingleThreadScheduledExecutor()
            val child = ScenarioDeviceProcess(process, timer)
            timer.schedule({ process.destroyForcibly() }, timeoutMillis, TimeUnit.MILLISECONDS)
            try {
                process.outputStream.use { it.write(input) }
                val bytes = mutableListOf<Byte>()
                while (bytes.lastOrNull() != 10.toByte()) {
                    val byte = process.inputStream.read()
                    scenarioCheck(byte >= 0 && bytes.size < 32, "worker exited before checkpoint")
                    bytes.add(byte.toByte())
                }
                scenarioCheck(bytes.toByteArray().contentEquals("$marker\n".encodeToByteArray()), "unexpected worker marker")
                return child
            } catch (_: Exception) {
                child.close()
                throw ScenarioFailure("worker did not reach checkpoint")
            }
        }
    }
    fun kill() {
        scenarioCheck(process.isAlive, "kill requires a live child")
        process.destroyForcibly()
        scenarioCheck(process.waitFor(5, TimeUnit.SECONDS) && process.exitValue() == 137, "actual SIGKILL termination")
    }
    fun requireSuccess() {
        scenarioCheck(process.waitFor(120, TimeUnit.SECONDS) && process.exitValue() == 0, "fresh worker recovery failed")
        scenarioCheck(process.inputStream.read() == -1, "unexpected worker output")
    }
    fun awaitWatchdog() {
        scenarioCheck(process.waitFor(5, TimeUnit.SECONDS) && process.exitValue() == 137, "watchdog must kill stalled child")
    }
    fun arguments(): List<String> = process.info().arguments().orElse(emptyArray()).toList()
    override fun close() {
        try {
            process.descendants().use { children -> children.forEach { it.destroyForcibly() } }
            if (process.isAlive) process.destroyForcibly()
            scenarioCheck(process.waitFor(5, TimeUnit.SECONDS), "worker was not reaped")
        } finally {
            process.inputStream.close()
            process.outputStream.close()
            watchdog.shutdownNow()
        }
    }
}

/** Test executable on the integration classpath, never an app or server artifact. */
internal object ScenarioDeviceWorker {
    @JvmStatic fun main(arguments: Array<String>) {
        try {
            scenarioCheck(arguments.isEmpty(), "worker accepts stdin only")
            val input = ScenarioFields(WireJson.parse(System.`in`.readNBytes(65_537)))
            val directory = Path.of(input.string("directory"))
            val name = input.string("name")
            val envelope = input.string("secret")
            val now = Instant.parse(input.string("now"))
            val checkpoint = input.string("checkpoint")
            val fileCount = input.required("file_count").count()
            input.finish()
            scenarioCheck(fileCount > 0 && checkpoint in setOf("none", "replay", "stall", "after_files", "before_state", "after_state",
                "before_state_file_flush", "before_state_directory_flush"), "invalid worker checkpoint")
            fun pause() { print("paused\n"); System.out.flush(); java.util.concurrent.CountDownLatch(1).await() }
            if (checkpoint == "stall") pause()
            val secrets = object : SecretStore {
                override suspend fun read(account: SecretAccount, source: SecretReadSource) = StoredSecret(SecretValue(envelope), SecretTier.KEYSTORE)
                override suspend fun write(value: SecretValue, account: SecretAccount): SecretTier = throw SecretStoreError.WriteFailed
                override suspend fun delete(account: SecretAccount): Unit = throw SecretStoreError.DeleteFailed
            }
            runBlocking(Dispatchers.IO) {
                val transport = ScenarioTransport()
                val device = ScenarioDevice(name, directory, now, ScenarioEntropy(5000), transport, secrets)
                var publications = 0L
                var stateWritten = false
                device.files.checkpoint = { operation, _ ->
                    if (operation == "published") {
                        publications++
                        if (checkpoint == "after_files" && publications == fileCount) pause()
                    }
                }
                device.data.checkpoint = { operation, path ->
                    if (publications > 0 && operation == "before_file_flush" && path == "sync/state.json") stateWritten = true
                    if (publications > 0 && ((checkpoint == "before_state" && operation == "before_private_write" && path == "sync/state.json") ||
                        (checkpoint == "after_state" && operation == "before_delete" && path == "sync/apply.json") ||
                        (checkpoint == "before_state_file_flush" && operation == "before_file_flush" && path == "sync/state.json") ||
                        (checkpoint == "before_state_directory_flush" && operation == "before_directory_flush" && path == "sync" && stateWritten))) pause()
                }
                try {
                    val journal = if (checkpoint == "none") {
                        scenarioCheck(device.data.stamp("sync/apply.json") != null, "recovery requires the killed journal")
                        SyncApplyJson.codec.decode(WireJson.parse(device.data.read("sync/apply.json")) as WireValue.ObjectValue)
                    } else null
                    val beforeReplay = if (checkpoint == "replay") device.states.loadForAccountTransition() else null
                    if (checkpoint == "replay") scenarioCheck(device.data.stamp("sync/apply.json") == null, "second replay requires recovered journal")
                    val result = device.account.startup()
                    scenarioCheck(result.enabled && result.cleanup.isComplete, "worker account activation")
                    if (journal != null) {
                        // Startup prepares the old graph locally before enabling foreground propagation.
                        scenarioCheck(device.data.stamp("sync/apply.json") == null && device.states.loadForAccountTransition() == journal.nextState,
                            "startup did not commit the exact killed journal intent")
                        scenarioCheck(transport.traces.none { it.method == "PUT" || it.path == "/api/v1/sync/pull" },
                            "journal replay must precede fresh pull and push")
                        for (step in journal.steps.filter { it.edit.copyID != null }) scenarioCheck(
                            device.files.read(step.edit.path).contentEquals(step.edit.bytes!!), "local replay changed stable losing copy")
                    }
                    if (checkpoint == "replay") device.engine.recoverJournal()
                    else device.engine.setExecutionMode(SyncExecutionMode.FOREGROUND)
                    device.settle()
                    scenarioCheck(device.engine.reports.value.blockingIssue == null && device.data.stamp("sync/apply.json") == null,
                        "worker recovery incomplete")
                    if (checkpoint == "replay") scenarioCheck(transport.traces.none { it.method == "PUT" || it.path == "/api/v1/sync/pull" } &&
                        device.files.writes == 0 && device.states.loadForAccountTransition() == beforeReplay, "second replay changed local intent or repeated HTTP")
                } finally { device.stop(); transport.close() }
            }
            print("complete\n"); System.out.flush()
            exitProcess(0)
        } catch (_: Throwable) { exitProcess(1) }
    }
}
