package ch.lkmc.monkeyspaw.core.domain.format

import java.text.Normalizer

enum class FieldKind(val rawValue: String) { TEXT("text"), MULTILINE("multiline"), CHOICE("choice") }

data class FieldOption(val label: String, val value: String)

/** Declarations retain file order; effective fields retain body first-use order. */
data class PromptField(
    val name: String,
    val kind: FieldKind = FieldKind.TEXT,
    val label: String = name,
    val description: String? = null,
    val defaultValue: String = "",
    val options: List<FieldOption> = emptyList(),
    val optional: Boolean = false,
    val remember: Boolean = true,
    val isImplicit: Boolean = false,
)

/** Swift String equality is canonically equivalent; rendering retains the original spelling. */
internal fun equalChoiceValues(first: String, second: String): Boolean =
    Normalizer.normalize(first, Normalizer.Form.NFC) == Normalizer.normalize(second, Normalizer.Form.NFC)
