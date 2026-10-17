package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.*
import org.junit.AfterClass
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertFailsWith

/** Every case is named and executes once; class completion rejects a consumption gap. */
@RunWith(Parameterized::class)
class ScenarioRunnerTest internal constructor(private val id: String, private val scenario: SyncScenario) {
    companion object {
        private val corpus = SyncScenarioCorpus.load(fixtureRoot())
        private val accounting = ScenarioAccounting(corpus.second, corpus.first)
        @JvmStatic @Parameterized.Parameters(name = "{0}")
        fun scenarios(): Collection<Array<Any>> = corpus.second.map { arrayOf(it.id, it) }
        @JvmStatic @AfterClass fun completeCorpus() = accounting.finish()
    }
    @Test fun executesEveryCheckpointOverRealHTTP() {
        runLiveScenario(scenario) { runner -> runner.run(); accounting.record(scenario, runner) }
        println("PASS sync scenario: $id")
    }
}

internal fun fixtureRoot(): Path = Path.of(System.getProperty("monkeyspaw.fixtures"), "sync")
internal fun liveRuntime(): ScenarioRuntime {
    val manifest = System.getenv("MONKEYSPAW_SYNC_MANIFEST")?.takeIf { it.isNotEmpty() }
    scenarioCheck(manifest != null, "required live server manifest missing")
    return ScenarioRuntime.read(Path.of(manifest!!))
}
internal fun runLiveScenario(scenario: SyncScenario, verify: suspend (ScenarioRunner) -> Unit = { it.run() }) {
    val runtime = liveRuntime()
    runBlocking(Dispatchers.IO) {
        withTimeout(300_000) {
            runtime.run(scenario) { root, deployments ->
                val runner = ScenarioRunner(scenario, root, deployments)
                try { verify(runner) }
                finally { withContext(NonCancellable) { withTimeout(10_000) { runner.stop() } } }
            }
        }
    }
}

class ScenarioRunnerMutationTest {
    private fun roundTrip(): WireValue = WireJson.parse(Files.readAllBytes(fixtureRoot().resolve("01-round-trip.json")))
    private fun decode(value: WireValue) = ScenarioDecoder.decode(WireJson.canonical(value)).single()

