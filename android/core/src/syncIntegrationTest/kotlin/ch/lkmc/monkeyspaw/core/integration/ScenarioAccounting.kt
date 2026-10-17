package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.syncapi.*

internal fun scenarioActions(step: ScenarioStep): List<ScenarioStep> {
    val then = step.fields["then"]
    return listOf(step) + if (then == null) emptyList() else
        (if (then is WireValue.ArrayValue) then.values else listOf(then)).flatMap { scenarioActions(ScenarioDecoder.decodeStep(it)) }
}

/** Count each asserted leaf; action inputs/bindings are covered by the action ledger. */
internal fun scenarioExpectations(step: ScenarioStep): Int {
    fun leaves(value: WireValue): Int = when (value) {
        is WireValue.ObjectValue -> maxOf(1, value.fields.values.sumOf(::leaves))
        is WireValue.ArrayValue -> maxOf(1, value.values.sumOf(::leaves))
        else -> 1
    }
    val repetitions = if (step.action == "http_series") step.fields.getValue("ids").array().size else 1
    return (step.fields["expected"]?.let(::leaves) ?: 0) * repetitions
}

internal class ScenarioAccounting(private val cases: List<SyncScenario>, private val files: Set<String>) {
    private val completed = mutableSetOf<String>()
    private var actions = 0
    private var expectations = 0
    @Synchronized fun record(scenario: SyncScenario, runner: ScenarioRunner) {
        scenarioCheck(completed.add(scenario.id), "case executed more than once")
        val expected = scenario.steps.flatMap(::scenarioActions)
        scenarioCheck(runner.actions == expected.size && runner.expectations == expected.sumOf(::scenarioExpectations), "scenario consumption gap")
        actions += runner.actions
        expectations += runner.expectations
    }
    @Synchronized fun finish() {
        scenarioCheck(completed == cases.map { it.id }.toSet(), "unconsumed sync case")
        scenarioCheck(files.map { it.take(2) }.toSet() == (1..23).map { "%02d".format(it) }.toSet(), "missing acceptance family")
        println("Full semantic sync acceptance: ${files.size} files / ${completed.size} cases / $actions actions / $expectations expectations; pending 0.")
    }
}
