package ch.lkmc.monkeyspaw.core.conformance

import ch.lkmc.monkeyspaw.core.syncapi.WireContractException
import ch.lkmc.monkeyspaw.core.syncapi.WireJson
import ch.lkmc.monkeyspaw.core.syncapi.WireValue
import ch.lkmc.monkeyspaw.core.syncapi.longValue
import java.math.BigDecimal
import java.net.URI
import java.nio.file.Files
import java.nio.file.Path

internal class UnsupportedSchema : IllegalArgumentException("Unsupported SyncAPI test schema")

/** Test-only emitted 2020-12 subset, with an independent implementation of every x- check. */
internal class SchemaValidator(
    private val schemasByID: Map<String, WireValue> = emptyMap(),
    private val idsByName: Map<String, String> = emptyMap(),
) {
    enum class Mode { SCHEMA, CONTRACT }

    val names: Set<String> get() = idsByName.keys

    fun schema(name: String): WireValue = schemasByID[idsByName[name]] ?: throw UnsupportedSchema()

    fun validate(bytes: ByteArray, name: String, mode: Mode = Mode.CONTRACT): Boolean {
        val value = try { WireJson.parse(bytes) } catch (_: WireContractException) { return false }
        return validate(value, schema(name), mode)
    }

    fun validate(value: WireValue, schema: WireValue, mode: Mode = Mode.CONTRACT, baseID: URI? = null): Boolean {
        val objectValue = schema.objectValue()
        auditKeywords(objectValue)
        val base = objectValue["\$id"]?.text()?.let(::URI) ?: baseID
        val required = objectValue["required"]?.stringList() ?: emptyList()

        objectValue["\$ref"]?.let { reference ->
            val targetID = resolve(base, reference.text())
            val target = schemasByID[targetID] ?: throw UnsupportedSchema()
            if (!validate(value, target, mode, URI(targetID))) return false
        }
        objectValue["const"]?.let { if (!equivalent(it, value)) return false }
        objectValue["enum"]?.let { if (it.arrayValue().none { item -> equivalent(item, value) }) return false }
        objectValue["oneOf"]?.let {
            if (it.arrayValue().count { branch -> validate(value, branch, mode, base) } != 1) return false
        }
        objectValue["allOf"]?.let {
            if (!it.arrayValue().all { constraint -> validate(value, constraint, mode, base) }) return false
        }
        objectValue["type"]?.let { type ->
            val matches = when (type.text()) {
                "string" -> value is WireValue.Text
                "integer" -> value.longOrNull() != null
                "number" -> value.decimalOrNull() != null
                "boolean" -> value is WireValue.BooleanValue
                "null" -> value == WireValue.Null
                "array" -> value is WireValue.ArrayValue
                "object" -> value is WireValue.ObjectValue
                else -> throw UnsupportedSchema()
            }
            if (!matches) return false
        }

        when (value) {
            is WireValue.Number -> {
                val number = value.decimalOrNull() ?: return false
                objectValue["minimum"]?.let { if (number < it.decimal()) return false }
                objectValue["maximum"]?.let { if (number > it.decimal()) return false }
            }
            is WireValue.Text -> {
                val text = value.value
                val count = text.codePointCount(0, text.length).toLong()
                objectValue["minLength"]?.let { if (count < it.integer()) return false }
                objectValue["maxLength"]?.let { if (count > it.integer()) return false }
                objectValue["pattern"]?.let { if (!Regex(it.text()).containsMatchIn(text)) return false }
                if (mode == Mode.CONTRACT) {
                    objectValue["x-max-utf8-bytes"]?.let {
                        if (text.toByteArray(Charsets.UTF_8).size > it.integer()) return false
                    }
                    if (objectValue.containsKey("x-syncapi-format") && !validCalendarDate(text)) return false
                }
            }
            is WireValue.ArrayValue -> {
                val values = value.values
                objectValue["minItems"]?.let { if (values.size < it.integer()) return false }
                objectValue["maxItems"]?.let { if (values.size > it.integer()) return false }
                if (objectValue["uniqueItems"] == WireValue.BooleanValue(true)) {
                    for (index in values.indices) if (values.take(index).any { equivalent(it, values[index]) }) return false
                }
                objectValue["items"]?.let { items ->
                    if (!values.all { validate(it, items, mode, base) }) return false
                }
            }
            is WireValue.ObjectValue -> {
                val fields = value.fields
                objectValue["minProperties"]?.let { if (fields.size < it.integer()) return false }
                if (!fields.keys.containsAll(required)) return false
                val properties = objectValue["properties"]?.objectValue() ?: emptyMap()
                for ((key, item) in fields) {
                    objectValue["propertyNames"]?.let {
                        if (!validate(WireValue.Text(key), it, mode, base)) return false
                    }
                    val property = properties[key]
                    if (property != null) {
                        if (!validate(item, property, mode, base)) return false
                    } else when (val additional = objectValue["additionalProperties"]) {
                        WireValue.BooleanValue(false) -> return false
                        is WireValue.ObjectValue -> if (!validate(item, additional, mode, base)) return false
                        else -> Unit
                    }
                }
                if (mode == Mode.CONTRACT) for (rule in objectValue["x-syncapi-rules"]?.stringList().orEmpty()) {
                    if (!validateRule(rule, fields)) return false
                }
            }
            else -> Unit
        }
        return true
    }

    // Audit even schemas whose branches/items have no fixture values. Unsupported
    // keywords, extensions and unresolved references cannot hide in unused nodes.
    fun audit(schema: WireValue, baseID: URI? = null) {
        val fields = schema.objectValue()
        auditKeywords(fields)
        val base = fields["\$id"]?.text()?.let(::URI) ?: baseID
        fields["\$ref"]?.let { if (!schemasByID.containsKey(resolve(base, it.text()))) throw UnsupportedSchema() }
        fields["properties"]?.objectValue()?.values?.forEach { audit(it, base) }
        for (key in listOf("items", "propertyNames")) fields[key]?.let { audit(it, base) }
        (fields["additionalProperties"] as? WireValue.ObjectValue)?.let { audit(it, base) }
        for (key in listOf("oneOf", "allOf")) fields[key]?.arrayValue()?.forEach { audit(it, base) }
    }

    private fun auditKeywords(fields: Map<String, WireValue>) {
        if (!supported.containsAll(fields.keys)) throw UnsupportedSchema()
        fields["type"]?.let { if (it.text() !in types) throw UnsupportedSchema() }
        fields["required"]?.stringList()
        fields["x-syncapi-format"]?.let { if (it.text() != "utc-milliseconds") throw UnsupportedSchema() }
        fields["x-syncapi-rules"]?.let { if (!rules.containsAll(it.stringList())) throw UnsupportedSchema() }
        fields["pattern"]?.let { Regex(it.text()) }
    }

    private fun validateRule(rule: String, fields: Map<String, WireValue>): Boolean {
        return when (rule) {
        "group-scope-key" -> {
            val groupID = (fields["group_id"] as? WireValue.Text)?.value
            groupID != null && fields["key"] == WireValue.Text("group:$groupID")
        }
        "sync-page" -> {
            val head = fields["head"]?.longOrNull()
            val mode = (fields["mode"] as? WireValue.Text)?.value
            val items = (fields["items"] as? WireValue.ArrayValue)?.values
            head != null && mode != null && items != null && items.all { item ->
                val objectValue = (item as? WireValue.ObjectValue)?.fields
                val seq = objectValue?.get("seq")?.longOrNull()
                seq != null && seq > 0 && seq <= head && (mode != "snapshot" ||
                    (objectValue["kind"] == WireValue.Text("upsert") && seq == head))
            }
        }
        "pull-item-budget" -> {
            val scopes = (fields["scopes"] as? WireValue.ArrayValue)?.values ?: return false
            val removed = (fields["removed"] as? WireValue.ArrayValue)?.values ?: return false
            val keys = scopes.mapNotNull { ((it as? WireValue.ObjectValue)?.fields?.get("key") as? WireValue.Text)?.value }
            val users = scopes.count { (it as? WireValue.ObjectValue)?.fields?.get("kind") == WireValue.Text("user") }
            val count = scopes.sumOf { ((it as? WireValue.ObjectValue)?.fields?.get("items") as? WireValue.ArrayValue)?.values?.size ?: 0 }
            count <= 200 && keys.toSet().size == scopes.size && users == 1 &&
                keys.none { removed.contains(WireValue.Text(it)) }
        }
        else -> throw UnsupportedSchema()
        }
    }

    private fun validCalendarDate(text: String): Boolean {
        if (!utcPattern.matches(text)) return false
        val year = text.substring(0, 4).toInt()
        val month = text.substring(5, 7).toInt()
        val day = text.substring(8, 10).toInt()
        val leap = year % 400 == 0 || (year % 4 == 0 && year % 100 != 0)
        val days = listOf(31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
        return day in 1..days[month - 1]
    }

    companion object {
        fun load(files: Map<String, Path>): SchemaValidator {
            val idsByName = linkedMapOf<String, String>()
            val schemas = linkedMapOf<String, WireValue>()
            for ((name, file) in files) {
                val schema = WireJson.parse(Files.readAllBytes(file))
                val fields = schema.objectValue()
                val id = fields["\$id"]?.text() ?: throw UnsupportedSchema()
                val uri = URI(id)
                if (!uri.isAbsolute || uri.path.substringAfterLast('/') != "$name.json" ||
                    fields["title"] != WireValue.Text(name) ||
                    fields["\$schema"] != WireValue.Text("https://json-schema.org/draft/2020-12/schema")) throw UnsupportedSchema()
                if (schemas.put(id, schema) != null) throw UnsupportedSchema()
                idsByName[name] = id
            }
            return SchemaValidator(schemas, idsByName).also { validator -> schemas.values.forEach { validator.audit(it) } }
        }

        private val supported = setOf(
            "\$schema", "\$id", "title", "\$ref", "type", "const", "enum", "oneOf", "allOf",
            "minimum", "maximum", "minLength", "maxLength", "pattern", "format",
            "items", "minItems", "maxItems", "uniqueItems", "properties", "required",
            "additionalProperties", "minProperties", "propertyNames", "x-max-utf8-bytes",
            "x-syncapi-format", "x-syncapi-rules",
        )
        private val types = setOf("string", "integer", "number", "boolean", "null", "array", "object")
        private val rules = setOf("group-scope-key", "sync-page", "pull-item-budget")
        private val utcPattern = Regex("(?!0000)[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]\\.[0-9]{3}Z")

        private fun resolve(base: URI?, reference: String): String = (base?.resolve(reference) ?: URI(reference)).toString()
    }
}

private fun WireValue.objectValue(): Map<String, WireValue> =
    (this as? WireValue.ObjectValue)?.fields ?: throw UnsupportedSchema()
private fun WireValue.arrayValue(): List<WireValue> =
    (this as? WireValue.ArrayValue)?.values ?: throw UnsupportedSchema()
private fun WireValue.text(): String = (this as? WireValue.Text)?.value ?: throw UnsupportedSchema()
private fun WireValue.stringList(): List<String> = arrayValue().map { it.text() }
private fun WireValue.longOrNull(): Long? = try { longValue() } catch (_: WireContractException) { null }
private fun WireValue.integer(): Long = longOrNull() ?: throw UnsupportedSchema()
private fun WireValue.decimalOrNull(): BigDecimal? =
    (this as? WireValue.Number)?.token?.toBigDecimalOrNull()
private fun WireValue.decimal(): BigDecimal = decimalOrNull() ?: throw UnsupportedSchema()

private fun equivalent(left: WireValue, right: WireValue): Boolean {
    return when {
    left is WireValue.Number && right is WireValue.Number ->
        left.decimalOrNull()?.compareTo(right.decimalOrNull() ?: return false) == 0
    left is WireValue.ArrayValue && right is WireValue.ArrayValue ->
        left.values.size == right.values.size && left.values.zip(right.values).all { equivalent(it.first, it.second) }
    left is WireValue.ObjectValue && right is WireValue.ObjectValue ->
        left.fields.keys == right.fields.keys && left.fields.all { (key, value) -> equivalent(value, right.fields.getValue(key)) }
    else -> left == right
    }
}
