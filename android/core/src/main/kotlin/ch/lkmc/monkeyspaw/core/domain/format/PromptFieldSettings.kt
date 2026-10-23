package ch.lkmc.monkeyspaw.core.domain.format

/** The original index carries unknown option metadata through edits and removal. */
data class PromptFieldOptionSettings(val label: String, val value: String, internal val originalIndex: Int? = null)

enum class PromptFieldSettingsIssue { MISSING_OPTIONS, INVALID_DEFAULT }

/** A staged visual edit. A null default differs from an explicitly empty default. */
data class PromptFieldSettings(
    val name: String,
    val isImplicit: Boolean,
    val kind: FieldKind,
    val label: String,
    val description: String?,
    val defaultValue: String?,
    val options: List<PromptFieldOptionSettings>,
    val optional: Boolean,
    val remember: Boolean,
) {
    val validationIssue: PromptFieldSettingsIssue? get() {
        if (kind != FieldKind.CHOICE) return null
        if (options.isEmpty()) return PromptFieldSettingsIssue.MISSING_OPTIONS
        if (defaultValue != null && options.none { equalChoiceValues(it.value, defaultValue) }) return PromptFieldSettingsIssue.INVALID_DEFAULT
        return null
    }

    companion object {
        internal fun of(field: PromptField, hasDefault: Boolean) = PromptFieldSettings(
            field.name, field.isImplicit, field.kind, field.label, field.description,
            if (hasDefault) field.defaultValue else null,
            field.options.mapIndexed { index, option -> PromptFieldOptionSettings(option.label, option.value, index) },
            field.optional, field.remember)
    }
}