    @Test fun changedFileCheckpointFailsAfterRealHTTP() {
        liveRuntime()
        val changed = decode(roundTrip().patching(mapOf("/cases/0/steps/4/expected/files/0/content" to wireString("incorrect bytes"))))
        val failure = assertFailsWith<ScenarioFailure> { runLiveScenario(changed) }
        scenarioCheck(failure.message?.contains("exact file bytes") == true, "wrong failure for changed file checkpoint")
    }
    @Test fun unusedAcknowledgementLossFailsAfterRealHTTP() {
        liveRuntime()
        val original = decode(roundTrip())
        val changed = original.copy(steps = listOf(ScenarioStep("drop_next_response", "a", mapOf("method" to wireString("PUT"),
            "path" to wireString("/api/v1/prompts/01ARZ3NDEKTSV4RRFFQ69G5FAY")))) + original.steps)
        val failure = assertFailsWith<ScenarioFailure> { runLiveScenario(changed) }
        scenarioCheck(failure.message?.contains("unused network mutation") == true, "wrong failure for unused hook")
    }
    @Test fun wrongMoveEventFailsAfterRealHTTP() {
        liveRuntime()
        val envelope = WireJson.parse(Files.readAllBytes(fixtureRoot().resolve("20-move-echo-pages.json")))
        val fields = envelope.at("/cases/0").obj()
        val steps = fields.getValue("steps").array()
        val index = steps.indexOfFirst { runCatching { it.at("/expected/pages/0/contains/0/kind").text() }.getOrNull() == "move_out" }
        scenarioCheck(index >= 0, "missing move checkpoint")
        val changed = envelope.patching(mapOf("/cases/0/steps/$index/expected/pages/0/contains/0/kind" to wireString("delete")))
        val scenario = ScenarioDecoder.decode(WireJson.canonical(changed)).first()
        val failure = assertFailsWith<ScenarioFailure> { runLiveScenario(scenario) }
        scenarioCheck(failure.message?.contains("required move/feed event") == true, "wrong failure for move checkpoint")
    }
    @Test fun invalidProtectedIdentityFailsAfterRealHTTP() {
        liveRuntime()
        val original = decode(roundTrip())
        val changed = original.copy(steps = original.steps + ScenarioDecoder.decodeStep(wireObject("action" to wireString("expect"),
            "device" to wireString("a"), "expected" to wireObject("protected_ids" to WireValue.ArrayValue(listOf(wireString("invalid-id")))))))
        val failure = assertFailsWith<ScenarioFailure> { runLiveScenario(changed) }
        scenarioCheck(failure.message?.contains("invalid checkpoint identity") == true, "wrong failure for invalid identity")
    }
    @Test fun unsupportedActionAndCheckpointFailAtExecution() {
        runLiveScenario(decode(roundTrip())) { runner ->
            assertFailsWith<ScenarioFailure> { runner.execute(ScenarioStep("unknown", "a", emptyMap())) }
            assertFailsWith<ScenarioFailure> { runner.checkpoints.check(runner.device("a"), mapOf("unknown" to wireLong(0))) }
            runner.run()
        }
    }
    @Test fun anUnregisteredActionMemberCannotPassTheDecoder() {
        val step = roundTrip().at("/cases/0/steps/0").obj()
        assertFailsWith<ScenarioFailure> { ScenarioDecoder.decodeStep(WireValue.ObjectValue(step + ("unused" to wireLong(1)))) }
    }
    @Test fun anUnconsumedCaseCannotPassAggregateAccounting() {
        val corpus = SyncScenarioCorpus.load(fixtureRoot())
        assertFailsWith<ScenarioFailure> { ScenarioAccounting(corpus.second, corpus.first).finish() }
    }
    @Test fun aLaterExternalWatchRunsTheProductionDebounceAndPush() {
        runLiveScenario(decode(roundTrip())) { runner ->
            runner.run()
            val device = runner.device("a")
            device.transport.resetMetrics()
            val path = device.states.loadForAccountTransition()!!.prompts.values.single().path
            device.files.externalWrite(device.files.read(path) + "Later external edit.\n".encodeToByteArray(), path)
            device.watch(path)
            device.fireTimers(3)
            scenarioCheck(device.transport.traces.any { it.method == "POST" && it.path == "/api/v1/sync/pull" && it.status == 200 }, "external watch must pull")
            scenarioCheck(device.transport.traces.count { it.method == "PUT" && it.status == 200 } == 1, "external watch must push once")
        }
    }
    @Test fun anOfflineAttemptCannotConsumeAResponseMutation() {
        liveRuntime()
        val original = decode(roundTrip())
        val tail = listOf(
            ScenarioStep("network", "a", mapOf("mode" to wireString("offline"))),
            ScenarioStep("rewrite_next_response", "a", mapOf("method" to wireString("POST"),
                "path" to wireString("/api/v1/sync/pull"), "patch" to wireObject("/removed" to WireValue.ArrayValue(emptyList())))),
            ScenarioStep("sync", "a", emptyMap()),
            ScenarioStep("expect", "a", mapOf("expected" to wireObject("status" to wireString("offline")))),
        )
        val failure = assertFailsWith<ScenarioFailure> { runLiveScenario(original.copy(steps = original.steps + tail)) }
        scenarioCheck(failure.message?.contains("unused network mutation") == true, "response mutation must await a real response")
    }
    @Test fun anUnmatchedTimerDelayCannotFireTheDebounce() {
        runLiveScenario(decode(roundTrip())) { runner ->
            runner.run()
            val device = runner.device("a")
            device.transport.resetMetrics()
            val path = device.states.loadForAccountTransition()!!.prompts.values.single().path
            device.files.externalWrite(device.files.read(path) + "Another external edit.\n".encodeToByteArray(), path)
            device.watch(path)
            device.fireTimers(4)
            scenarioCheck(device.transport.traces.isEmpty(), "unmatched timer delay fired the debounce")
            device.fireTimers(3)
            scenarioCheck(device.transport.traces.count { it.method == "PUT" && it.status == 200 } == 1, "matching timer delay must push once")
        }
    }
}
