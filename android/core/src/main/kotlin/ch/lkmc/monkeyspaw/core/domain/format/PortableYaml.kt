package ch.lkmc.monkeyspaw.core.domain.format

import java.math.BigInteger
import java.text.Normalizer
import java.util.Locale
import org.snakeyaml.engine.v2.api.LoadSettings
import org.snakeyaml.engine.v2.api.lowlevel.Parse
import org.snakeyaml.engine.v2.events.AliasEvent
import org.snakeyaml.engine.v2.events.CollectionStartEvent
import org.snakeyaml.engine.v2.events.DocumentStartEvent
import org.snakeyaml.engine.v2.events.Event
import org.snakeyaml.engine.v2.events.MappingEndEvent
import org.snakeyaml.engine.v2.events.NodeEvent
import org.snakeyaml.engine.v2.events.ScalarEvent
import org.snakeyaml.engine.v2.events.SequenceEndEvent
import org.snakeyaml.engine.v2.events.SequenceStartEvent
import org.snakeyaml.engine.v2.common.CharConstants
import org.snakeyaml.engine.v2.common.ScalarStyle as EngineScalarStyle
import org.snakeyaml.engine.v2.parser.ParserImpl
import org.snakeyaml.engine.v2.scanner.Scanner
import org.snakeyaml.engine.v2.scanner.ScannerImpl
import org.snakeyaml.engine.v2.scanner.StreamReader
import org.snakeyaml.engine.v2.tokens.ScalarToken
import org.snakeyaml.engine.v2.tokens.Token

/** Syntax events only: never Load, Compose, a bean constructor, or a library scalar resolver. */
internal object PortableYaml {
    private val settings = LoadSettings.builder().setCodePointLimit(PromptCodec.maxSourceBytes)
        .setVersionFunction { it }.build()
    private val legacyBooleans = setOf("y", "yes", "n", "no", "on", "off")
    private val coreRules = listOf(
        YamlTag.NULL to Regex("(?:null|Null|NULL|~|)"),
        YamlTag.BOOL to Regex("(?:true|True|TRUE|false|False|FALSE)"),
        YamlTag.INT to Regex("(?:[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+)"),
        YamlTag.FLOAT to Regex("(?:[-+]?(?:\\.[0-9]+|[0-9]+(?:\\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\\.(?:inf|Inf|INF)|\\.(?:nan|NaN|NAN))"),
    )
    // The reviewed Yams resolver, rather than a broader approximation of YAML 1.1.
    private val legacyRules = listOf(
        YamlTag.BOOL to Regex("(?:yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF)"),
        YamlTag.INT to Regex("(?:[-+]?0b[0-1_]+|[-+]?0o?[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+)"),
        YamlTag.FLOAT to Regex("(?:[-+]?(?:[0-9][0-9_]*)(?:\\.[0-9_]*)?(?:[eE][-+]?[0-9]+)?|\\.[0-9_]+(?:[eE][-+][0-9]+)?|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\\.[0-9_]*|[-+]?\\.(?:inf|Inf|INF)|\\.(?:nan|NaN|NAN))"),
        YamlTag.MERGE to Regex("<<"),
        YamlTag.NULL to Regex("(?:~|null|Null|NULL|)"),
        YamlTag.TIMESTAMP to Regex("(?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:[Tt]|[ \\t]+)[0-9]{1,2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]*)?(?:[ \\t]*(?:Z|[-+][0-9]{1,2}(?::[0-9]{2})?))?)"),
        YamlTag.VALUE to Regex("="),
    )

