package ch.lkmc.monkeyspaw.core.domain.`import`

import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.PromptDocument
import ch.lkmc.monkeyspaw.core.domain.format.PromptFormatVersion
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode

enum class ImportFormat(val rawValue: String, private val sourceExtension: String) {
    MARKDOWN("markdown", ".md"), DOTPROMPT("dotprompt", ".prompt"), PROMPTY("prompty", ".prompty");

    companion object {
        internal fun filename(filename: String): ImportFormat? = entries.firstOrNull { filename.endsWith(it.sourceExtension) }
    }
}

data class ImportFieldMapping(
    val sourceKey: String,
    val fieldName: String,
    val kind: FieldKind,
    /** The original property's path, never the default value. */
    val defaultSource: String?,
)

sealed interface ImportWarning {
    data class UnsupportedInput(val key: String) : ImportWarning
    data class InvalidName(val key: String) : ImportWarning
    data class ReservedName(val name: String) : ImportWarning
    data class FieldCollision(val name: String) : ImportWarning
    data class InvalidOptions(val key: String) : ImportWarning
    data class InvalidDefault(val key: String) : ImportWarning
    data class InvalidDescription(val key: String) : ImportWarning
    data class UnsupportedTemplate(val format: ImportFormat, val byteOffset: Int) : ImportWarning
    data class Validation(val issue: PromptIssueCode) : ImportWarning
}

enum class ImportLoss(val rawValue: String) {
    FRONT_MATTER_PRESENTATION("frontMatterPresentation"),
}

@ConsistentCopyVisibility
data class ImportMappingReport internal constructor(
    val mappings: List<ImportFieldMapping> = emptyList(),
    val preservedKeys: List<String> = emptyList(),
    val dropped: List<ImportLoss> = emptyList(),
    val warnings: List<ImportWarning> = emptyList(),
)

class ImportMappingResult internal constructor(val document: PromptDocument, val report: ImportMappingReport)

/** Mapper refusals only; publication and identity decisions belong to a library service. */
sealed class ImportSkipReason private constructor(message: String) : Exception(message) {
    object UnsupportedExtension : ImportSkipReason("Choose a supported import extension.")
    object FileTooLarge : ImportSkipReason("The import source exceeds the byte limit.")
    object InvalidUTF8 : ImportSkipReason("Encode the import source as UTF-8.")
    data class InvalidPrompt(val issues: List<PromptIssueCode>) : ImportSkipReason("Resolve prompt validation errors before importing.")
    data class UnsupportedFormat(val version: PromptFormatVersion) : ImportSkipReason("This prompt format cannot be imported.")
    object ConvertedTooLarge : ImportSkipReason("The converted prompt exceeds the byte limit.")
    object OperationFailed : ImportSkipReason("The import could not be converted.")

    final override fun toString(): String = message.orEmpty()
}
