package ch.lkmc.monkeyspaw.core.domain.format

import ch.lkmc.monkeyspaw.core.domain.Limits

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

        return expand(document, resolved)
    }

    /** Pure editor preview: empty defaults and absent snapshots stay visible as field markers. */
    fun preview(document: PromptDocument, builtins: PromptBuiltinValues = PromptBuiltinValues()): String {
        if (document.isReadOnly) throw PromptRenderError.UnsupportedFormat(document.frontMatter.format)
        if (!document.canRender) throw PromptRenderError.InvalidPrompt
        val resolved = document.effectiveFields.associate {
            it.name to it.defaultValue.ifEmpty { "{${it.name}}" }
        }.toMutableMap()
        for (name in document.template.builtins) {
            resolved[name.rawValue] = builtins.value(name) ?: "{${name.rawValue}}"
        }
        return expand(document, resolved)
    }

    private fun expand(document: PromptDocument, resolved: Map<String, String>): String {
        val output = StringBuilder()
        var remaining = Limits.maxRenderedPromptBytes
        var trailingHighSurrogate = false
        for (token in document.template.tokens) {
            val value = when (token) {
                is TemplateToken.Literal -> token.text
                TemplateToken.EscapedOpener -> "{{"
                is TemplateToken.Placeholder -> resolved[token.name] ?: throw PromptRenderError.InvalidPrompt
            }
            // UTF-16 length is a lower bound for UTF-8 bytes. Reject huge snapshots
            // before encoding; only at most the remaining UTF-16 length is converted.
            if (value.length > remaining) throw PromptRenderError.OutputTooLarge
            var bytes = value.toByteArray(Charsets.UTF_8).size
            // Joining raw pieces can turn two one-byte replacement characters into
            // a four-byte pair. Empty pieces preserve the preceding boundary.
            if (trailingHighSurrogate && value.firstOrNull()?.isLowSurrogate() == true) bytes += 2
            if (bytes > remaining) throw PromptRenderError.OutputTooLarge
            output.append(value)
            remaining -= bytes
            if (value.isNotEmpty()) trailingHighSurrogate = value.last().isHighSurrogate()
        }
        return output.toString()
    }
}

/** Identifiers are available to forms; descriptions never include names or supplied content. */
sealed class PromptRenderError private constructor(message: String) : Exception(message) {
    object OutputTooLarge : PromptRenderError("Rendered prompt exceeds 2 MiB. Shorten field values or reduce repeated placeholders.")
    object InvalidPrompt : PromptRenderError("Resolve prompt validation errors before rendering.")
    data class UnsupportedFormat(val version: PromptFormatVersion) : PromptRenderError("This prompt format cannot be rendered.")
    data class MissingRequiredValue(val field: String) : PromptRenderError("Fill every required field before rendering.")
    data class InvalidChoiceValue(val field: String) : PromptRenderError("Select a listed choice value before rendering.")
    data class MissingBuiltin(val name: BuiltinName) : PromptRenderError("Supply every builtin snapshot used by this prompt.")

    final override fun toString(): String = message.orEmpty()
}