    fun parse(source: YamlSource): YamlNode? {
        val frames = ArrayDeque<ParseFrame>()
        val anchors = mutableMapOf<String, PromptIssueLocation.FrontMatter?>()
        var root: YamlNode? = null
        var documents = 0
        fun mark(event: Event) = event.startMark.orElse(null)?.let { source.location(it.index) }

        fun attach(node: YamlNode) {
            if (frames.isEmpty()) root = node else frames.last().children.add(node)
        }

        val events = if (source.needsAdapter) Iterable { ParserImpl(settings,
            PortableScanner(source, ScannerImpl(settings, StreamReader(settings, source.syntax)))) }
            else Parse(settings).parseString(source.original)
        for (event in events) {
            val name = (event as? NodeEvent)?.anchor?.orElse(null)?.value
            if (name != null) {
                val invalid = name.indexOfFirst { it !in 'A'..'Z' && it !in 'a'..'z' &&
                    it !in '0'..'9' && it != '_' && it != '-' }
                if (invalid >= 0) {
                    val start = event.startMark.get().index
                    val raw = source.slice(start, event.endMark.get().index)
                    val prefix = raw.indexOf(if (event is AliasEvent) "*$name" else "&$name").coerceAtLeast(0)
                    throw YamlFailure(PromptIssue(PromptIssueCode.INVALID_YAML,
                        source.location(start + raw.codePointCount(0, (prefix + 1 + invalid).coerceAtMost(raw.length)))))
                }
            }
            when (event) {
                is DocumentStartEvent -> {
                    documents++
                    if (documents > 1) throw YamlFailure(PromptIssue(PromptIssueCode.INVALID_YAML, mark(event)))
                    // The engine accepts other 1.x versions; libyaml accepts exactly 1.1 and 1.2.
                    event.specVersion.orElse(null)?.let { version ->
                        if (version.major != 1 || version.minor !in 1..2) {
                            throw YamlFailure(PromptIssue(PromptIssueCode.INVALID_YAML, mark(event)))
                        }
                    }
                }
                is ScalarEvent -> {
                    if (event.anchor.isPresent) {
                        anchors[event.anchor.get().value] = mark(event)
                        attach(YamlNode.Rejected(mark(event)))
                    } else attach(YamlNode.Scalar(event.value, scalarTag(event), scalarStyle(event), mark(event)))
                }
                is AliasEvent -> {
                    val name = event.anchor.orElseThrow().value
                    // Yams registers collections after closing them, so recursive/undefined aliases fail syntax.
                    if (!anchors.containsKey(name)) throw YamlFailure(PromptIssue(PromptIssueCode.INVALID_YAML, mark(event)))
                    attach(YamlNode.Rejected(anchors[name]))
                }
                is CollectionStartEvent -> frames.addLast(ParseFrame(event))
                is SequenceEndEvent, is MappingEndEvent -> {
                    val frame = frames.removeLast()
                    val first = frame.event
                    val style = if (first.isFlow) CollectionStyle.FLOW else CollectionStyle.BLOCK
                    val pairs = if (first is SequenceStartEvent) emptyList() else
                        frame.children.chunked(2).map { YamlNode.Entry(it[0], it[1]) }
                    // Literal syntax duplicates still fail inside rejected anchored collections.
                    checkSyntaxDuplicates(pairs)
                    if (first.anchor.isPresent) {
                        anchors[first.anchor.get().value] = mark(first)
                        attach(YamlNode.Rejected(mark(first)))
                    } else if (first is SequenceStartEvent) {
                        attach(YamlNode.Sequence(frame.children.toList(), collectionTag(first, YamlTag.SEQ), style, mark(first)))
                    } else attach(YamlNode.Mapping(pairs, collectionTag(first, YamlTag.MAP), style, mark(first)))
                }
            }
        }
        return root
    }

