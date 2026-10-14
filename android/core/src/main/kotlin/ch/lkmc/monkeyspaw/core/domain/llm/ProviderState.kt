package ch.lkmc.monkeyspaw.core.domain.llm

/** Each downgrade consumes one probe; an action can make at most two. */
internal enum class OpenAIResponseFormat(val rawValue: String) {
    JSON_SCHEMA("json_schema"), JSON_OBJECT("json_object"), NONE("none");

    val lower: OpenAIResponseFormat?
        get() = when (this) {
            JSON_SCHEMA -> JSON_OBJECT
            JSON_OBJECT -> NONE
            NONE -> null
        }
}
