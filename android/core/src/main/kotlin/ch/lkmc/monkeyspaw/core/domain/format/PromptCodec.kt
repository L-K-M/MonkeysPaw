package ch.lkmc.monkeyspaw.core.domain.format

import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction.REPORT
import org.snakeyaml.engine.v2.exceptions.MarkedYamlEngineException
import org.snakeyaml.engine.v2.exceptions.YamlEngineException

/** Reading result; K4 adds template/validation assembly, K5 adds writing. */
class ParsedPrompt internal constructor(
    val source: String,
    val body: String,
    val frontMatter: FrontMatter,
    val decodingIssues: List<PromptIssue> = emptyList(),
    internal val preservedHeader: YamlNode.Mapping? = null,
    internal val declarationLocations: Map<String, PromptIssueLocation> = emptyMap(),
) {
    val isReadOnly: Boolean get() = frontMatter.format.isFuture
}

object PromptCodec {
    internal const val maxSourceBytes = 256 * 1024

    /** Checks the byte cap before decoding or invoking YAML. A leading BOM remains body data. */
    fun parseFile(bytes: ByteArray, filename: String): ParsedPrompt {
        if (bytes.size > maxSourceBytes) return failedBytes(filename, PromptIssueCode.SOURCE_TOO_LARGE)
        val source = try {
            Charsets.UTF_8.newDecoder().onMalformedInput(REPORT).onUnmappableCharacter(REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: CharacterCodingException) {
            return failedBytes(filename, PromptIssueCode.INVALID_UTF8)
        }
        return parse(source, filename)
    }

    /** Text input only; filename is a basename used exclusively for title fallback. */
    fun parse(source: String, filename: String): ParsedPrompt {
        val title = fallbackTitle(filename)
        val size = if (source.length > maxSourceBytes) source.length else try {
            Charsets.UTF_8.newEncoder().onMalformedInput(REPORT).onUnmappableCharacter(REPORT)
                .encode(CharBuffer.wrap(source)).remaining()
        } catch (_: CharacterCodingException) {
            return failedBytes(filename, PromptIssueCode.INVALID_UTF8)
        }
        if (size > maxSourceBytes) {
            return ParsedPrompt(source, source, FrontMatter(title, isPrivate = true),
                listOf(PromptIssue(PromptIssueCode.SOURCE_TOO_LARGE)))
        }
        val parts = split(source)
        val header = parts.header ?: return ParsedPrompt(source, parts.body,
            FrontMatter(title, isPrivate = parts.unclosed),
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
                    return ParsedPrompt(source, parts.body, FrontMatter(title, isPrivate = true), issues.toList())
                }
            }
            val decoder = FrontMatterDecoder(mapping, issues)
            val metadata = decoder.decode(title)
            return ParsedPrompt(source, parts.body, metadata, decoder.issues.toList(), mapping, decoder.locations.toMap())
        } catch (error: YamlFailure) {
            return invalidHeader(source, parts.body, title, error.issue)
        } catch (error: YamlEngineException) {
            // Do not retain or describe the exception: engine error messages include source.
            val mark = (error as? MarkedYamlEngineException)?.problemMark?.orElse(null)
            val location = mark?.let { yamlSource.location(it.index) }
            return invalidHeader(source, parts.body, title, PromptIssue(PromptIssueCode.INVALID_YAML, location))
        }
    }

    private fun invalidHeader(source: String, body: String, title: String, issue: PromptIssue) =
        ParsedPrompt(source, body, FrontMatter(title, isPrivate = true), listOf(issue))

    private fun failedBytes(filename: String, code: PromptIssueCode) =
        ParsedPrompt("", "", FrontMatter(fallbackTitle(filename), isPrivate = true), listOf(PromptIssue(code)))

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