    /** Preorder diagnostics, including key normalization before duplicates and values after them. */
    fun normalize(root: YamlNode, issues: MutableList<PromptIssue>): YamlNode {
        val steps = ArrayDeque<NormalizeStep>()
        val output = mutableListOf<YamlNode>()
        steps.addLast(Visit(root))
        while (steps.isNotEmpty()) {
            when (val step = steps.removeLast()) {
                is Visit -> when (val node = step.node) {
                    is YamlNode.Rejected -> {
                        issues.add(PromptIssue(PromptIssueCode.ANCHOR_OR_ALIAS, node.mark))
                        output.add(YamlNode.Scalar("null", YamlTag.NULL))
                    }
                    is YamlNode.Scalar -> output.add(normalizeScalar(node, step.key, issues))
                    is YamlNode.Sequence -> {
                        if (node.tag != YamlTag.SEQ) issues.add(PromptIssue(PromptIssueCode.NON_PORTABLE_TAG, node.mark))
                        steps.addLast(Finish(node, node.values.size))
                        node.values.asReversed().forEach { steps.addLast(Visit(it)) }
                    }
                    is YamlNode.Mapping -> {
                        if (node.tag != YamlTag.MAP) issues.add(PromptIssue(PromptIssueCode.NON_PORTABLE_TAG, node.mark))
                        val keys = mutableSetOf<String>()
                        steps.addLast(Finish(node, node.entries.size * 2))
                        for (pair in node.entries.asReversed()) {
                            steps.addLast(Visit(pair.value))
                            steps.addLast(CheckKey(keys, pair.key.mark))
                            steps.addLast(Visit(pair.key, key = true))
                        }
                    }
                }
                is CheckKey -> {
                    if (!step.keys.add(identity(output.last(), IdentityMode.TYPED)!!)) {
                        issues.add(PromptIssue(PromptIssueCode.DUPLICATE_KEY, step.mark))
                    }
                }
                is Finish -> {
                    val children = output.takeLast(step.count)
                    repeat(step.count) { output.removeAt(output.lastIndex) }
                    output.add(when (val node = step.node) {
                        is YamlNode.Sequence -> node.copy(values = children, tag = YamlTag.SEQ)
                        is YamlNode.Mapping -> node.copy(entries = children.chunked(2).map { YamlNode.Entry(it[0], it[1]) }, tag = YamlTag.MAP)
                        else -> error("Expected a collection")
                    })
                }
            }
        }
        return output.single()
    }

    fun string(node: YamlNode?): String? = (node as? YamlNode.Scalar)?.takeIf { it.tag == YamlTag.STR }?.value

    fun boolean(node: YamlNode?): Boolean? = (node as? YamlNode.Scalar)?.takeIf { it.tag == YamlTag.BOOL }?.let {
        when (it.value) { "true" -> true; "false" -> false; else -> null }
    }

    fun formatVersion(node: YamlNode): PromptFormatVersion? {
        if (node !is YamlNode.Scalar || node.tag != YamlTag.INT || !validExplicit(node.value, YamlTag.INT)) return null
        return PromptFormatVersion.fromDecimal(decimalInteger(node.value))
    }

    private fun normalizeScalar(node: YamlNode.Scalar, key: Boolean, issues: MutableList<PromptIssue>): YamlNode.Scalar {
        val implicit = node.tag == YamlTag.IMPLICIT
        val legacy = resolve(node.value, legacyRules)
        val core = resolve(node.value, coreRules)
        val tag = if (implicit) legacy else node.tag
        val issue = when {
            key && tag == YamlTag.MERGE -> PromptIssueCode.MERGE_KEY
            implicit && (legacy != core || node.value.lowercase(Locale.ROOT) in legacyBooleans ||
                (tag == YamlTag.BOOL && node.value != "true" && node.value != "false") || leadingZero(node.value)) -> PromptIssueCode.NON_PORTABLE_SCALAR
            implicit -> null
            tag !in setOf(YamlTag.STR, YamlTag.NULL, YamlTag.BOOL, YamlTag.INT, YamlTag.FLOAT) -> PromptIssueCode.NON_PORTABLE_TAG
            tag != YamlTag.STR && !validExplicit(node.value, tag) -> PromptIssueCode.NON_PORTABLE_SCALAR
            else -> null
        }
        if (issue != null) issues.add(PromptIssue(issue, node.mark))
        return node.copy(tag = tag)
    }

    private fun resolve(value: String, rules: List<Pair<String, Regex>>): String =
        rules.firstOrNull { it.second.matches(value) }?.first ?: YamlTag.STR

    private fun leadingZero(value: String): Boolean {
        val unsigned = if (value.startsWith('-') || value.startsWith('+')) value.substring(1) else value
        return unsigned.length > 1 && unsigned[0] == '0' && unsigned.all { it in '0'..'9' }
    }

    private fun validExplicit(value: String, tag: String): Boolean {
        val core = resolve(value, coreRules)
        return when (tag) {
            YamlTag.BOOL -> value == "true" || value == "false"
            YamlTag.INT -> core == YamlTag.INT && !leadingZero(value)
            YamlTag.NULL -> core == YamlTag.NULL
            YamlTag.FLOAT -> core == YamlTag.FLOAT || (core == YamlTag.INT &&
                !value.startsWith("0x") && !value.startsWith("0o") && !leadingZero(value))
            else -> false
        }
    }

