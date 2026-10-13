package ch.lkmc.monkeyspaw.core.domain.format

import ch.lkmc.monkeyspaw.core.domain.Limits

/** Presentation of the validated ordered tree; no loader, identity assignment or filesystem access. */
internal object PromptWriter {
    private val knownKeys = listOf("id", "title", "description", "tags", "favorite", "private", "fields", "format")

    fun validate(document: PromptDocument) {
        if (document.isReadOnly) throw PromptWriteError.UnsupportedFormat(document.frontMatter.format)
        if (document.issues.any { it.severity == PromptIssueSeverity.ERROR }) throw PromptWriteError.InvalidPrompt
    }

    fun write(document: PromptDocument): String {
        validate(document)
        val header = document.preservedHeader ?: return document.body
        val ordered = knownKeys.flatMap { name -> header.entries.filter { PortableYaml.string(it.key) == name }.map { entry ->
            val value = when (name) {
                "id" -> document.frontMatter.id?.let { YamlNode.Scalar(it.rawValue, YamlTag.STR) } ?: entry.value
                "format" -> YamlNode.Scalar(document.frontMatter.format.decimalValue, YamlTag.INT)
                else -> entry.value
            }
            entry.copy(value = value)
        } } + header.entries.filter { PortableYaml.string(it.key) !in knownKeys }

        val output = Output(Limits.maxPromptBytes - 8 - document.body.toByteArray(Charsets.UTF_8).size)
        present(header.copy(entries = ordered), output)
        return "---\n" + output + "---\n" + document.body
    }

    // Engine emission differs in supplementary escapes, Unicode breaks and simple-key length.
    // Follow libyaml's block presentation directly, with a bounded, iterative traversal.
    private fun present(root: YamlNode.Mapping, output: Output) {
        val steps = ArrayDeque<Step>()
        steps.addLast(Node(root, 0))
        while (steps.isNotEmpty()) {
            when (val step = steps.removeLast()) {
                is Pair -> {
                    if (step.layout == Layout.BLOCK) output.indent(step.indent)
                    if (simpleKey(step.entry.key)) {
                        inline(step.entry.key, step.indent + 2, output)
                        output.append(":")
                        steps.addLast(Value(step.entry.value, step.indent))
                    } else {
                        output.append("? ")
                        steps.addLast(Value(step.entry.value, step.indent, KeyStyle.EXPLICIT))
                        steps.addLast(Node(step.entry.key, step.indent + 2, Layout.COMPACT))
                    }
                }
                is Value -> {
                    if (step.keyStyle == KeyStyle.EXPLICIT) {
                        output.indent(step.indent)
                        output.append(": ")
                        steps.addLast(Node(step.node, step.indent + 2, Layout.COMPACT))
                    } else if (nonemptyCollection(step.node)) {
                        output.append("\n")
                        // Mapping values use indentless sequences, as in the Swift goldens.
                        steps.addLast(Node(step.node, step.indent + if (step.node is YamlNode.Sequence) 0 else 2))
                    } else {
                        output.append(" ")
                        steps.addLast(Node(step.node, step.indent + 2, Layout.COMPACT))
                    }
                }
                is Item -> {
                    if (step.layout == Layout.BLOCK) output.indent(step.indent)
                    output.append("- ")
                    steps.addLast(Node(step.node, step.indent + 2, Layout.COMPACT))
                }
                is Node -> when (val node = step.node) {
                    is YamlNode.Mapping -> if (node.entries.isNotEmpty()) {
                        for (index in node.entries.indices.reversed()) {
                            steps.addLast(Pair(node.entries[index], step.indent, if (index == 0) step.layout else Layout.BLOCK))
                        }
                    } else line(node, step, output)
                    is YamlNode.Sequence -> if (node.values.isNotEmpty()) {
                        for (index in node.values.indices.reversed()) {
                            steps.addLast(Item(node.values[index], step.indent, if (index == 0) step.layout else Layout.BLOCK))
                        }
                    } else line(node, step, output)
                    is YamlNode.Scalar -> line(node, step, output)
                    is YamlNode.Rejected -> throw PromptWriteError.SerializationFailed
                }
            }
        }
    }

    private enum class Layout { BLOCK, COMPACT }
    private enum class KeyStyle { SIMPLE, EXPLICIT }
    private sealed interface Step
    private data class Node(val node: YamlNode, val indent: Int, val layout: Layout = Layout.BLOCK) : Step
    private data class Pair(val entry: YamlNode.Entry, val indent: Int, val layout: Layout) : Step
    private data class Item(val node: YamlNode, val indent: Int, val layout: Layout) : Step
    private data class Value(val node: YamlNode, val indent: Int, val keyStyle: KeyStyle = KeyStyle.SIMPLE) : Step

    private fun line(node: YamlNode, step: Node, output: Output) {
        if (step.layout == Layout.BLOCK) output.indent(step.indent)
        inline(node, step.indent, output)
        output.append("\n")
    }

    private fun nonemptyCollection(node: YamlNode): Boolean = when (node) {
        is YamlNode.Mapping -> node.entries.isNotEmpty()
        is YamlNode.Sequence -> node.values.isNotEmpty()
        else -> false
    }

