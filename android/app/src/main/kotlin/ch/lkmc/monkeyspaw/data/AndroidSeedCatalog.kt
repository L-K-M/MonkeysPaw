package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.ports.StorePath
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*

internal class SeedPrompt(val relativePath: String, val bytes: ByteArray)

/** Reads only Gradle-generated assets. The shared seed/ tree remains the sole source. */
internal class AndroidSeedCatalog(private val readAsset: (String) -> ByteArray) {
    fun prompts(): List<SeedPrompt> = try {
        val catalog = Json.parseToJsonElement(readAsset("seeds/catalog.json").decodeToString(throwOnInvalidSequence = true)) as JsonObject
        require(catalog.keys == setOf("version", "paths") && catalog["version"] == JsonPrimitive(1))
        val paths = (catalog["paths"] as JsonArray).map { value ->
            val path = (value as JsonPrimitive).also { require(it.isString) }.content
            StorePath.validate(path)
            val parts = path.split('/')
            require(path != "README.md" && path.endsWith(".md") && parts.none { it.startsWith('_') } &&
                parts.dropLast(1).none { it.startsWith('.') })
            path
        }
        require(paths.isNotEmpty() && paths.zipWithNext().all { (a, b) ->
            comparePaths(a, b) < 0
        })
        paths.map { SeedPrompt(it, readAsset("seeds/$it")) }
    } catch (error: Exception) {
        if (error is CancellationException) throw error
        throw StoreError.IOFailure
    }

    private fun comparePaths(a: String, b: String): Int {
        val left = a.encodeToByteArray()
        val right = b.encodeToByteArray()
        for (index in 0 until minOf(left.size, right.size)) {
            val order = (left[index].toInt() and 255).compareTo(right[index].toInt() and 255)
            if (order != 0) return order
        }
        return left.size.compareTo(right.size)
    }
}
