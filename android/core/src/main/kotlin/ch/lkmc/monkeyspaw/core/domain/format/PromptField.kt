package ch.lkmc.monkeyspaw.core.domain.format

import com.ibm.icu.text.Normalizer2

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

/** Swift canonical equality needs the pinned ICU data; rendering retains the original spelling. */
internal fun equalChoiceValues(first: String, second: String): Boolean =
    Normalizer2.getNFCInstance().normalize(first) == Normalizer2.getNFCInstance().normalize(second)
