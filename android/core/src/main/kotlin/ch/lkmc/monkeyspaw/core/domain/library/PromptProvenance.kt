package ch.lkmc.monkeyspaw.core.domain.library

import ch.lkmc.monkeyspaw.core.domain.llm.AssistantTokenUsage
import java.time.Instant

/** Local attribution only; prompt content, instructions, notes and credentials never belong here. */
@ConsistentCopyVisibility
data class PromptProvenance internal constructor(
    val timestamp: Instant,
    val providerHost: String,
    val model: String,
    val usage: AssistantTokenUsage?,
) {
    enum class Origin(val rawValue: String) { LLM("llm") }

    val origin: Origin = Origin.LLM

    override fun toString(): String = "<prompt provenance>"
}
