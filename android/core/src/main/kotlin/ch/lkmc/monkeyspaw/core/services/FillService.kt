package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.ports.*
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

enum class PersistenceWarning { REMEMBERED_VALUES_UNAVAILABLE, REMEMBERED_VALUES_NOT_SAVED, USAGE_NOT_SAVED }

data class FillFormField(val field: PromptField, val prefill: String)

data class FillForm(
    val fields: List<FillFormField>,
    val issues: List<PromptIssue>,
    val canRender: Boolean,
    val isReadOnly: Boolean,
    val warning: PersistenceWarning? = null,
)

sealed interface FillPreview {
    data class Rendered(val text: String) : FillPreview
    data class Blocked(val error: PromptRenderError, val issues: List<PromptIssue>) : FillPreview
}

/** Preparation is read-only; delivery and post-delivery learning are separate intents. */
class FillService(private val library: LibraryService, private val clipboard: Clipboard, private val timeZone: () -> ZoneId) {
    private val snapshotLock = Any()

    /** Call on the clipboard's owning thread when opening a form, never while browsing rows. */
    fun builtinSnapshot(document: PromptDocument, completion: (PromptBuiltinValues) -> Unit) {
        val used = document.template.builtins
        val local = if (BuiltinName.DATE in used || BuiltinName.TIME in used) {
            val (now, zone) = synchronized(snapshotLock) { library.clock.now() to timeZone() }
            now.atZone(zone)
        } else null
        val date = if (BuiltinName.DATE in used) DateTimeFormatter.ofPattern("uuuu-MM-dd", Locale.ROOT).format(local) else null
        val time = if (BuiltinName.TIME in used) DateTimeFormatter.ofPattern("HH:mm", Locale.ROOT).format(local) else null
        if (BuiltinName.CLIPBOARD !in document.template.builtins) {
            completion(PromptBuiltinValues(date = date, time = time))
            return
        }
        val completed = AtomicBoolean(false)
        fun deliver(text: String?) {
            if (completed.compareAndSet(false, true)) completion(PromptBuiltinValues(text ?: "", date, time))
        }
        try { clipboard.readText(::deliver) } catch (_: Exception) { deliver(null) }
    }

    fun form(entry: LibraryEntry): FillForm = library.mutations.run {
        var warning: PersistenceWarning? = null
        val remembered = try { library.values.rememberedValues(entry.identity) }
        catch (_: Exception) { warning = PersistenceWarning.REMEMBERED_VALUES_UNAVAILABLE; emptyMap() }
        val document = entry.document
        val fields = document.effectiveFields.map { field ->
            FillFormField(field, if (field.remember) remembered[field.name] ?: field.defaultValue else field.defaultValue)
        }
        FillForm(fields, document.issues, document.canRender, document.isReadOnly, warning)
    }

    fun preview(document: PromptDocument, values: Map<String, String>, builtins: PromptBuiltinValues): FillPreview =
        try { FillPreview.Rendered(render(document, values, builtins)) }
        catch (error: PromptRenderError) { FillPreview.Blocked(error, document.issues) }

    fun render(document: PromptDocument, values: Map<String, String>, builtins: PromptBuiltinValues): String =
        PromptRenderer.render(document, values, builtins)

    /** On the clipboard's owning UI thread. Validation/write failure prevents any learning. */
    fun copy(document: PromptDocument, values: Map<String, String>, builtins: PromptBuiltinValues): String {
        val text = render(document, values, builtins)
        try { clipboard.writeText(text) } catch (error: Exception) { throw sanitized(error) }
        return text
    }

    /** Render once from the held snapshot; a refused effect retains the form for an explicit retry. */
    fun deliver(document: PromptDocument, values: Map<String, String>, builtins: PromptBuiltinValues,
        mode: DeliveryMode, endpoint: TextDelivery): TextDeliveryResult {
        val text = render(document, values, builtins)
        return try { endpoint.deliver(mode, text) } catch (error: Exception) { throw sanitized(error) }
    }

    /** Call once after acceptance on IO. Independent failures warn without repeating the effect. */
    fun recordDelivery(entry: LibraryEntry, delivered: Map<String, String>, policy: LearningPolicy): List<PersistenceWarning> {
        if (policy == LearningPolicy.EPHEMERAL) return emptyList()
        return library.mutations.run {
            val warnings = mutableListOf<PersistenceWarning>()
            try { rememberedOnDelivery(entry.identity, entry.document.effectiveFields, delivered) }
            catch (_: Exception) { warnings.add(PersistenceWarning.REMEMBERED_VALUES_NOT_SAVED) }
            try { library.index.recordUse(entry.identity) }
            catch (_: Exception) { warnings.add(PersistenceWarning.USAGE_NOT_SAVED) }
            warnings
        }
    }

    /**
     * Only after delivery succeeded, on an IO worker. Record supplied remember-fields
     * verbatim, including empty strings; never pin absent fields to a default.
     */
    fun rememberedOnDelivery(identity: PromptIdentity, fields: List<PromptField>, delivered: Map<String, String>) =
        library.values.record(identity, fields.filter { it.remember && it.name in delivered }
            .associate { it.name to delivered.getValue(it.name) })

    fun forgetValues(identity: PromptIdentity) = library.values.remove(identity)
    fun forgetAllValues() = library.values.removeAll()
}
