package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.llm.AssistantAction
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantMessage
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantOutput
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantRequest
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantResponse

internal val AssistantMessage.wireValue: Map<String, String>
    get() = mapOf("role" to role.rawValue, "content" to content)

internal val AssistantRequest.userMessage: AssistantMessage
    get() {
        var content = when (val intent = action) {
            is AssistantAction.Write -> AssistantPrompts.writeData(intent.brief)
            is AssistantAction.Review -> AssistantPrompts.reviewData(intent.source)
            is AssistantAction.Improve -> AssistantPrompts.improveData(intent.source, intent.instruction, intent.selectedFindings)
        }
        feedback?.let { content += "\n" + AssistantPrompts.data(it, "feedback") }
        return AssistantMessage(AssistantMessage.Role.USER, content)
    }

internal val AssistantRequest.messages: List<AssistantMessage>
    get() = transcript + userMessage

/** Compatible chat templates can require alternating roles; retain the original session turns. */
internal val AssistantRequest.wireMessages: List<AssistantMessage>
    get() {
        val turns = mutableListOf<AssistantMessage>()
        for (message in messages) {
            val last = turns.lastOrNull()
            if (last?.role == message.role) {
                turns[turns.lastIndex] = AssistantMessage(message.role, last.content + "\n\n" + message.content)
            } else {
                turns.add(message)
            }
        }
        return turns
    }

/** Strict output shape, including empty properties and notes, without local issues or quote ranges. */
internal fun AssistantResponse.transcriptMessage(): AssistantMessage {
    val value = when (val result = output) {
        is AssistantOutput.Artifact -> result.value.let { artifact ->
            mapOf("title" to artifact.title, "description" to artifact.description, "tags" to artifact.tags,
                "body" to artifact.body, "notes" to artifact.notes, "fields" to artifact.fields.map { field ->
                    mapOf("name" to field.name, "type" to field.type.rawValue, "label" to field.label,
                        "description" to field.description, "default" to field.defaultValue,
                        "optional" to field.optional, "remember" to field.remember,
                        "options" to field.options.map { mapOf("label" to it.label, "value" to it.value) })
                })
        }
        is AssistantOutput.Review -> result.value.let { review ->
            mapOf("summary" to review.summary, "findings" to review.findings.map {
                mapOf("severity" to it.severity.rawValue, "criterion" to it.criterion.rawValue,
                    "quote" to it.quote, "problem" to it.problem, "suggestion" to it.suggestion)
            })
        }
    }
    return AssistantMessage(AssistantMessage.Role.ASSISTANT, AssistantJson.encode(value))
}
