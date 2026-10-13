package ch.lkmc.monkeyspaw.core.domain.format

/** Invocation snapshots; these pure values never read the clipboard or clock. */
data class PromptBuiltinValues(val clipboard: String? = null, val date: String? = null, val time: String? = null) {
    internal fun value(name: BuiltinName): String? = when (name) {
        BuiltinName.CLIPBOARD -> clipboard
        BuiltinName.DATE -> date
        BuiltinName.TIME -> time
    }
}

object PromptRenderer {
    fun render(document: PromptDocument, values: Map<String, String> = emptyMap(),
               builtins: PromptBuiltinValues = PromptBuiltinValues()): String {
        if (document.isReadOnly) throw PromptRenderError.UnsupportedFormat(document.frontMatter.format)
        if (!document.canRender) throw PromptRenderError.InvalidPrompt
        val resolved = mutableMapOf<String, String>()

        for (field in document.effectiveFields) {
            val value = values[field.name] ?: field.defaultValue
            if (value.isEmpty() && !field.optional) throw PromptRenderError.MissingRequiredValue(field.name)
            if (field.kind == FieldKind.CHOICE && value.isNotEmpty() &&
                field.options.none { equalChoiceValues(it.value, value) }) {
                throw PromptRenderError.InvalidChoiceValue(field.name)
            }
            resolved[field.name] = value
        }
        for (name in document.template.builtins) {
            resolved[name.rawValue] = builtins.value(name) ?: throw PromptRenderError.MissingBuiltin(name)
        }

        return buildString {
            for (token in document.template.tokens) {
                when (token) {
                    is TemplateToken.Literal -> append(token.text)
                    TemplateToken.EscapedOpener -> append("{{")
                    is TemplateToken.Placeholder -> append(resolved[token.name] ?: throw PromptRenderError.InvalidPrompt)
                }
            }
        }
    }
}

/** Identifiers are available to forms; descriptions never include names or supplied content. */
sealed class PromptRenderError private constructor(message: String) : Exception(message) {
    object InvalidPrompt : PromptRenderError("Resolve prompt validation errors before rendering.")
    data class UnsupportedFormat(val version: PromptFormatVersion) : PromptRenderError("This prompt format cannot be rendered.")
    data class MissingRequiredValue(val field: String) : PromptRenderError("Fill every required field before rendering.")
    data class InvalidChoiceValue(val field: String) : PromptRenderError("Select a listed choice value before rendering.")
    data class MissingBuiltin(val name: BuiltinName) : PromptRenderError("Supply every builtin snapshot used by this prompt.")

    final override fun toString(): String = message.orEmpty()
}
