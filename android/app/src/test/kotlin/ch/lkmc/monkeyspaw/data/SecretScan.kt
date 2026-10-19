package ch.lkmc.monkeyspaw.data

import kotlinx.serialization.json.JsonPrimitive
import java.net.URLEncoder
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.util.Base64

/** Byte-preserving, streaming scan: hidden files count, symlinks and unreadable roots cannot silently pass. */
internal class SecretScan(values: List<String>) {
    private val patterns: List<String> = values.flatMap { value ->
        val variants = mutableSetOf(value, Base64.getEncoder().encodeToString(value.encodeToByteArray()),
            Base64.getUrlEncoder().encodeToString(value.encodeToByteArray()))
        val percent = URLEncoder.encode(value, "UTF-8")
        variants += listOf(percent, percent.replace("+", "%20"),
            Regex("%[0-9A-F]{2}").replace(percent) { it.value.lowercase() })
        var escaped = setOf(value)
        repeat(2) {
            escaped = escaped.flatMap { text ->
                val json = JsonPrimitive(text).toString().removeSurrounding("\"")
                val ascii = json.flatMap { char -> if (char.code > 127) "\\u%04x".format(char.code).toList() else listOf(char) }.joinToString("")
                listOf(json, json.replace("/", "\\/"), ascii, ascii.replace("/", "\\/"))
            }.toSet()
            variants += escaped
        }
        variants
    }.map { String(it.encodeToByteArray(), Charsets.ISO_8859_1) } + values.flatMap { value ->
        listOf(Charsets.UTF_16LE, Charsets.UTF_16BE).map { String(value.toByteArray(it), Charsets.ISO_8859_1) }
    }

    fun contains(bytes: ByteArray): Boolean {
        val text = String(bytes, Charsets.ISO_8859_1)
        return patterns.any { it in text }
    }

    fun matches(root: Path): Set<Path> {
        check(Files.isDirectory(root, NOFOLLOW_LINKS)) { "A scan root is missing" }
        val found = mutableSetOf<Path>()
        Files.walk(root).use { paths -> paths.forEach { path ->
            check(!Files.isSymbolicLink(path)) { "A scan root contains a symlink" }
            if (Files.isRegularFile(path, NOFOLLOW_LINKS)) Files.newInputStream(path).use { stream ->
                var tail = byteArrayOf()
                val overlap = patterns.maxOf { it.length } - 1
                val buffer = ByteArray(65_536)
                while (true) {
                    val count = stream.read(buffer)
                    if (count < 0) break
                    val bytes = tail + buffer.copyOf(count)
                    if (contains(bytes)) { found.add(path); break }
                    tail = bytes.takeLast(overlap).toByteArray()
                }
            }
        } }
        return found
    }
}
