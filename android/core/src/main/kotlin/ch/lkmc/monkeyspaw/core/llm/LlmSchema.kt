package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantError
import ch.lkmc.monkeyspaw.core.domain.llm.LlmReviewSeverity
import ch.lkmc.monkeyspaw.core.domain.llm.LlmRubricCriterion

/** B25: the same descriptor supplies request bytes and local type/key checks. */
internal sealed class LlmSchema {
    data object String : LlmSchema()
    data object Boolean : LlmSchema()
    class Enumeration(val values: List<kotlin.String>) : LlmSchema()
    class Array(val item: LlmSchema) : LlmSchema()
    class Object(val properties: List<Pair<kotlin.String, LlmSchema>>) : LlmSchema()

    val jsonSchema: ByteArray get() = json().toByteArray(Charsets.UTF_8)

    fun validate(value: LlmJsonValue) {
        val valid = when (this) {
            String -> value is LlmJsonValue.Text
            Boolean -> value is LlmJsonValue.Boolean
            is Enumeration -> value is LlmJsonValue.Text && value.value in values
            is Array -> value is LlmJsonValue.Array && value.items.all { item.validate(it); true }
            is Object -> value is LlmJsonValue.Object && value.members.keys == properties.map { it.first }.toSet() &&
                properties.all { (key, schema) -> schema.validate(value.members.getValue(key)); true }
        }
        if (!valid) throw AssistantError.InvalidOutput
    }

    // The descriptor vocabulary is ASCII. Sorted keys match Foundation without a second schema snapshot.
    private fun json(): kotlin.String = when (this) {
        String -> "{\"type\":\"string\"}"
        Boolean -> "{\"type\":\"boolean\"}"
        is Enumeration -> "{\"enum\":[${values.joinToString(",") { quoted(it) }}],\"type\":\"string\"}"
        is Array -> "{\"items\":${item.json()},\"type\":\"array\"}"
        is Object -> "{\"additionalProperties\":false,\"properties\":{${properties.sortedBy { it.first }.joinToString(",") {
            (key, schema) -> "${quoted(key)}:${schema.json()}"
        }}},\"required\":[${properties.joinToString(",") { quoted(it.first) }}],\"type\":\"object\"}"
    }

    private fun quoted(value: kotlin.String): kotlin.String {
        check(value.all { it in 'a'..'z' || it == '_' })
        return "\"$value\""
    }
}

internal object LlmSchemas {
    private val option = LlmSchema.Object(listOf("value" to LlmSchema.String, "label" to LlmSchema.String))
    private val field = LlmSchema.Object(listOf(
        "name" to LlmSchema.String, "type" to LlmSchema.Enumeration(FieldKind.entries.map { it.rawValue }),
        "label" to LlmSchema.String, "description" to LlmSchema.String, "default" to LlmSchema.String,
        "options" to LlmSchema.Array(option), "optional" to LlmSchema.Boolean, "remember" to LlmSchema.Boolean,
    ))
    val artifact = LlmSchema.Object(listOf(
        "title" to LlmSchema.String, "description" to LlmSchema.String, "tags" to LlmSchema.Array(LlmSchema.String),
        "fields" to LlmSchema.Array(field), "body" to LlmSchema.String, "notes" to LlmSchema.String,
    ))
    private val finding = LlmSchema.Object(listOf(
        "severity" to LlmSchema.Enumeration(LlmReviewSeverity.entries.map { it.rawValue }),
        "criterion" to LlmSchema.Enumeration(LlmRubricCriterion.entries.map { it.rawValue }),
        "quote" to LlmSchema.String, "problem" to LlmSchema.String, "suggestion" to LlmSchema.String,
    ))
    val review = LlmSchema.Object(listOf("summary" to LlmSchema.String, "findings" to LlmSchema.Array(finding)))
}
