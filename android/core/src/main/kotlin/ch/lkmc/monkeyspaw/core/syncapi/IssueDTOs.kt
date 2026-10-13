package ch.lkmc.monkeyspaw.core.syncapi

import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueLocation
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueSeverity
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathIssue
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathIssueCode

sealed interface IssueLocation {
    data class FrontMatter(val line: Long, val column: Long) : IssueLocation
    data class Body(val byteOffset: Long) : IssueLocation
    data class Path(val segment: Long?) : IssueLocation

    companion object {
        val codec: WireCodec<IssueLocation> = objectCodec("IssueLocation", { o ->
            when (o.string("kind")) {
                "front_matter" -> {
                    o.members(setOf("kind", "line", "column"))
                    FrontMatter(o.long("line", minimum = 1), o.long("column", minimum = 1))
                }
                "body" -> {
                    o.members(setOf("kind", "byte_offset"))
                    Body(o.long("byte_offset", minimum = 0))
                }
                "path" -> {
                    o.members(setOf("kind", "segment"))
                    Path(o.nullableLong("segment", minimum = 0))
                }
                else -> throw WireContractException()
            }
        }, { location ->
            when (location) {
                is FrontMatter -> wireObject("kind" to wireString("front_matter"), "line" to wireLong(location.line),
                    "column" to wireLong(location.column))
                is Body -> wireObject("kind" to wireString("body"), "byte_offset" to wireLong(location.byteOffset))
                is Path -> wireObject("kind" to wireString("path"), "segment" to (location.segment?.let(::wireLong) ?: WireValue.Null))
            }
        })
    }
}

data class Issue(val code: String, val severity: Severity, val location: IssueLocation? = null) {
    constructor(issue: PromptIssue) : this(issue.code.rawValue,
        if (issue.severity == PromptIssueSeverity.WARNING) Severity.WARNING else Severity.ERROR,
        when (val location = issue.location) {
            is PromptIssueLocation.FrontMatter -> IssueLocation.FrontMatter(location.line.toLong(), location.column.toLong())
            is PromptIssueLocation.Body -> IssueLocation.Body(location.byteOffset.toLong())
            null -> null
        })

    constructor(issue: SyncPathIssue) : this(issue.code.wireCode, Severity.ERROR,
        IssueLocation.Path(issue.segmentIndex?.toLong()))

    companion object {
        private val warningCodes = setOf(PromptIssueCode.INVALID_PLACEHOLDER, PromptIssueCode.UNUSED_FIELD,
            PromptIssueCode.GROUP_PRIVATE_REMOVED).map { it.rawValue }.toSet()
        private val errorCodes = PromptIssueCode.entries.map { it.rawValue }.toSet() - warningCodes +
            SyncPathIssueCode.entries.map { it.wireCode } + "prompt.id_mismatch"

        val codec = objectCodec("Issue", { o ->
            o.members(setOf("code", "severity"), setOf("location"))
            val code = o.string("code")
            val severity = o.dto("severity", Severity.codec)
            wireRequire(code in if (severity == Severity.WARNING) warningCodes else errorCodes)
            Issue(code, severity, o.optionalDto("location", IssueLocation.codec))
        }, { dto ->
            val fields = mutableMapOf("code" to wireString(dto.code), "severity" to Severity.codec.encodeValue(dto.severity))
            dto.location?.let { fields["location"] = IssueLocation.codec.encodeValue(it) }
            WireValue.ObjectValue(fields)
        })
    }
}
