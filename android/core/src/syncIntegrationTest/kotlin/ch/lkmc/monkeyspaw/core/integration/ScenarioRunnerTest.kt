package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.*
import org.junit.Assume.assumeTrue
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertFailsWith

/** Named partial proof only. Z17 owns the twelve external-control cases and aggregate ownership. */
@RunWith(Parameterized::class)
class ScenarioRunnerTest internal constructor(private val id: String, private val scenario: SyncScenario) {
    companion object {
        @JvmStatic @Parameterized.Parameters(name = "{0}")
        fun scenarios(): Collection<Array<Any>> = selectedScenarios().map { arrayOf(it.id, it) }
    }
    @Test fun executesEverySelectedCheckpointOverRealHTTP() {
        runLiveScenario(scenario)
        println("PASS Z16 named partial scenario: $id")
    }
}

internal fun fixtureRoot(): Path = Path.of(System.getProperty("monkeyspaw.fixtures"), "sync")
internal fun selectedScenarios(): List<SyncScenario> {
    val deferred = setOf("06-removed-retention.json", "17-crash-apply.json", "22-restore-lower-head.json", "23-quiet-scope-retention.json")
    val deferredPaging = setOf("08-frozen-pages-survive-real-purge", "08-expired-manifest-discards-collected-page", "08-restarted-manifest")
    val corpus = SyncScenarioCorpus.load(fixtureRoot())
    val deferredIDs = deferred.flatMap { file -> ScenarioDecoder.decode(Files.readAllBytes(fixtureRoot().resolve(file))).map { it.id } }.toSet() + deferredPaging
    val cases = corpus.second.filter { it.id !in deferredIDs }
    scenarioCheck(cases.size == 75 && cases.map { it.id }.distinct().size == cases.size, "named Z16 inventory changed; coordinate selection with Z17")
    return cases
}
internal fun liveRuntime(): ScenarioRuntime {
    val manifest = System.getenv("MONKEYSPAW_SYNC_MANIFEST")?.takeIf { it.isNotEmpty() }
    if (manifest == null && System.getenv("MONKEYSPAW_REQUIRE_SYNC_SERVER") != "1") {
        assumeTrue("Z16 named live proof requires a server manifest; local infrastructure checks remain separate", false)
    }
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
}
