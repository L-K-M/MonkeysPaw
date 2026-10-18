package ch.lkmc.monkeyspaw.ui.library

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.sync.SyncPromptOrigin
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssue
import ch.lkmc.monkeyspaw.core.domain.ranking.SearchNormalizer
import ch.lkmc.monkeyspaw.core.ports.FileStamp
import ch.lkmc.monkeyspaw.core.services.IndexedPrompt
import ch.lkmc.monkeyspaw.core.services.PromptIdentity
import ch.lkmc.monkeyspaw.core.services.PromptAccessState
import ch.lkmc.monkeyspaw.core.services.GroupAccessGroup
import ch.lkmc.monkeyspaw.data.LibrarySearchSnapshot
import java.time.Instant

internal sealed interface LibraryFilter {
    data object All : LibraryFilter
    data object Favourites : LibraryFilter
    data object Recent : LibraryFilter
    data object Conflicts : LibraryFilter
    data class Group(val id: ULID) : LibraryFilter
    data class Folder(val path: String) : LibraryFilter
    data class Tag(val key: String) : LibraryFilter
}

internal data class LibrarySection(val filter: LibraryFilter, val count: Int, val title: String = "", val group: GroupAccessGroup? = null)

/** Identity follows assigned renames; the exact path disambiguates duplicate identities. */
internal data class LibrarySelection(val identity: PromptIdentity, val relativePath: String)

internal data class LibraryRow(
    val selection: LibrarySelection,
    val stamp: FileStamp,
    val title: String,
    val folder: String,
    val tags: List<String>,
    val description: String?,
    val favorite: Boolean,
    val issues: List<PromptIssue>,
    val isReadOnly: Boolean,
    val lastUsedAt: Instant?,
    val access: PromptAccessState = PromptAccessState.Local,
    val accessGeneration: Long = 0,
    val canFavorite: Boolean = !isReadOnly,
    val syncOrigin: SyncPromptOrigin? = null,
) {
    val group: GroupAccessGroup? get() = (access as? PromptAccessState.Group)?.group
}

internal enum class LibraryContent { LOADING, READY, EMPTY, NO_MATCH, FAILED }
internal enum class LibraryFailure { DATA, FAVOURITE, CHANGED }

internal data class LibraryUiState(
    val query: String = "",
    val filter: LibraryFilter = LibraryFilter.All,
    val sections: List<LibrarySection> = emptyList(),
    val rows: List<LibraryRow> = emptyList(),
    // Selection survives filters hiding its row; opening a later destination must use this key.
    val selectedPrompt: LibraryRow? = null,
    val content: LibraryContent = LibraryContent.LOADING,
    val refreshing: Boolean = false,
    val favoritePending: LibrarySelection? = null,
    val failure: LibraryFailure? = null,
    val historyMaintenanceFailed: Boolean = false,
)

internal data class LibraryProjection(
    val all: List<LibraryRow>,
    val sections: List<LibrarySection>,
    val filter: LibraryFilter,
    val rows: List<LibraryRow>,
    val content: LibraryContent,
)

