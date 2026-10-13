package ch.lkmc.monkeyspaw.core.domain.canonical

import ch.lkmc.monkeyspaw.core.domain.format.PortableYaml
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptDocument
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueSeverity
import ch.lkmc.monkeyspaw.core.domain.format.PromptWriter
import java.security.MessageDigest

/** Pure storage bytes and ingest diagnostics; callers own personal state and file writes. */
class CanonicalForm private constructor(bytes: ByteArray, val favorite: Boolean? = null, val warnings: List<PromptIssue>) {
    enum class Scope { USER, GROUP }

    private val storedBytes = bytes.copyOf()
    val bytes: ByteArray get() = storedBytes.copyOf()
    /** Lowercase SHA-256 over every stored byte, including id. */
    val canonicalHash: String = MessageDigest.getInstance("SHA-256").digest(storedBytes)
        .joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }

    companion object {
        fun group(bytes: ByteArray, filename: String): CanonicalForm {
            val document = validated(bytes, filename)
            val entries = document.preservedHeader?.entries.orEmpty()
            val hasFavorite = entries.any { PortableYaml.string(it.key) == "favorite" }
            val warnings = document.issues.filter { it.severity == PromptIssueSeverity.WARNING }.toMutableList()
            entries.firstOrNull { PortableYaml.string(it.key) == "private" }?.let {
                warnings.add(PromptIssue(PromptIssueCode.GROUP_PRIVATE_REMOVED, it.value.mark))
            }
            val text = PromptCodec.write(groupDocument(document))
            return CanonicalForm(text.toByteArray(Charsets.UTF_8),
                if (hasFavorite) document.frontMatter.favorite else null, warnings.toList())
        }

        /** Validation does not rewrite private storage, including comments, BOMs and line endings. */
        fun user(bytes: ByteArray, filename: String): CanonicalForm {
            val document = validated(bytes, filename)
            return CanonicalForm(bytes, warnings = document.issues.filter { it.severity == PromptIssueSeverity.WARNING })
        }

        fun equivalentForAdoption(local: ByteArray, server: ByteArray, scope: Scope, filename: String): Boolean {
            val left = adoptionContent(local, scope, filename)
            val right = adoptionContent(server, scope, filename)
            // Removing an empty header must not turn body text into another file's metadata.
            return left.body == right.body && left.text == right.text
        }

        private fun validated(bytes: ByteArray, filename: String): PromptDocument =
            PromptCodec.parseFile(bytes, filename).also(PromptWriter::validate)

        private fun groupDocument(document: PromptDocument): PromptDocument = PromptDocument(
            document.source, document.body, document.frontMatter.copy(favorite = false, isPrivate = false),
            document.template, document.decodingIssues,
            document.preservedHeader?.let { header -> header.copy(entries = header.entries.filter {
                PortableYaml.string(it.key) !in setOf("favorite", "private")
            }) }, document.declarationLocations,
        )

        private data class AdoptionContent(val text: String, val body: String)

        private fun adoptionContent(bytes: ByteArray, scope: Scope, filename: String): AdoptionContent {
            val original = validated(bytes, filename)
            val document = if (scope == Scope.GROUP) groupDocument(original) else original
            val entries = document.preservedHeader?.entries.orEmpty().filter { PortableYaml.string(it.key) != "id" }
            val header = document.preservedHeader?.copy(entries = entries)?.takeIf { entries.isNotEmpty() }
            val neutral = PromptDocument(document.source, document.body, document.frontMatter.copy(id = null),
                document.template, document.decodingIssues, header, document.declarationLocations)
            return AdoptionContent(PromptCodec.write(neutral), document.body)
        }
    }
}
