package ch.lkmc.monkeyspaw.ui.editor

import ch.lkmc.monkeyspaw.core.domain.format.PromptFieldOptionSettings
import ch.lkmc.monkeyspaw.core.domain.format.PromptFieldSettings

/** A staged settings draft. Each choice row keeps a stable local UI id so a
    delayed field commit follows its option rather than its old position, and a
    removed row's late callback is ignored. Ids never leave the sheet. */
internal data class StagedFieldSettings(
    private val nextId: Long,
    val settings: PromptFieldSettings,
    val rows: List<OptionRow>,
) {
    internal data class OptionRow(val id: Long, val option: PromptFieldOptionSettings)

    private val options: List<PromptFieldOptionSettings> get() = rows.map { it.option }

    /** Rows own the option list; other properties stage as plain copies. */
    fun edit(change: (PromptFieldSettings) -> PromptFieldSettings): StagedFieldSettings =
        copy(settings = change(settings).copy(options = options))

    fun addOption(): StagedFieldSettings =
        copy(nextId = nextId + 1, rows = rows + OptionRow(nextId, PromptFieldOptionSettings("", ""))).syncOptions()

    fun removeOption(id: Long): StagedFieldSettings =
        copy(rows = rows.filterNot { it.id == id }).syncOptions()

    /** The row index is resolved at event time, not bound at composition. */
    fun editOption(id: Long, change: (PromptFieldOptionSettings) -> PromptFieldOptionSettings): StagedFieldSettings {
        val index = rows.indexOfFirst { it.id == id }
        if (index < 0) return this
        val updated = rows.toMutableList()
        updated[index] = updated[index].copy(option = change(updated[index].option))
        return copy(rows = updated).syncOptions()
    }

    private fun syncOptions() = copy(settings = settings.copy(options = options))

    companion object {
        fun of(settings: PromptFieldSettings) = StagedFieldSettings(settings.options.size.toLong(), settings,
            settings.options.mapIndexed { index, option -> OptionRow(index.toLong(), option) })
    }
}
