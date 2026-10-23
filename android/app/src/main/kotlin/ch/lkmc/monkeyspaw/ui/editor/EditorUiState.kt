package ch.lkmc.monkeyspaw.ui.editor

import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.library.PromptProvenance
import ch.lkmc.monkeyspaw.core.syncapi.Role
import ch.lkmc.monkeyspaw.core.ports.FileStamp
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.ui.library.LibrarySelection
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

internal enum class EditorTab { EDIT, PREVIEW, FIELDS, HISTORY }
internal enum class EditorStatus { CLOSED, LOADING, READY, SAVING, COMMAND }
internal enum class EditorDecision { SAVE, DISCARD, CANCEL }
internal enum class EditorConflictChoice { KEEP_MINE, TAKE_THEIRS, DISCARD, CANCEL, REVIEW }
internal enum class EditorConflictPresentation { DIALOG, BANNER }
internal enum class EditorFailure { DATA, INVALID, READ_ONLY, ACCESS_CHANGED, OCCUPIED, INVALID_PATH, IDENTITY, RECOVERY, UNVERIFIED, FORENSIC }

internal data class EditorDestination(val group: GroupAccessGroup? = null) {
    val canWrite: Boolean get() = group?.role != Role.VIEWER
}

internal data class EditorMoveTarget(val groupID: ULID?, val subfolder: String)

internal sealed interface EditorAction {
    data class Open(val selection: LibrarySelection) : EditorAction
    data class New(val path: String) : EditorAction
    data object Close : EditorAction
    data object Reload : EditorAction
    data class Rename(val filename: String) : EditorAction
    data class Move(val folder: String) : EditorAction
    data object Delete : EditorAction
    data class Restore(val revision: HistoryRevision) : EditorAction
}

internal data class EditorPendingDecision(val id: Long, val action: EditorAction)
internal data class EditorConflict(val deleted: Boolean, val stamp: FileStamp? = null,
    val source: String? = null, val readOnlyReason: SourceReadOnlyReason? = null,
    val loading: Boolean = false, val failure: EditorFailure? = null,
    val presentation: EditorConflictPresentation = EditorConflictPresentation.DIALOG)

/** A value captured before worker work begins; later edits cannot change its source or baseline. */
internal data class EditorSnapshot(val session: Long, val revision: Long, val relativePath: String,
    val source: String, val stamp: FileStamp?, val identity: PromptIdentity?, val isNew: Boolean) {
    override fun toString(): String = "<editor snapshot redacted>"
}

internal data class EditorRevision(val revision: HistoryRevision, val byteCount: Int,
    val source: String?, val canRestore: Boolean, val provenance: PromptProvenance? = null)

internal data class EditorHistoryState(val revisions: List<EditorRevision> = emptyList(),
    val selected: HistoryRevision? = null, val loading: Boolean = false, val failure: EditorFailure? = null,
    val currentProvenance: PromptProvenance? = null) {
    val selectedRevision: EditorRevision? get() = revisions.firstOrNull { it.revision == selected }
}

internal data class EditorUiState(
    val relativePath: String? = null,
    val selection: LibrarySelection? = null,
    val source: String? = null,
    val stamp: FileStamp? = null,
    val isNew: Boolean = false,
    val dirty: Boolean = false,
    val status: EditorStatus = EditorStatus.CLOSED,
    val tab: EditorTab = EditorTab.EDIT,
    val title: String = "",
    val issues: List<PromptIssue> = emptyList(),
    val fields: List<PromptField> = emptyList(),
    val fieldSettings: List<PromptFieldSettings>? = null,
    val preview: String = "",
    val previewAvailable: Boolean = false,
    val isPrivate: Boolean = false,
    val quoteSelection: ReviewQuoteSelection? = null,
    val validating: Boolean = false,
    val readOnlyReason: SourceReadOnlyReason? = null,
    val access: PromptAccessState = PromptAccessState.Local,
    val destinations: List<EditorDestination> = listOf(EditorDestination()),
    val failure: EditorFailure? = null,
    val saveIssues: List<PromptIssue> = emptyList(),
    val conflict: EditorConflict? = null,
    val pendingDecision: EditorPendingDecision? = null,
    val queuedActions: List<EditorAction> = emptyList(),
    val history: EditorHistoryState = EditorHistoryState(),
    val historyMaintenanceFailed: Boolean = false,
    val provenanceMaintenanceFailed: Boolean = false,
    val assistantAcceptanceOutcome: AssistantAcceptanceOutcome? = null,
    val lastAssistantCopy: LibrarySelection? = null,
) {
    val isOpen: Boolean get() = relativePath != null
    val writing: Boolean get() = status == EditorStatus.SAVING || status == EditorStatus.COMMAND
    val canEdit: Boolean get() = source != null && readOnlyReason == null &&
        status != EditorStatus.LOADING && status != EditorStatus.COMMAND
    val canSave: Boolean get() = canEdit && !writing && conflict == null && (isNew || stamp != null)
    val canCommand: Boolean get() = !isNew && stamp != null && readOnlyReason == null &&
        !writing && status != EditorStatus.LOADING && conflict == null
    val canPrivateCopy: Boolean get() = !isNew && source != null && previewAvailable && !validating &&
        !writing && status == EditorStatus.READY && pendingDecision == null
    val group: GroupAccessGroup? get() = (access as? PromptAccessState.Group)?.group

    override fun toString(): String = "<editor state redacted>"
}

internal data class EditorDocumentState(val title: String, val issues: List<PromptIssue>,
    val fields: List<PromptField>, val preview: String, val previewAvailable: Boolean, val isPrivate: Boolean,
    val fieldSettings: List<PromptFieldSettings>? = null)

/** History rows show a localized medium date with a short time instead of the raw ISO instant. */
internal fun editorTimestamp(instant: Instant, locale: Locale = Locale.getDefault(),
    zone: ZoneId = ZoneId.systemDefault()): String =
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withLocale(locale)
        .withZone(zone).format(instant)

/** Editor preview uses tokens directly: absent defaults remain markers, including choice fields. */
internal fun projectEditor(document: PromptDocument, now: Instant, zone: ZoneId): EditorDocumentState {
    val effective = document.effectiveFields
    val used = effective.map { it.name }.toSet()
    val fields = effective + document.frontMatter.fields.filterNot { it.name in used }
    val defaults = effective.associate { it.name to it.defaultValue.ifEmpty { "{${it.name}}" } }
    val date = DateTimeFormatter.ofPattern("uuuu-MM-dd", Locale.ROOT).withZone(zone).format(now)
    val time = DateTimeFormatter.ofPattern("HH:mm", Locale.ROOT).withZone(zone).format(now)
    val preview = if (!document.canRender) "" else document.template.tokens.joinToString("") { token ->
        when (token) {
            is TemplateToken.Literal -> token.text
            TemplateToken.EscapedOpener -> "{{"
            is TemplateToken.Placeholder -> when (token.name) {
                "clipboard" -> "{clipboard}"
                "date" -> date
                "time" -> time
                else -> defaults[token.name] ?: "{${token.name}}"
            }
        }
    }
    return EditorDocumentState(document.frontMatter.title, document.issues, fields, preview, document.canRender,
        document.frontMatter.isPrivate, PromptCodec.fieldSettings(document))
}
