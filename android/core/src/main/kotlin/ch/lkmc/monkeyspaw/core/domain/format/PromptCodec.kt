package ch.lkmc.monkeyspaw.core.domain.format

import ch.lkmc.monkeyspaw.core.domain.Limits
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction.REPORT
import org.snakeyaml.engine.v2.exceptions.MarkedYamlEngineException
import org.snakeyaml.engine.v2.exceptions.YamlEngineException

object PromptCodec {
    /** Checks the byte cap before decoding or invoking YAML. A leading BOM remains body data. */
    fun parseFile(bytes: ByteArray, filename: String): PromptDocument {
        if (bytes.size > Limits.maxPromptBytes) return failedBytes(filename, PromptIssueCode.SOURCE_TOO_LARGE)
        val source = try {
            Charsets.UTF_8.newDecoder().onMalformedInput(REPORT).onUnmappableCharacter(REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: CharacterCodingException) {
            return failedBytes(filename, PromptIssueCode.INVALID_UTF8)
        }
        return parse(source, filename)
    }

    /** Text input only; filename is a basename used exclusively for title fallback. */
    fun parse(source: String, filename: String): PromptDocument {
        val title = fallbackTitle(filename)
        val size = if (source.length > Limits.maxPromptBytes) source.length else try {
            Charsets.UTF_8.newEncoder().onMalformedInput(REPORT).onUnmappableCharacter(REPORT)
                .encode(CharBuffer.wrap(source)).remaining()
        } catch (_: CharacterCodingException) {
            return failedBytes(filename, PromptIssueCode.INVALID_UTF8)
        }
        if (size > Limits.maxPromptBytes) {
            return PromptDocument(source, source, FrontMatter(title, isPrivate = true), Template.parse(""),
                listOf(PromptIssue(PromptIssueCode.SOURCE_TOO_LARGE)))
        }
        val parts = split(source)
        val template = Template.parse(parts.body)
        val header = parts.header ?: return PromptDocument(source, parts.body,
            FrontMatter(title, isPrivate = parts.unclosed), template,
            if (parts.unclosed) listOf(PromptIssue(PromptIssueCode.UNCLOSED_FRONT_MATTER,
                PromptIssueLocation.FrontMatter(1, 1))) else emptyList())

        val yamlSource = YamlSource(header)
        try {
            val root = PortableYaml.parse(yamlSource)
            val issues = mutableListOf<PromptIssue>()
            val normalized = root?.let { PortableYaml.normalize(it, issues) }
            val mapping = when {
                normalized is YamlNode.Mapping -> normalized
                normalized == null || (normalized is YamlNode.Scalar && normalized.tag == YamlTag.NULL && normalized.value.isEmpty()) -> YamlNode.Mapping(emptyList())
                else -> {
                    issues.add(PromptIssue(PromptIssueCode.FRONT_MATTER_NOT_MAPPING, normalized.mark))
                    return PromptDocument(source, parts.body, FrontMatter(title, isPrivate = true), template, issues.toList())
                }
            }
            val decoder = FrontMatterDecoder(mapping, issues)
            val metadata = decoder.decode(title)
            return PromptDocument(source, parts.body, metadata, template, decoder.issues.toList(), mapping, decoder.locations.toMap())
        } catch (error: YamlFailure) {
            return invalidHeader(source, parts.body, title, template, error.issue)
        } catch (error: YamlEngineException) {
            // Do not retain or describe the exception: engine error messages include source.
            val mark = (error as? MarkedYamlEngineException)?.problemMark?.orElse(null)
            val location = mark?.let { yamlSource.location(it.index) }
            return invalidHeader(source, parts.body, title, template, PromptIssue(PromptIssueCode.INVALID_YAML, location))
        }
    }

    private fun invalidHeader(source: String, body: String, title: String, template: Template, issue: PromptIssue) =
        PromptDocument(source, body, FrontMatter(title, isPrivate = true), template, listOf(issue))

    private fun failedBytes(filename: String, code: PromptIssueCode) =
        PromptDocument("", "", FrontMatter(fallbackTitle(filename), isPrivate = true), Template.parse(""), listOf(PromptIssue(code)))

    private fun fallbackTitle(filename: String): String {
        val dot = filename.lastIndexOf('.')
        return if (dot > 0) filename.substring(0, dot) else filename
    }

    private data class SourceParts(val header: String?, val body: String, val unclosed: Boolean = false)

    private fun split(source: String): SourceParts {
        // ASCII line delimiters have the same boundaries in UTF-16 and UTF-8. Only LF ends a line.
        fun line(start: Int): Pair<Int, Int> {
            val end = source.indexOf('\n', start).let { if (it < 0) source.length else it }
            val contentEnd = if (end < source.length && end > start && source[end - 1] == '\r') end - 1 else end
            return contentEnd to if (end < source.length) end + 1 else end
        }
        val first = line(0)
        if (source.substring(0, first.first) != "---") return SourceParts(null, source)
        val headerStart = first.second
        var start = headerStart
        while (start < source.length) {
            val current = line(start)
            if (source.substring(start, current.first) == "---") {
                return SourceParts(source.substring(headerStart, start), source.substring(current.second))
            }
            start = current.second
        }
        return SourceParts(null, source.substring(headerStart), unclosed = true)
    }
}