    private fun decimalInteger(value: String): String {
        val negative = value.startsWith('-')
        val unsigned = if (value.startsWith('-') || value.startsWith('+')) value.substring(1) else value
        val radix = when { unsigned.startsWith("0x") -> 16; unsigned.startsWith("0o") -> 8; else -> null }
        if (radix != null) {
            val digits = unsigned.substring(2)
            if (digits.any { if (radix == 8) it !in '0'..'7' else it !in '0'..'9' && it !in 'a'..'f' && it !in 'A'..'F' }) return value
            val number = if (digits.isEmpty()) BigInteger.ZERO else BigInteger(digits, radix)
            return (if (negative) number.negate() else number).toString()
        }
        val digits = unsigned.trimStart('0')
        return if (digits.isEmpty()) "0" else (if (negative) "-" else "") + digits
    }

    private fun decimalFloat(value: String): String {
        val lower = value.lowercase(Locale.ROOT)
        if (lower == ".nan") return ".nan"
        if (lower.endsWith(".inf")) return if (lower.startsWith('-')) "-.inf" else ".inf"
        val negative = lower.startsWith('-')
        val unsigned = if (lower.startsWith('-') || lower.startsWith('+')) lower.substring(1) else lower
        val parts = unsigned.split('e')
        val mantissa = parts[0].split('.')
        val fractionCount = if (mantissa.size == 2) mantissa[1].length else 0
        val digits = mantissa.joinToString("").trimStart('0')
        if (digits.isEmpty()) return "0"
        val significant = digits.trimEnd('0')
        val adjustment = digits.length - significant.length - fractionCount
        val exponent = BigInteger(parts.getOrElse(1) { "0" }) + BigInteger.valueOf(adjustment.toLong())
        return (if (negative) "-" else "") + significant + "e" + exponent
    }

    // Iterative framing also handles deeply nested literal keys without a JVM stack limit.
    private fun identity(root: YamlNode, mode: IdentityMode): String? {
        val steps = ArrayDeque<IdentityStep>()
        val output = mutableListOf<String?>()
        steps.addLast(IdentityVisit(root))
        while (steps.isNotEmpty()) {
            when (val step = steps.removeLast()) {
                is IdentityVisit -> when (val node = step.node) {
                    is YamlNode.Rejected -> output.add(null)
                    is YamlNode.Scalar -> {
                        var value = node.value
                        if (mode == IdentityMode.SYNTAX) value = Normalizer.normalize(value, Normalizer.Form.NFC)
                        else when (node.tag) {
                            YamlTag.INT -> value = decimalInteger(value)
                            YamlTag.FLOAT -> if (validExplicit(value, YamlTag.FLOAT)) value = decimalFloat(value)
                            YamlTag.NULL -> value = "null"
                        }
                        output.add(framed(node.tag) + framed(value))
                    }
                    is YamlNode.Sequence -> {
                        steps.addLast(IdentityFinish(node, node.values.size))
                        node.values.asReversed().forEach { steps.addLast(IdentityVisit(it)) }
                    }
                    is YamlNode.Mapping -> {
                        steps.addLast(IdentityFinish(node, node.entries.size * 2))
                        node.entries.asReversed().forEach { steps.addLast(IdentityVisit(it.value)); steps.addLast(IdentityVisit(it.key)) }
                    }
                }
                is IdentityFinish -> {
                    val children = output.takeLast(step.count)
                    repeat(step.count) { output.removeAt(output.lastIndex) }
                    val value = if (children.any { it == null }) null else when (val node = step.node) {
                        is YamlNode.Sequence -> "sequence" + (if (mode == IdentityMode.SYNTAX) framed(node.tag) else "") + children.joinToString("") { framed(it!!) }
                        is YamlNode.Mapping -> {
                            val pairs = children.chunked(2).map { framed(it[0]!!) + framed(it[1]!!) }
                            val ordered = if (mode == IdentityMode.TYPED) pairs.sortedWith(::compareUtf8) else pairs
                            "mapping" + (if (mode == IdentityMode.SYNTAX) framed(node.tag) else "") + ordered.joinToString("") { framed(it) }
                        }
                        else -> error("Expected a collection")
                    }
                    output.add(value)
                }
            }
        }
        return output.single()
    }

