package ch.lkmc.monkeyspaw.core.domain.llm

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.FieldKind
import ch.lkmc.monkeyspaw.core.domain.format.FrontMatter
import ch.lkmc.monkeyspaw.core.domain.format.PortableYaml
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptDocument
import ch.lkmc.monkeyspaw.core.domain.format.PromptField
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueSeverity
import ch.lkmc.monkeyspaw.core.domain.format.PromptWriteError
import ch.lkmc.monkeyspaw.core.domain.format.Template
import ch.lkmc.monkeyspaw.core.domain.format.YamlNode
import ch.lkmc.monkeyspaw.core.domain.format.YamlTag

/** Only Ready carries canonical bytes that may be offered for acceptance. */
sealed interface ArtifactMergeResult {
    data class Ready(val candidate: ArtifactMergeCandidate) : ArtifactMergeResult
    class Invalid internal constructor(issues: List<PromptIssue>) : ArtifactMergeResult {
        val issues: List<PromptIssue> = issues.immutableCopy()
    }
    data class Failed(val error: PromptWriteError) : ArtifactMergeResult
}

class ArtifactMergeCandidate internal constructor(val document: PromptDocument) {
    // The reparsed source is immutable; callers cannot mutate the bytes retained for preview.
    val canonicalBytes: ByteArray get() = document.source.toByteArray(Charsets.UTF_8)
}

/** Pure content conversion. Saving services own identity preflight, stale checks and publication. */
object ArtifactMerge {
    fun write(artifact: LlmArtifact, id: ULID): ArtifactMergeResult {
        val original = PromptDocument("", "", FrontMatter("", id = id), Template.parse(""),
            preservedHeader = YamlNode.Mapping(listOf(entry("id", string(id.rawValue)))))
        return merge(artifact, original)
    }

    fun improve(artifact: LlmArtifact, original: PromptDocument): ArtifactMergeResult = merge(artifact, original)

    private fun merge(artifact: LlmArtifact, original: PromptDocument): ArtifactMergeResult {
        val originalIssues = original.issues
        if (originalIssues.any { it.severity == PromptIssueSeverity.ERROR }) return ArtifactMergeResult.Invalid(originalIssues)

        val artifactIssues = artifact.issues
        if (artifactIssues.any { it.severity == PromptIssueSeverity.ERROR }) return ArtifactMergeResult.Invalid(artifactIssues)

        val replaced = setOf("title", "description", "tags", "fields")
        val pairs = original.preservedHeader?.entries.orEmpty().filter { PortableYaml.string(it.key) !in replaced } + listOf(
            entry("title", string(artifact.title)),
            entry("description", string(artifact.description)),
            entry("tags", YamlNode.Sequence(artifact.tags.map(::string))),
            entry("fields", YamlNode.Mapping(artifact.fields.map { entry(it.name, fieldNode(it)) })),
        )
        val old = original.frontMatter
        val fields = artifact.fields.map { PromptField(it.name, it.type, it.label, it.description,
            it.defaultValue, it.options, it.optional, it.remember) }
        val merged = PromptDocument("", artifact.body,
            FrontMatter(artifact.title, old.id, artifact.description, artifact.tags, old.favorite,
                old.isPrivate, fields, old.format), Template.parse(artifact.body), preservedHeader = YamlNode.Mapping(pairs))
        val issues = merged.issues
        if (issues.any { it.severity == PromptIssueSeverity.ERROR }) return ArtifactMergeResult.Invalid(issues)

        return try {
            val canonical = PromptCodec.write(merged)
            val document = PromptCodec.parse(canonical, artifact.title + ".md")
            val finalIssues = document.issues
            if (finalIssues.any { it.severity == PromptIssueSeverity.ERROR }) ArtifactMergeResult.Invalid(finalIssues)
            else ArtifactMergeResult.Ready(ArtifactMergeCandidate(document))
        } catch (error: PromptWriteError) {
            ArtifactMergeResult.Failed(error)
        }
    }

    private fun fieldNode(field: LlmArtifact.Field): YamlNode.Mapping {
        val pairs = mutableListOf(entry("type", string(field.type.rawValue)), entry("label", string(field.label)),
            entry("description", string(field.description)), entry("optional", boolean(field.optional)),
            entry("remember", boolean(field.remember)))
        if (field.defaultValue.isNotEmpty()) pairs.add(entry("default", string(field.defaultValue)))
        if (field.type == FieldKind.CHOICE) {
            pairs.add(entry("options", YamlNode.Sequence(field.options.map { option ->
                if (option.label.toByteArray(Charsets.UTF_8).contentEquals(option.value.toByteArray(Charsets.UTF_8))) string(option.value)
                else YamlNode.Mapping(listOf(entry("label", string(option.label)), entry("value", string(option.value))))
            })))
        }
        return YamlNode.Mapping(pairs)
    }

    private fun string(value: String) = YamlNode.Scalar(value, YamlTag.STR)
    private fun boolean(value: Boolean) = YamlNode.Scalar(value.toString(), YamlTag.BOOL)
    private fun entry(key: String, value: YamlNode) = YamlNode.Entry(string(key), value)
}