/** Counts use the complete library. Filters narrow Core's ranked matches without rescoring them. */
internal fun projectLibrary(loaded: LibrarySearchSnapshot, requested: LibraryFilter): LibraryProjection {
    val all = loaded.state.snapshot.prompts.map(::libraryRow)
    val byPath = all.associateBy { it.selection.relativePath }
    val recent = all.filter { it.lastUsedAt != null }.sortedWith { left, right ->
        val time = right.lastUsedAt!!.compareTo(left.lastUsedAt!!)
        if (time != 0) time else titleOrder(left, right)
    }.take(Limits.libraryRecentCap)
    val recentPaths = recent.map { it.selection.relativePath }.toSet()
    val folders = mutableMapOf<String, Int>()
    val tags = mutableMapOf<String, Pair<String, Int>>()
    for (row in all) {
        for (folder in folderAncestors(row.selection.relativePath)) folders[folder] = (folders[folder] ?: 0) + 1
        val counted = mutableSetOf<String>()
        for (tag in row.tags) {
            val key = SearchNormalizer.normalize(tag)
            if (key.isEmpty() || !counted.add(key)) continue
            val previous = tags[key]
            val title = if (previous == null || utf8Order(tag, previous.first) < 0) tag else previous.first
            tags[key] = title to (previous?.second ?: 0) + 1
        }
    }
    val sections = listOf(
        LibrarySection(LibraryFilter.All, all.size),
        LibrarySection(LibraryFilter.Favourites, all.count { it.favorite }),
        LibrarySection(LibraryFilter.Recent, recent.size),
        LibrarySection(LibraryFilter.Conflicts, all.count { it.syncOrigin != null }),
    ) + loaded.state.access?.groups.orEmpty().values.sortedWith { a, b ->
        val names = utf8Order(a.name, b.name)
        if (names != 0) names else utf8Order(a.id.rawValue, b.id.rawValue)
    }.map { group -> LibrarySection(LibraryFilter.Group(group.id), all.count {
        (it.access as? PromptAccessState.Group)?.group?.id == group.id
    }, group.name, group) } +
        folders.keys.sortedWith(::folderOrder).map { LibrarySection(LibraryFilter.Folder(it), folders.getValue(it), it) } +
        tags.keys.sortedWith(::utf8Order).map { LibrarySection(LibraryFilter.Tag(it), tags.getValue(it).second, "#" + tags.getValue(it).first) }
    val filter = requested.takeIf { id -> sections.any { it.filter == id } } ?: LibraryFilter.All
    var rows = loaded.matches.mapNotNull { byPath[it.entry.relativePath] }.filter { row ->
        when (filter) {
            LibraryFilter.All -> true
            LibraryFilter.Favourites -> row.favorite
            LibraryFilter.Recent -> row.selection.relativePath in recentPaths
            LibraryFilter.Conflicts -> row.syncOrigin != null
            is LibraryFilter.Group -> (row.access as? PromptAccessState.Group)?.group?.id == filter.id
            is LibraryFilter.Folder -> filter.path in folderAncestors(row.selection.relativePath)
            is LibraryFilter.Tag -> row.tags.any { SearchNormalizer.normalize(it) == filter.key }
        }
    }
    // Recent means latest use, not accumulated frecency. Apply its cap before the search filter.
    if (filter == LibraryFilter.Recent) rows = rows.sortedWith { left, right ->
        val time = right.lastUsedAt!!.compareTo(left.lastUsedAt!!)
        if (time != 0) time else titleOrder(left, right)
    }
    val content = when {
        loaded.state.snapshot.version == 0L -> if (loaded.state.error == null) LibraryContent.LOADING else LibraryContent.FAILED
        all.isEmpty() -> LibraryContent.EMPTY
        rows.isEmpty() -> LibraryContent.NO_MATCH
        else -> LibraryContent.READY
    }
    return LibraryProjection(all, sections, filter, rows, content)
}

private fun libraryRow(indexed: IndexedPrompt): LibraryRow {
    val entry = indexed.entry
    val document = entry.document
    val front = document.frontMatter
    return LibraryRow(LibrarySelection(entry.identity, entry.relativePath), entry.stamp, front.title,
        entry.folder, front.tags, front.description, entry.favorite, entry.issues,
        isReadOnly = !document.canRender || entry.access.readOnlyReason != null, lastUsedAt = indexed.useEvents.maxOrNull(),
        access = entry.access, accessGeneration = entry.accessGeneration,
        canFavorite = when (entry.access) {
            PromptAccessState.Local -> document.canRender
            is PromptAccessState.Group -> true
            PromptAccessState.Unavailable -> false
        }, syncOrigin = entry.syncOrigin)
}

private fun folderAncestors(path: String): List<String> = path.indices.filter { path[it] == '/' }.map { path.substring(0, it) }

private fun folderOrder(left: String, right: String): Int {
    val a = left.split('/')
    val b = right.split('/')
    for (index in 0 until minOf(a.size, b.size)) {
        val order = utf8Order(a[index], b[index])
        if (order != 0) return order
    }
    return a.size.compareTo(b.size)
}

private fun titleOrder(left: LibraryRow, right: LibraryRow): Int {
    val titles = utf8Order(left.title, right.title)
    return if (titles != 0) titles else utf8Order(left.selection.relativePath, right.selection.relativePath)
}

private fun utf8Order(left: String, right: String): Int {
    val a = left.encodeToByteArray()
    val b = right.encodeToByteArray()
    for (index in 0 until minOf(a.size, b.size)) {
        val order = (a[index].toInt() and 255).compareTo(b[index].toInt() and 255)
        if (order != 0) return order
    }
    return a.size.compareTo(b.size)
}