    private fun checkSyntaxDuplicates(entries: List<YamlNode.Entry>) {
        val first = mutableMapOf<String, YamlNode>()
        val duplicates = mutableListOf<YamlNode>()
        for (entry in entries) {
            val identity = identity(entry.key, IdentityMode.SYNTAX) ?: continue
            val previous = first.putIfAbsent(identity, entry.key)
            if (previous != null) duplicates.add(previous)
        }
        if (duplicates.isNotEmpty()) {
            val firstKey = duplicates.minWithOrNull { a, b -> compareSyntax(a, b) }!!
            throw YamlFailure(PromptIssue(PromptIssueCode.DUPLICATE_KEY, firstKey.mark))
        }
    }

    private fun compareSyntax(left: YamlNode, right: YamlNode): Int {
        val steps = ArrayDeque<SyntaxComparison>()
        steps.addLast(CompareNodes(left, right))
        while (steps.isNotEmpty()) {
            val comparison = when (val step = steps.removeLast()) {
                is CompareSizes -> step.left.compareTo(step.right)
                is CompareNodes -> {
                    val a = step.left
                    val b = step.right
                    when {
                        a is YamlNode.Scalar && b is YamlNode.Scalar -> compareUtf8(
                            Normalizer.normalize(a.value, Normalizer.Form.NFC), Normalizer.normalize(b.value, Normalizer.Form.NFC))
                        a is YamlNode.Sequence && b is YamlNode.Sequence -> {
                            steps.addLast(CompareSizes(a.values.size, b.values.size))
                            a.values.zip(b.values).asReversed().forEach { steps.addLast(CompareNodes(it.first, it.second)) }
                            0
                        }
                        a is YamlNode.Mapping && b is YamlNode.Mapping -> {
                            steps.addLast(CompareSizes(a.entries.size, b.entries.size))
                            a.entries.zip(b.entries).asReversed().forEach { steps.addLast(CompareNodes(it.first.key, it.second.key)) }
                            0
                        }
                        else -> 0
                    }
                }
            }
            if (comparison != 0) return comparison
        }
        return 0
    }

    private fun framed(value: String): String = "${value.toByteArray(Charsets.UTF_8).size}:$value"

    private fun compareUtf8(left: String, right: String): Int {
        val a = left.toByteArray(Charsets.UTF_8)
        val b = right.toByteArray(Charsets.UTF_8)
        for (index in 0 until minOf(a.size, b.size)) {
            val order = (a[index].toInt() and 255).compareTo(b[index].toInt() and 255)
            if (order != 0) return order
        }
        return a.size.compareTo(b.size)
    }

    private fun scalarTag(event: ScalarEvent): String = when (val tag = event.tag.orElse(null)) {
        null -> if (event.isPlain) YamlTag.IMPLICIT else YamlTag.STR
        "!" -> YamlTag.STR
        else -> tag
    }

    private fun scalarStyle(event: ScalarEvent): ScalarStyle = when {
        event.isSQuoted -> ScalarStyle.SINGLE_QUOTED
        event.isDQuoted -> ScalarStyle.DOUBLE_QUOTED
        event.isLiteral -> ScalarStyle.LITERAL
        event.isFolded -> ScalarStyle.FOLDED
        else -> ScalarStyle.PLAIN
    }

    private fun collectionTag(event: CollectionStartEvent, default: String): String =
        event.tag.orElse(null)?.takeUnless { it == "!" } ?: default

    private class ParseFrame(val event: CollectionStartEvent, val children: MutableList<YamlNode> = mutableListOf())
    private sealed interface NormalizeStep
    private data class Visit(val node: YamlNode, val key: Boolean = false) : NormalizeStep
    private data class Finish(val node: YamlNode, val count: Int) : NormalizeStep
    private data class CheckKey(val keys: MutableSet<String>, val mark: PromptIssueLocation.FrontMatter?) : NormalizeStep
    private enum class IdentityMode { SYNTAX, TYPED }
    private sealed interface IdentityStep
    private data class IdentityVisit(val node: YamlNode) : IdentityStep
    private data class IdentityFinish(val node: YamlNode, val count: Int) : IdentityStep
    private sealed interface SyntaxComparison
    private data class CompareNodes(val left: YamlNode, val right: YamlNode) : SyntaxComparison
    private data class CompareSizes(val left: Int, val right: Int) : SyntaxComparison
}

