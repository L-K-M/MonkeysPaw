package ch.lkmc.monkeyspaw.ui.fill

import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.PromptDocument
import ch.lkmc.monkeyspaw.core.domain.format.PromptField
import ch.lkmc.monkeyspaw.entry.CapturedTextRequest

/** Pure session overlay: user edits > one captured-text assignment > remembered/default prefill. */
internal class CapturedTextFieldChoice private constructor(
    val candidates: List<PromptField>,
    val selectedField: String?,
    private val capturedText: String,
    private val prefills: Map<String, String>,
    private val edits: Map<String, String>,
) {
    val values: Map<String, String> get() {
        val capture = selectedField?.let { mapOf(it to capturedText) } ?: emptyMap()
        return prefills + capture + edits
    }

    /** Null explicitly ignores capture; moving it restores unedited prefills without discarding edits. */
    fun select(fieldName: String?): CapturedTextFieldChoice {
        require(fieldName == null || candidates.any { it.name == fieldName }) { "Choose a text or multiline field." }
        return CapturedTextFieldChoice(candidates, fieldName, capturedText, prefills, edits)
    }

    fun edit(fieldName: String, value: String): CapturedTextFieldChoice {
        require(fieldName in prefills) { "Edit an effective field." }
        return CapturedTextFieldChoice(candidates, selectedField, capturedText, prefills, edits + (fieldName to value))
    }

    companion object {
        /** Start a new overlay for each prompt; the owner may retain old overlays to preserve that prompt's edits. */
        fun start(document: PromptDocument, capture: CapturedTextRequest,
                  prefills: Map<String, String> = emptyMap()): CapturedTextFieldChoice {
            val fields = document.effectiveFields
            val candidates = fields.filter { it.kind == FieldKind.TEXT || it.kind == FieldKind.MULTILINE }
            val selected = candidates.firstOrNull { it.kind == FieldKind.MULTILINE } ?: candidates.firstOrNull()
            val base = fields.associate { it.name to (prefills[it.name] ?: it.defaultValue) }
            return CapturedTextFieldChoice(candidates, selected?.name, capture.text, base, emptyMap())
        }
    }
}