    private fun simpleKey(node: YamlNode): Boolean = when (node) {
        is YamlNode.Scalar -> PortableYaml.canonicalScalar(node).value.let {
            // libyaml checks the scalar's raw UTF-8 length, before quoting, inclusively.
            it.none(::isBreak) && it.toByteArray(Charsets.UTF_8).size <= 128
        }
        is YamlNode.Mapping -> node.entries.isEmpty()
        is YamlNode.Sequence -> node.values.isEmpty()
        else -> false
    }

    private fun inline(node: YamlNode, indent: Int, output: Output): Unit = when (node) {
        is YamlNode.Scalar -> scalar(PortableYaml.canonicalScalar(node), indent, output)
        is YamlNode.Mapping -> if (node.entries.isEmpty()) output.append("{}") else throw PromptWriteError.SerializationFailed
        is YamlNode.Sequence -> if (node.values.isEmpty()) output.append("[]") else throw PromptWriteError.SerializationFailed
        else -> throw PromptWriteError.SerializationFailed
    }

    private fun scalar(node: YamlNode.Scalar, indent: Int, output: Output) {
        val value = node.value
        if (node.style == ScalarStyle.DOUBLE_QUOTED || value.isEmpty() ||
            value.codePoints().anyMatch { !printable(it) } || (1 until value.length).any { index ->
                value[index - 1] == ' ' && isBreak(value[index]) || isBreak(value[index - 1]) && value[index] == ' '
            }) {
            doubleQuoted(value, output)
            return
        }
        val indicator = value.startsWith("---") || value.startsWith("...") ||
            value.first() in "#,[]{}&*!|>'\"%@`" ||
            (value.first() in "?:-" && blank(value.getOrNull(1))) ||
            value.indices.any { index -> value[index] == ':' && blank(value.getOrNull(index + 1)) ||
                value[index] == '#' && blank(value.getOrNull(index - 1)) }
        if (!indicator && value.first() != ' ' && value.last() != ' ' && value.none(::isBreak)) {
            output.append(value)
            return
        }
        output.append('\'')
        for (index in value.indices) {
            val character = value[index]
            if (index > 0 && isBreak(value[index - 1]) && !isBreak(character)) output.indent(indent)
            if (character == '\'') output.append('\'')
            output.append(character)
        }
        if (isBreak(value.last())) output.indent(indent)
        output.append('\'')
    }

    private fun isBreak(character: Char): Boolean = character in "\n\r\u0085\u2028\u2029"
    private fun blank(character: Char?): Boolean = character == null || character == '\u0000' ||
        character == ' ' || character == '\t' || isBreak(character)

    // libyaml's printable range excludes the BOM, noncharacters and supplementary scalars.
    private fun printable(point: Int): Boolean = point == 10 || point in 0x20..0x7e ||
        point in 0xa0..0xd7ff || (point in 0xe000..0xfffd && point != 0xfeff)

    private fun doubleQuoted(value: String, output: Output) {
        output.append('"')
        val points = value.codePoints().iterator()
        while (points.hasNext()) {
            val point = points.nextInt()
            if (point in 0xd800..0xdfff) throw PromptWriteError.SerializationFailed
            val escape = when (point) {
                0 -> "0"; 7 -> "a"; 8 -> "b"; 9 -> "t"; 10 -> "n"; 11 -> "v"; 12 -> "f"; 13 -> "r"
                27 -> "e"; 34 -> "\""; 92 -> "\\"; 0x85 -> "N"; 0x2028 -> "L"; 0x2029 -> "P"
                else -> null
            }
            when {
                escape != null -> { output.append('\\'); output.append(escape) }
                !printable(point) -> {
                    output.append('\\')
                    output.append(if (point <= 0xff) 'x' else if (point <= 0xffff) 'u' else 'U')
                    val width = if (point <= 0xff) 2 else if (point <= 0xffff) 4 else 8
                    for (shift in (width - 1) * 4 downTo 0 step 4) output.append("0123456789ABCDEF"[(point ushr shift) and 15])
                }
                else -> output.append(point.toChar())
            }
        }
        output.append('"')
    }

    private class Output(private var remaining: Int) {
        private val text = StringBuilder()

        init { if (remaining < 0) throw PromptWriteError.SourceTooLarge }

        fun append(value: String) {
            if (value.length > remaining) throw PromptWriteError.SourceTooLarge
            val size = value.toByteArray(Charsets.UTF_8).size
            if (size > remaining) throw PromptWriteError.SourceTooLarge
            remaining -= size
            text.append(value)
        }

        fun append(value: Char) {
            val size = if (value.code <= 0x7f) 1 else if (value.code <= 0x7ff) 2 else 3
            if (size > remaining) throw PromptWriteError.SourceTooLarge
            remaining -= size
            text.append(value)
        }

        fun indent(count: Int) {
            if (count > remaining) throw PromptWriteError.SourceTooLarge
            append(" ".repeat(count))
        }

        override fun toString(): String = text.toString()
    }
}

sealed class PromptWriteError private constructor(message: String) : Exception(message) {
    object InvalidPrompt : PromptWriteError("Resolve prompt validation errors before writing.")
    data class UnsupportedFormat(val version: PromptFormatVersion) : PromptWriteError("This prompt format cannot be rewritten.")
    object SerializationFailed : PromptWriteError("The front matter could not be serialized.")
    object SourceTooLarge : PromptWriteError("Canonical content exceeds the prompt size limit.")

    final override fun toString(): String = message.orEmpty()
}