/** Carries only a safe diagnostic, never a parser exception or its embedded input. */
internal class YamlFailure(val issue: PromptIssue) : RuntimeException()

/** A syntax view only; all source spans and diagnostic coordinates refer to original text. */
internal class YamlSource(val original: String) {
    val needsAdapter = original.any { it == '\u0085' || it == '\u2028' || it == '\u2029' } ||
        listOf("\\L", "\\P", "\\u", "\\U").any { original.contains(it) }
    val syntax = original.replace('\u0085', '\n').replace('\u2028', '\n').replace('\u2029', '\n')
        .replace("\\L", "\\N").replace("\\P", "\\N")
    private val points = original.codePoints().toArray()
    private val offsets = IntArray(points.size + 1)
    private val lines = IntArray(points.size + 1)
    private val columns = IntArray(points.size + 1)

    init {
        var line = 2
        var column = 1
        for (index in 0..points.size) {
            lines[index] = line
            columns[index] = column
            if (index == points.size) break
            offsets[index + 1] = offsets[index] + Character.charCount(points[index])
            when (points[index]) {
                13, 133, 0x2028, 0x2029 -> { line++; column = 1 }
                10 -> if (index == 0 || points[index - 1] != 13) { line++; column = 1 }
                0xfeff -> if (index != 0) column++
                else -> column++
            }
        }
    }

    fun location(index: Int): PromptIssueLocation.FrontMatter = index.coerceIn(0, points.size).let {
        PromptIssueLocation.FrontMatter(lines[it], columns[it])
    }

    fun slice(start: Int, end: Int): String = original.substring(offsets[start], offsets[end])
}

/** Engine 3.2 scans YAML 1.2 breaks; libyaml also scans NEL/LS/PS and retains LS/PS in values. */
private class PortableScanner(private val source: YamlSource, private val scanner: Scanner) : Scanner {
    private val indents = ArrayDeque<Int>()
    private var cached: Token? = null
    private var adapted: Token? = null

    override fun checkToken(vararg choices: Token.ID): Boolean = scanner.checkToken(*choices)
    override fun hasNext(): Boolean = scanner.hasNext()
    override fun remove() { throw UnsupportedOperationException() }
    override fun resetDocumentIndex() = scanner.resetDocumentIndex()
    override fun peekToken(): Token = adapt(scanner.peekToken())

    override fun next(): Token {
        val token = adapt(scanner.next())
        when (token.tokenId) {
            Token.ID.BlockMappingStart, Token.ID.BlockSequenceStart -> indents.addLast(token.startMark.get().column)
            Token.ID.BlockEnd -> if (indents.isNotEmpty()) indents.removeLast()
            else -> Unit
        }
        return token
    }

    private fun adapt(token: Token): Token {
        if (token === cached) return adapted!!
        cached = token
        adapted = token
        if (token !is ScalarToken) return token
        val start = token.startMark.get().index
        val raw = source.slice(start, token.endMark.get().index)
        val needsValue = raw.any { it == '\u0085' || it == '\u2028' || it == '\u2029' } ||
            raw.contains("\\L") || raw.contains("\\P") ||
            (token.style == EngineScalarStyle.DOUBLE_QUOTED && (raw.contains("\\u") || raw.contains("\\U")))
        if (!needsValue) return token
        val decoder = PortableScalar(raw) { index ->
            throw YamlFailure(PromptIssue(PromptIssueCode.INVALID_YAML,
                source.location(start + raw.codePointCount(0, index))))
        }
        val value = when (token.style) {
            EngineScalarStyle.PLAIN -> decoder.flow()
            EngineScalarStyle.SINGLE_QUOTED -> decoder.flow('\'')
            EngineScalarStyle.DOUBLE_QUOTED, EngineScalarStyle.JSON_SCALAR_STYLE -> decoder.flow('"')
            EngineScalarStyle.LITERAL, EngineScalarStyle.FOLDED -> decoder.block(token.style, indents.lastOrNull() ?: -1)
        }
        return ScalarToken(value, token.isPlain, token.style, token.startMark, token.endMark).also { adapted = it }
    }
}

