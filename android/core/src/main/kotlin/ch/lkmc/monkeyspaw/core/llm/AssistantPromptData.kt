package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.llm.LlmReview

internal fun AssistantPrompts.writeData(brief: String): String = data(brief, "brief")

internal fun AssistantPrompts.reviewData(source: String): String = data(source, "prompt")

internal fun AssistantPrompts.improveData(source: String, instruction: String,
                                        selectedFindings: List<LlmReview.Finding> = emptyList()): String {
    val findings = selectedFindings.joinToString("\n") {
        "<finding>\n" + listOf(data(it.criterion.rawValue, "criterion"), data(it.severity.rawValue, "severity"),
            data(it.quote, "quote"), data(it.problem, "problem"), data(it.suggestion, "suggestion"))
            .joinToString("\n") + "\n</finding>"
    }
    // Long source material precedes the edit; only trusted literals supply tag names.
    return data(source, "prompt") + "\n<findings>\n" + findings + "\n</findings>\n" + data(instruction, "instruction")
}

internal fun AssistantPrompts.data(value: String, tag: String): String {
    val escaped = value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        .replace("\"", "&quot;").replace("'", "&apos;")
    return "<$tag>\n$escaped\n</$tag>"
}
