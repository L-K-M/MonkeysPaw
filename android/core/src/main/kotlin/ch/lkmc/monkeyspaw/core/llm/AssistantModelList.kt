package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.llm.AssistantError
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantModelPage
import ch.lkmc.monkeyspaw.core.domain.llm.ModelDescriptor
import ch.lkmc.monkeyspaw.core.domain.llm.ProviderConnection
import ch.lkmc.monkeyspaw.core.domain.llm.ProviderKind
import ch.lkmc.monkeyspaw.core.domain.llm.hasControls
import ch.lkmc.monkeyspaw.core.domain.llm.trimProviderWhitespace

internal fun LlmJsonValue.optionalString(key: String): String? = optional(key)?.string()
internal fun LlmJsonValue.optional(key: String): LlmJsonValue? =
    ((this as? LlmJsonValue.Object)?.members ?: throw AssistantError.InvalidOutput)[key]?.takeUnless { it == LlmJsonValue.Null }

/** One page only. Service-level pagination, sorting and deduplication belong to L10. */
internal object AssistantModelList {
    fun validID(id: String): Boolean = id.trimProviderWhitespace().isNotEmpty() && !id.hasControls()

    fun url(connection: ProviderConnection, afterID: String?): String {
        if (afterID == null) return connection.modelsURL
        if (!validID(afterID)) throw AssistantError.InvalidOutput
        val encoded = buildString {
            for (byte in scalarBytes(afterID)) {
                val value = byte.toInt() and 255
                if (value.toChar() in queryCharacters) append(value.toChar())
                else { append('%'); append(hex[value ushr 4]); append(hex[value and 15]) }
            }
        }
        return connection.modelsURL + "?after_id=" + encoded
    }

    fun decode(body: ByteArray, kind: ProviderKind = ProviderKind.ANTHROPIC): AssistantModelPage {
        val page = LlmJsonParser(body, mode = AssistantJsonMode.ENVELOPE).parse()
        val models = page.member("data").array().map {
            val id = it.member("id").string()
            if (!validID(id)) throw AssistantError.InvalidOutput
            val name = it.optionalString("display_name")
                ?: if (kind == ProviderKind.OPENAI_COMPATIBLE) it.optionalString("name") else null
            ModelDescriptor(id, name)
        }
        val first = page.optionalString("first_id")
        val last = page.optionalString("last_id")
        if (listOfNotNull(first, last).any { !validID(it) }) throw AssistantError.InvalidOutput
        return AssistantModelPage(models, page.optional("has_more")?.boolean() ?: false, first, last)
    }

    private const val hex = "0123456789ABCDEF"
    // URLComponents queryItem encoding, with '+' escaped for form-style decoders.
    private const val queryCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$'()*,:;@/?"
}