/** Decode only adapted scalar spans, after the engine has validated their YAML syntax. */
private class PortableScalar(private val raw: String, private val invalid: (Int) -> Nothing) {
    private var index = 0
    private val output = StringBuilder()
    private fun isBreak(char: Char) = char in "\r\n\u0085\u2028\u2029"
    private fun peek(): Char = raw.getOrElse(index) { '\u0000' }
    private fun breakValue(): String {
        val char = raw[index++]
        if (char == '\r' && peek() == '\n') index++
        return if (char == '\u2028' || char == '\u2029') char.toString() else "\n"
    }

    fun flow(quote: Char? = null): String {
        val end = if (quote == null) raw.length else raw.length - 1
        if (quote != null) index++
        while (index < end) {
            val char = peek()
            if (quote == '\'' && char == '\'' && raw.getOrNull(index + 1) == '\'') {
                output.append('\''); index += 2
            } else if (quote == '"' && char == '\\') {
                index++
                if (isBreak(peek())) {
                    breakValue()
                    output.append(followingBreaks(end))
                } else {
                    val escapeIndex = index
                    val escape = raw[index++]
                    val literal = when (escape) { 'L' -> "\u2028"; 'P' -> "\u2029"; else -> CharConstants.ESCAPE_REPLACEMENTS[escape] }
                    if (literal != null) output.append(literal) else {
                        val count = when (escape) { 'x' -> 2; 'u' -> 4; 'U' -> 8; else -> invalid(escapeIndex) }
                        val value = raw.substring(index, index + count).toLong(16)
                        if (value > 0x10ffff || value in 0xd800..0xdfff) invalid(escapeIndex)
                        output.appendCodePoint(value.toInt())
                        index += count
                    }
                }
            } else if (char == ' ' || char == '\t' || isBreak(char)) {
                val start = index
                while (index < end && peek() in " \t") index++
                if (index < end && isBreak(peek())) {
                    val leading = breakValue()
                    val following = followingBreaks(end)
                    if (leading != "\n") output.append(leading)
                    else if (following.isEmpty()) output.append(' ')
                    output.append(following)
                } else output.append(raw, start, index)
            } else { output.append(char); index++ }
        }
        return output.toString()
    }

    private fun followingBreaks(end: Int): String = buildString {
        while (index < end) {
            while (index < end && peek() in " \t") index++
            if (index >= end || !isBreak(peek())) break
            append(breakValue())
        }
    }

    fun block(style: EngineScalarStyle, parentIndent: Int): String {
        val headerEnd = raw.indexOfFirst(::isBreak).let { if (it < 0) raw.length else it }
        val indicators = raw.substring(1, headerEnd).takeWhile { it !in " \t#" }
        val chomp = when { '-' in indicators -> -1; '+' in indicators -> 1; else -> 0 }
        val increment = indicators.firstOrNull { it in '1'..'9' }?.digitToInt()
        index = headerEnd
        if (index < raw.length) breakValue()
        val minimum = maxOf(1, parentIndent + 1)
        var maxIndent = 0

        fun breaks(indent: Int?): Pair<String, Int> {
            var column = 0
            val value = buildString {
                while (true) {
                    while (peek() == ' ' && (indent == null || column < indent)) { index++; column++ }
                    maxIndent = maxOf(maxIndent, column)
                    if (index >= raw.length || !isBreak(peek())) break
                    append(breakValue())
                    column = 0
                }
            }
            return value to column
        }

        val indent = increment?.let { minimum + it - 1 }
        var pending = breaks(indent)
        val effectiveIndent = indent ?: maxOf(minimum, maxIndent)
        var leading = ""
        while (pending.second == effectiveIndent && index < raw.length) {
            output.append(pending.first)
            val leadingNonSpace = peek() !in " \t"
            while (index < raw.length && !isBreak(peek())) output.append(raw[index++])
            leading = if (index < raw.length) breakValue() else ""
            pending = breaks(effectiveIndent)
            if (pending.second != effectiveIndent || index >= raw.length) break
            if (style == EngineScalarStyle.FOLDED && leading == "\n" && leadingNonSpace && peek() !in " \t") {
                if (pending.first.isEmpty()) output.append(' ')
            } else output.append(leading)
        }
        if (chomp != -1) output.append(leading)
        if (chomp == 1) output.append(pending.first)
        return output.toString()
    }
}
