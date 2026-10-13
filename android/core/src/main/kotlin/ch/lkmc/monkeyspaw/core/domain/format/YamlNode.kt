package ch.lkmc.monkeyspaw.core.domain.format

/** Ordered syntax, kept internal so callers cannot bypass validation by editing the tree. */
internal sealed interface YamlNode {
    val tag: String
    val mark: PromptIssueLocation.FrontMatter?

    data class Scalar(
        val value: String,
        override val tag: String,
        val style: ScalarStyle = ScalarStyle.PLAIN,
        override val mark: PromptIssueLocation.FrontMatter? = null,
    ) : YamlNode

    data class Sequence(
        val values: List<YamlNode>,
        override val tag: String = YamlTag.SEQ,
        val style: CollectionStyle = CollectionStyle.BLOCK,
        override val mark: PromptIssueLocation.FrontMatter? = null,
    ) : YamlNode

    data class Mapping(
        val entries: List<Entry>,
        override val tag: String = YamlTag.MAP,
        val style: CollectionStyle = CollectionStyle.BLOCK,
        override val mark: PromptIssueLocation.FrontMatter? = null,
    ) : YamlNode

    data class Entry(val key: YamlNode, val value: YamlNode)

    // No anchor target or children survive here, and aliases are never expanded.
    data class Rejected(override val mark: PromptIssueLocation.FrontMatter?) : YamlNode {
        override val tag: String = YamlTag.NULL
    }
}

internal enum class ScalarStyle { PLAIN, SINGLE_QUOTED, DOUBLE_QUOTED, LITERAL, FOLDED }
internal enum class CollectionStyle { BLOCK, FLOW }

internal object YamlTag {
    const val STR = "tag:yaml.org,2002:str"
    const val NULL = "tag:yaml.org,2002:null"
    const val BOOL = "tag:yaml.org,2002:bool"
    const val INT = "tag:yaml.org,2002:int"
    const val FLOAT = "tag:yaml.org,2002:float"
    const val SEQ = "tag:yaml.org,2002:seq"
    const val MAP = "tag:yaml.org,2002:map"
    const val MERGE = "tag:yaml.org,2002:merge"
    const val VALUE = "tag:yaml.org,2002:value"
    const val TIMESTAMP = "tag:yaml.org,2002:timestamp"
    const val IMPLICIT = "tag:monkeyspaw,2026:implicit-scalar"
}
