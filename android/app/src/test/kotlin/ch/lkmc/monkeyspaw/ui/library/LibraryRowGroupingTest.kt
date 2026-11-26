package ch.lkmc.monkeyspaw.ui.library

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.ports.FileStamp
import ch.lkmc.monkeyspaw.core.services.GroupAccessGroup
import ch.lkmc.monkeyspaw.core.services.PromptAccessState
import ch.lkmc.monkeyspaw.core.services.PromptIdentity
import ch.lkmc.monkeyspaw.core.syncapi.Role
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Grouping rules from §11.8, exercised without a repository so ordering is exact. */
internal class LibraryRowGroupingTest {
    private val idA = ULID.parse("01ARZ3NDEKTSV4RRFFQ69G5FAY")!!
    private val idB = ULID.parse("01ARZ3NDEKTSV4RRFFQ69G5FAW")!!

    @Test
    fun `group rows use committed names and subfolders and same-named groups stay separate`() {
        val team = GroupAccessGroup(idA, "Team", "Team", Role.EDITOR)
        val sameName = GroupAccessGroup(idB, "Team", "Other", Role.VIEWER)
        val rows = listOf(
            row("Groups/Team/root.md", "Groups/Team", PromptAccessState.Group(team)),
            row("Groups/Team/sub/child.md", "Groups/Team/sub", PromptAccessState.Group(team)),
            row("Groups/Other/same.md", "Groups/Other", PromptAccessState.Group(sameName)),
            row("Elsewhere/moved.md", "Elsewhere", PromptAccessState.Group(team)),
        )
        val groups = libraryRowGroups(rows)
        assertEquals(
            listOf(
                LibraryFolderKey.Group(idA, ""),
                LibraryFolderKey.Group(idA, "sub"),
                LibraryFolderKey.Group(idB, ""),
                LibraryFolderKey.Folder("Elsewhere"),
            ),
            groups.map { it.key },
        )
        assertEquals(
            listOf(
                LibraryFolderHeading.Group("Team", ""),
                LibraryFolderHeading.Group("Team", "sub"),
                LibraryFolderHeading.Group("Team", ""),
                LibraryFolderHeading.Folder("Elsewhere"),
            ),
            groups.map { it.heading },
        )
        // Two headings can render the same text while their keys stay distinct.
        assertEquals(2, groups.count { it.heading == LibraryFolderHeading.Group("Team", "") })
        assertEquals("Groups/Team/root.md", groups[0].rows.single().selection.relativePath)
        assertEquals("Groups/Team/sub/child.md", groups[1].rows.single().selection.relativePath)
        assertEquals("Elsewhere/moved.md", groups.last().rows.single().selection.relativePath)
    }

    @Test
    fun `byte-distinct folder names stay separate`() {
        val decomposed = "e\u0301"
        val precomposed = "\u00e9"
        val rows = listOf(
            row("$decomposed/a.md", decomposed),
            row("$precomposed/b.md", precomposed),
            row("$decomposed/c.md", decomposed),
        )
        val groups = libraryRowGroups(rows)
        assertEquals(listOf(LibraryFolderKey.Folder(decomposed), LibraryFolderKey.Folder(precomposed)), groups.map { it.key })
        assertEquals(
            listOf("$decomposed/a.md", "$decomposed/c.md", "$precomposed/b.md"),
            groups.flatMap { group -> group.rows }.map { it.selection.relativePath },
        )
    }

    @Test
    fun `top-level and unavailable rows join folder headings and every row is covered once`() {
        val team = GroupAccessGroup(idA, "Team", "Team", Role.EDITOR)
        val rows = listOf(
            row("plain.md", ""),
            row("Groups/Team/x.md", "Groups/Team", PromptAccessState.Group(team)),
            row("Groups/Ghost/y.md", "Groups/Ghost", PromptAccessState.Unavailable),
            row("Private/z.md", "Private"),
        )
        val groups = libraryRowGroups(rows)
        assertEquals(
            listOf(
                LibraryFolderKey.Folder(""),
                LibraryFolderKey.Group(idA, ""),
                LibraryFolderKey.Folder("Groups/Ghost"),
                LibraryFolderKey.Folder("Private"),
            ),
            groups.map { it.key },
        )
        assertEquals(LibraryFolderHeading.TopLevel, groups.first().heading)
        assertEquals(rows.size, groups.sumOf { it.rows.size })
        assertEquals(
            rows.map { it.selection.relativePath }.sorted(),
            groups.flatMap { group -> group.rows }.map { it.selection.relativePath }.sorted(),
        )
    }

    @Test
    fun `a flat row list gets no headings`() {
        val rows = listOf(row("a.md", ""), row("b.md", ""))
        assertTrue(libraryRowGroups(rows).isEmpty())
        assertTrue(libraryRowGroups(emptyList()).isEmpty())
    }

    private fun row(path: String, folder: String, access: PromptAccessState = PromptAccessState.Local): LibraryRow =
        LibraryRow(
            selection = LibrarySelection(PromptIdentity.Local("hash:$path"), path),
            stamp = FileStamp(path),
            title = path.substringAfterLast('/'),
            folder = folder,
            tags = emptyList(),
            description = null,
            favorite = false,
            issues = emptyList(),
            isReadOnly = false,
            lastUsedAt = null,
            access = access,
        )
}
