package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.syncapi.*
import ch.lkmc.monkeyspaw.core.domain.llm.SecretReadSource
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertFailsWith

class ScenarioDeviceProcessTest {
    @Test fun watchdogKillsARealStalledChildWithNoSecretArguments() {
        val sentinel = "runtime-only-secret-" + java.util.UUID.randomUUID()
        val input = WireJson.canonical(wireObject("directory" to wireString("/unused"), "name" to wireString("a"),
            "secret" to wireString(sentinel), "now" to wireString("2026-10-14T00:00:00Z"),
            "checkpoint" to wireString("stall"), "file_count" to wireLong(1)))
        ScenarioDeviceProcess.launch(input, "paused", timeoutMillis = 3000).use { child ->
            scenarioCheck(child.alive, "stalled child must be alive")
            scenarioCheck(child.arguments().isNotEmpty() && child.arguments().none { sentinel in it }, "stdin secret reached argv")
            child.awaitWatchdog()
            scenarioCheck(!child.alive, "watchdog left child alive")
        }
    }
    @Test fun malformedInputFailsWithoutLeavingAChild() {
        assertFailsWith<ScenarioFailure> { ScenarioDeviceProcess.launch("{}".encodeToByteArray(), "paused", 3000) }
    }
    @Test fun aRecoveryWorkerCannotSubstituteAFreshSyncForTheKilledJournal() {
        val scenario = ScenarioDecoder.decode(Files.readAllBytes(fixtureRoot().resolve("01-round-trip.json"))).single()
        runLiveScenario(scenario) { runner ->
            runner.run()
            val device = runner.device("a")
            device.engine.stop(); device.settle()
            val account = device.accounts.loadAccount()!!
            val secret = device.secrets.read(account.secretAccount, SecretReadSource.PERSISTED)!!
            val input = secret.value.withValue { WireJson.canonical(wireObject("directory" to wireString(device.directory.toString()),
                "name" to wireString(device.name), "secret" to wireString(it), "now" to wireString(device.now.toString()),
                "checkpoint" to wireString("none"), "file_count" to wireLong(1))) }
            assertFailsWith<ScenarioFailure> { ScenarioDeviceProcess.launch(input, "complete").use { it.requireSuccess() } }
        }
    }
    @Test fun stateFileAndDirectoryFlushInterruptionsRecoverTwiceOverRealHTTP() {
        for (checkpoint in listOf("before_state_file_flush", "before_state_directory_flush")) {
            val scenario = ScenarioDecoder.decode(Files.readAllBytes(fixtureRoot().resolve("17-crash-apply.json")))
                .single { it.id == "17-killed-after-state" }
            val changed = scenario.copy(steps = scenario.steps.map { step ->
                if (step.action == "kill_client") step.copy(fields = step.fields + ("checkpoint" to wireString(checkpoint))) else step
            })
            runLiveScenario(changed)
        }
    }
}
