package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.ports.Clipboard
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

enum class PersistenceWarning { REMEMBERED_VALUES_UNAVAILABLE }

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

/** Read-only preparation; learning is an explicit post-copy action. Cancelled forms teach nothing. */
class FillService(private val library: LibraryService, private val clipboard: Clipboard, private val timeZone: () -> ZoneId) {
    private val snapshotLock = Any()

    /** Call on the clipboard's owning thread when opening a form, never while browsing rows. */
    fun builtinSnapshot(document: PromptDocument, completion: (PromptBuiltinValues) -> Unit) {
        val (now, zone) = synchronized(snapshotLock) { library.clock.now() to timeZone() }
        val local = now.atZone(zone)
        val date = DateTimeFormatter.ofPattern("uuuu-MM-dd", Locale.ROOT).format(local)
        val time = DateTimeFormatter.ofPattern("HH:mm", Locale.ROOT).format(local)
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

    /**
     * Only after Clipboard.writeText succeeded, on an IO worker. Record supplied remember-fields
     * verbatim, including empty strings; never pin absent fields to a default. K15 owns copy lifetime
     * and reports failures here as post-copy warnings, then records usage through library.index.
     */
    fun rememberedOnDelivery(identity: PromptIdentity, fields: List<PromptField>, delivered: Map<String, String>) =
        library.values.record(identity, fields.filter { it.remember && it.name in delivered }
            .associate { it.name to delivered.getValue(it.name) })

    fun forgetValues(identity: PromptIdentity) = library.values.remove(identity)
    fun forgetAllValues() = library.values.removeAll()
}
