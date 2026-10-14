package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.sync.*
import java.util.UUID

/** Permanent raw holds precede identity matching and never imply upload consent. */
internal class SyncRetainedRescue(
    val operationID: UUID,
    val binding: SyncLibraryIdentity,
    val path: String,
    val sourcePath: String,
    val hash: SyncHash,
    val issue: SyncIssueCode,
    val origin: SyncPromptOrigin,
) {
    override fun toString(): String = "<retained sync rescue>"
}
