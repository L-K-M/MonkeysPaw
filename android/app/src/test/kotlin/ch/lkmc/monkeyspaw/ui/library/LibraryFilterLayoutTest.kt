package ch.lkmc.monkeyspaw.ui.library

import kotlin.test.Test
import kotlin.test.assertEquals

internal class LibraryFilterLayoutTest {
    @Test fun `quick rail keeps common filters and browse retains every other section`() {
        val sections = listOf(
            LibrarySection(LibraryFilter.All, 2), LibrarySection(LibraryFilter.Favourites, 0),
            LibrarySection(LibraryFilter.Recent, 1), LibrarySection(LibraryFilter.Conflicts, 0),
            LibrarySection(LibraryFilter.Folder("writing"), 2), LibrarySection(LibraryFilter.Tag("work"), 1),
        )
        val result = libraryFilterSections(sections)
        assertEquals(sections.take(3), result.quick)
        assertEquals(sections.drop(3), result.browse)
        assertEquals(sections.size, (result.quick + result.browse).size)
    }

    @Test fun `actionable conflicts stay visible on the quick rail`() {
        val conflict = LibrarySection(LibraryFilter.Conflicts, 1)
        assertEquals(listOf(conflict), libraryFilterSections(listOf(conflict)).quick)
        assertEquals(emptyList(), libraryFilterSections(listOf(conflict)).browse)
        assertEquals(LibraryFilterSections(emptyList(), emptyList()), libraryFilterSections(emptyList()))
    }
}
