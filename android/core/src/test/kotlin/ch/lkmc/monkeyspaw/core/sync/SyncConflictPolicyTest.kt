package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.canonical.CanonicalForm
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.domain.paths.SyncPathIssueCode
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.time.Instant
import kotlin.test.*

class SyncConflictPolicyTest {
    private val v = SyncTestValues
    private val date = Instant.parse("2026-10-13T21:07:05Z")
    private val origin = SyncPromptOrigin.ConflictOf(v.personal)

    @Test fun editEditUsesAuthoritativeOwnershipAndKeepsExactLocalVersionPrivately() {
        val h = SyncJournalHarness()
        val local = put(h, "Local\r\n")
        val outcome = assertIs<SyncConflictOutcome.ServerWins>(resolve(SyncHTTPClientError.Conflict(head("Server", scope = v.groupScope, path = "New.md")), local = local))
        assertEquals(v.groupScope, outcome.head.scope)
        assertEquals("New.md", outcome.head.path)
        assertContentEquals(local.bytes, outcome.local!!.bytes)
        val copy = copy(local, h)
        assertTrue(copy.edit.path.startsWith("Conflicts/Personal/"))
        assertEquals(v.groupPrompt.rawValue, copy.edit.copyID)
        assertContentEquals(local.bytes, copy.edit.retainedBytes)
        assertEquals(origin, SyncConflictMetadata.origin(copy.edit.bytes!!, "Copy.md"))
        assertContentEquals(local.bytes, assertIs<SyncConflictOutcome.RemoteDeleted>(resolve(SyncHTTPClientError.Deleted, local = local)).local!!.bytes)
    }

    @Test fun localDeleteAgainstRemoteEditRestoresWithoutInventingACopy() {
        val outcome = assertIs<SyncConflictOutcome.ServerWins>(resolve(SyncHTTPClientError.Conflict(head("Remote edit")), intent(SyncOperation.DELETE)))
        assertNull(outcome.local)
        assertContentEquals(bytes("Remote edit"), outcome.head.bytes)
    }

    @Test fun moveConflictFollowsHeadButPathTakenRenamesIntendedDestination() {
        val request = intent(SyncOperation.MOVE, scope = v.groupScope, path = "Destination.md")
        val moved = assertIs<SyncConflictOutcome.ServerWins>(resolve(SyncHTTPClientError.Conflict(head("Elsewhere", path = "Actual.md")), request))
        assertEquals(v.userScope, moved.head.scope)
        assertEquals("Actual.md", moved.head.path)
        // The unrelated existing payload is deliberately not a prompt.
        val error = SyncHTTPClientError.PathTaken(ExistingPrompt(v.groupPrompt.rawValue, 1, "Unrelated"))
        assertEquals("Destination (3).md", assertIs<SyncConflictOutcome.ClashRename>(resolve(error, request, occupied = listOf("DESTINATION (2).md"))).path)
        val exhausted = assertIs<SyncConflictOutcome.FileError>(resolve(error, request, occupied = (2..20).map { "Destination ($it).md" }))
        assertEquals(SyncIssueCode.PathClash, exhausted.error.code)
        assertFalse(SyncConflictPolicy.shouldAttempt(request.fingerprint, exhausted.error))
        assertFailsWith<SyncConflictPolicyError.InvalidResponse> { resolve(error, intent(SyncOperation.DELETE)) }
    }

    @Test fun createPathTakenAdoptsOnlyIdentityNeutralEquality() {
        for (scope in listOf(v.userScope, v.groupScope)) {
            val request = intent(base = 0, scope = scope)
            val equal = SyncHTTPClientError.PathTaken(ExistingPrompt(v.groupPrompt.rawValue, 4, sent("Sent", v.groupPrompt, scope).decodeToString()))
            val adopted = assertIs<SyncConflictOutcome.AdoptExisting>(resolve(equal, request))
            assertEquals(v.groupPrompt, adopted.head.id)
            assertEquals(scope, adopted.head.scope)
            val unequal = SyncHTTPClientError.PathTaken(ExistingPrompt(v.groupPrompt.rawValue, 4, sent("Different", v.groupPrompt, scope).decodeToString()))
            assertEquals("a (2).md", assertIs<SyncConflictOutcome.ClashRename>(resolve(unequal, request)).path)
        }
    }

    @Test fun pathTakenUpdatesNeverAdoptUnrelatedIdentity() {
        for (request in listOf(intent(), intent(SyncOperation.MOVE))) {
            val error = SyncHTTPClientError.PathTaken(ExistingPrompt(v.groupPrompt.rawValue, 4, "not a prompt"))
            assertIs<SyncConflictOutcome.ClashRename>(resolve(error, request))
        }
        assertFailsWith<SyncConflictPolicyError.InvalidHead> {
            resolve(SyncHTTPClientError.PathTaken(ExistingPrompt(v.groupPrompt.rawValue, 1, "bad")), intent(base = 0))
        }
        assertNull(resolve(SyncHTTPClientError.SnapshotExpired(listOf(v.userScope.rawValue))))
    }

    @Test fun lostCreateEditAndMoveAcksCompareSentFactsWhileNewerLocalEditStaysDirty() {
        for (operation in listOf(SyncOperation.PUT, SyncOperation.MOVE)) {
            for (base in if (operation == SyncOperation.PUT) listOf(0L, 3L) else listOf(3L)) {
                val scope = if (operation == SyncOperation.MOVE) v.groupScope else v.userScope
                val request = intent(operation, base, scope)
                val h = SyncJournalHarness()
                val newer = put(h, "Edited while request was in flight")
                val acknowledged = assertIs<SyncConflictOutcome.Acknowledged>(resolve(SyncHTTPClientError.Conflict(head("Sent", base + 1, scope)), request, newer))
                assertEquals(request.sentHash, acknowledged.head.hash)
                assertFalse(newer.bytes.contentEquals(acknowledged.head.bytes))
                assertContentEquals(newer.bytes, h.local.prompts.read("a.md"))
                assertTrue(h.local.prompts.writes.isEmpty())
                assertIs<SyncConflictOutcome.ServerWins>(resolve(SyncHTTPClientError.Conflict(head("Edited while request was in flight", base + 2, scope)), request, newer))
            }
        }
        for (envelope in listOf(head("Sent", path = "Renamed.md"), head("Sent", scope = v.groupScope), head("Sent", rev = 1))) {
            assertIs<SyncConflictOutcome.ServerWins>(resolve(SyncHTTPClientError.Conflict(envelope)))
        }
    }

    @Test fun moveAckRequiresKnownDestinationCanonicalizedServerBaseline() {
        val unknown = SyncConflictIntent(v.personal, SyncOperation.MOVE, 1, v.groupScope, "a.md", null, bytes("Accompanying edit"), 0)
        assertIs<SyncConflictOutcome.ServerWins>(resolve(SyncHTTPClientError.Conflict(head("Server baseline", scope = v.groupScope)), unknown))
        val baseline = sent("Server baseline", v.personal, v.groupScope)
        val known = SyncConflictIntent(v.personal, SyncOperation.MOVE, 1, v.groupScope, "a.md", baseline, bytes("Accompanying edit"), 0)
        assertIs<SyncConflictOutcome.Acknowledged>(resolve(SyncHTTPClientError.Conflict(head("Server baseline", scope = v.groupScope)), known))
        assertNotEquals(known.fingerprint.contentHash, known.sentHash)
    }

    @Test fun groupAckUsesCanonicalSentBytesAndPrivateAckComparesEveryByte() {
        val raw = bytes("Sent", extra = "favorite: true\nprivate: true\n")
        val canonical = CanonicalForm.group(raw, "a.md").bytes
        val request = SyncConflictIntent(v.personal, SyncOperation.PUT, 1, v.groupScope, "a.md", canonical, raw, 0)
        val envelope = ConflictHead(2, wire(v.groupScope), "a.md", canonical.decodeToString())
        assertIs<SyncConflictOutcome.Acknowledged>(resolve(SyncHTTPClientError.Conflict(envelope), request))
        assertEquals(SyncHash.of(raw), request.fingerprint.contentHash)
        assertNotEquals(request.fingerprint.contentHash, request.sentHash)
        val withComment = head("Sent").copy(content = bytes("Sent", extra = "# representation\n").decodeToString())
        assertIs<SyncConflictOutcome.ServerWins>(resolve(SyncHTTPClientError.Conflict(withComment)))
    }

    @Test fun deleteOnly404And410IdempotencePreservesOtherOperationFailures() {
        for (error in listOf(SyncHTTPClientError.NotFound, SyncHTTPClientError.Deleted)) {
            assertEquals(SyncConflictOutcome.DeleteSucceeded, resolve(error, intent(SyncOperation.DELETE)))
        }
        for (request in listOf(intent(), intent(SyncOperation.MOVE), intent(base = 0))) {
            assertEquals(SyncIssueCode.NotFound, assertIs<SyncConflictOutcome.FileError>(resolve(SyncHTTPClientError.NotFound, request)).error.code)
            assertIs<SyncConflictOutcome.RemoteDeleted>(resolve(SyncHTTPClientError.Deleted, request))
        }
    }

    @Test fun deniedWritesRestoreOnlyAnAccessibleRecordedOriginalAndKeepLocalBytes() {
        val h = SyncJournalHarness()
        val local = put(h, "Keep private")
        val recorded = SyncPromptState(v.userScope, "a.md", 1, SyncHash.of(bytes("Old")))
        for (operation in SyncOperation.entries) {
            val request = intent(operation, scope = if (operation == SyncOperation.MOVE) v.groupScope else v.userScope,
                path = if (operation == SyncOperation.MOVE) "New.md" else "a.md")
            for (available in listOf(false, true)) {
                val outcome = assertIs<SyncConflictOutcome.Denied>(resolve(SyncHTTPClientError.Forbidden, request,
                    local.takeUnless { operation == SyncOperation.DELETE }, recorded, if (available) prompt("Current") else null))
                if (available) assertContentEquals(bytes("Current"), outcome.restore!!.bytes) else assertNull(outcome.restore)
                if (operation == SyncOperation.DELETE) assertNull(outcome.local) else assertContentEquals(local.bytes, outcome.local!!.bytes)
                assertEquals(SyncIssueCode.Forbidden, outcome.error.code)
                assertFalse(SyncConflictPolicy.shouldAttempt(request.fingerprint, outcome.error))
            }
        }
        for (accessible in listOf(prompt("Current"), prompt("Wrong ID", v.groupPrompt), prompt("New ownership", scope = v.groupScope), prompt("Moved", path = "Elsewhere.md"))) {
            val outcome = assertIs<SyncConflictOutcome.Denied>(resolve(SyncHTTPClientError.Forbidden, intent(base = 0), local, recorded, accessible))
            assertNull(outcome.restore)
            assertContentEquals(local.bytes, outcome.local!!.bytes)
        }
    }

    @Test fun deniedMalformedMismatchedOrUnrecordedHeadsCannotAuthorizeRestoration() {
        val h = SyncJournalHarness()
        val local = put(h, "Keep me")
        val recorded = SyncPromptState(v.userScope, "a.md", 1, SyncHash.of(bytes("Old")))
        val bad = listOf(prompt("Wrong ID", v.groupPrompt), prompt("Moved", path = "New.md"), prompt("Wrong scope", scope = v.groupScope),
            prompt("Bad").copy(content = "---\ntitle: [\n---\nBad"), prompt("Bad").copy(content = bytes("Wrong document ID", v.groupPrompt).decodeToString()))
        for (head in bad) {
            for (operation in listOf(SyncOperation.PUT, SyncOperation.MOVE)) {
                val outcome = assertIs<SyncConflictOutcome.Denied>(resolve(SyncHTTPClientError.Forbidden, intent(operation), local, recorded, head))
                assertNull(outcome.restore)
                assertContentEquals(local.bytes, outcome.local!!.bytes)
            }
        }
        assertNull(assertIs<SyncConflictOutcome.Denied>(resolve(SyncHTTPClientError.Forbidden, recorded = null, accessible = prompt("Current"))).restore)
        assertNull(assertIs<SyncConflictOutcome.Denied>(resolve(SyncHTTPClientError.Forbidden, recorded = SyncPromptState(v.userScope, "a.md", 0), accessible = prompt("Current"))).restore)
    }

    @Test fun inputErrorFingerprintPersistsAcrossRestartAndAllRepairsPermitRetry() {
        val h = SyncJournalHarness()
        val request = intent()
        val error = assertIs<SyncConflictOutcome.FileError>(resolve(SyncHTTPClientError.Validation(listOf(Issue("path.too_long", Severity.ERROR))), request)).error
        assertEquals(SyncIssueCode.Path(SyncPathIssueCode.PATH_TOO_LONG), error.code)
        h.states.update(h.binding) { SyncState(h.binding, prompts = mapOf(v.personalID to SyncPromptState(v.userScope, "a.md", 0, lastError = error))) }
        val saved = h.restart().states.load(h.binding)!!.prompts.getValue(v.personalID).lastError
        assertFalse(SyncConflictPolicy.shouldAttempt(request.fingerprint, saved))
        for (changed in listOf(intent(body = "Changed"), intent(path = "Fixed.md"), intent(scope = v.groupScope), intent(access = 1), intent(SyncOperation.MOVE))) {
            assertTrue(SyncConflictPolicy.shouldAttempt(changed.fingerprint, saved))
        }
        assertFalse(h.local.state.text("sync/state.json").contains("Sent"))
        assertTrue(SyncConflictPolicy.shouldAttempt(request.fingerprint, null))
        for (code in listOf("metadata.invalid_type", "prompt.id_mismatch")) {
            assertEquals(code, assertIs<SyncConflictOutcome.FileError>(resolve(SyncHTTPClientError.Validation(listOf(Issue(code, Severity.ERROR))))).error.code.rawValue)
        }
        for (issues in listOf(emptyList(), listOf(Issue("untrusted-error-body", Severity.ERROR)), listOf(Issue("path.too_long", Severity.WARNING)))) {
            assertFailsWith<SyncConflictPolicyError.InvalidResponse> { resolve(SyncHTTPClientError.Validation(issues)) }
        }
        for (error in listOf(SyncHTTPClientError.Unauthorized, SyncHTTPClientError.Transport(HttpTransportError.NetworkFailure), SyncHTTPClientError.ServerFailure(503))) {
            assertNull(resolve(error))
        }
    }

    @Test fun intentsRejectInvalidBasesPathsIdentityAndNoncanonicalGroupBytes() {
        for ((operation, base) in listOf(SyncOperation.PUT to -1L, SyncOperation.MOVE to 0L, SyncOperation.DELETE to 0L)) {
            assertFailsWith<SyncConflictPolicyError.InvalidIntent> { intent(operation, base) }
        }
        assertFailsWith<SyncConflictPolicyError.InvalidIntent> { SyncConflictIntent(v.personal, SyncOperation.PUT, 0, v.userScope, "a.md", null, bytes("Sent"), 0) }
        assertFailsWith<SyncConflictPolicyError.InvalidIntent> { SyncConflictIntent(v.personal, SyncOperation.DELETE, 1, v.userScope, "a.md", bytes("Sent"), bytes("Sent"), 0) }
        assertFailsWith<SyncConflictPolicyError.InvalidIntent> { intent(path = "Cafe\u0301.md") }
        assertFailsWith<SyncConflictPolicyError.InvalidIntent> { intent(path = "Groups/a.md") }
        assertFailsWith<SyncConflictPolicyError.InvalidIntent> { SyncConflictIntent(v.personal, SyncOperation.PUT, 1, v.userScope, "a.md", bytes("Sent", v.groupPrompt), bytes("Sent"), 0) }
        assertFailsWith<SyncConflictPolicyError.InvalidIntent> { SyncConflictIntent(v.personal, SyncOperation.PUT, 1, v.groupScope, "a.md", bytes("Sent"), bytes("Sent"), 0) }
        assertFailsWith<SyncError.InvalidState> { intent(access = -1) }
        assertFailsWith<SyncConflictPolicyError.InvalidIntent> { resolve(SyncHTTPClientError.NotFound, intent(scope = SyncScopeKey.User(v.otherUser))) }
        val h = SyncJournalHarness()
        assertFailsWith<SyncConflictPolicyError.InvalidIntent> { resolve(SyncHTTPClientError.NotFound, local = put(h, "Other", id = v.groupPrompt)) }
    }

    @Test fun malformedHeadsRefuseUnsafePlanningAndAllByteValuesAreOwnedAndRedacted() {
        for (bad in listOf(prompt("Bad").copy(rev = 0), prompt("Bad").copy(id = "invalid"), prompt("Bad").copy(path = "../a.md"),
            prompt("Bad").copy(path = "Cafe\u0301.md"), prompt("Bad").copy(content = bytes("Wrong", v.groupPrompt).decodeToString()),
            prompt("Bad").copy(content = "\uD800"), prompt("Bad").copy(content = bytes("Bad", extra = "x-monkeyspaw-rescued: 'true'\n").decodeToString()),
            prompt("Bad", scope = v.groupScope).copy(content = bytes("Noncanonical group").decodeToString()))) {
            assertFailsWith<SyncConflictPolicyError.InvalidHead> { SyncConflictHead(bad, v.user) }
        }
        val sent = bytes("Content sentinel")
        val request = SyncConflictIntent(v.personal, SyncOperation.PUT, 1, v.userScope, "a.md", sent, sent, 0)
        val snapshot = sent.copyOf()
        sent.fill(0)
        request.sentBytes!!.fill(0)
        assertContentEquals(snapshot, request.sentBytes)
        assertEquals(SyncHash.of(snapshot), request.sentHash)
        val remote = SyncConflictHead(prompt("Remote sentinel"), v.user)
        remote.bytes.fill(0)
        assertContentEquals(bytes("Remote sentinel"), remote.bytes)
        for (value in listOf(request, remote, resolve(SyncHTTPClientError.Conflict(head("Remote sentinel"))), SyncConflictPolicyError.InvalidHead)) {
            assertFalse(value.toString().contains("sentinel"))
        }
    }

    @Test fun sameVersionReusesExactRenamedPrivateCopyButDifferentVersionAllocatesAnother() {
        val h = SyncJournalHarness()
        val local = put(h, "Version one")
        val first = copy(local, h)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(h.plan(listOf(first.edit))))
        val restarted = h.restart()
        val renamed = "Renamed elsewhere.md"
        restarted.local.prompts.move(first.edit.path, renamed)
        val existing = restarted.mutations.read(renamed)!!
        val candidate = SyncConflictCopyCandidate(v.userScope, existing)
        val reused = copy(local, restarted, v.device, listOf(renamed), listOf(candidate))
        assertEquals(SyncLibraryEdit.Kind.APPLY, reused.edit.kind)
        assertEquals(renamed, reused.edit.path)
        assertEquals(v.groupPrompt.rawValue, reused.edit.transition?.destination)
        val newer = put(restarted, "Version two")
        val next = copy(newer, restarted, v.device, listOf(first.edit.path), listOf(candidate))
        assertEquals(SyncLibraryEdit.Kind.RESCUE, next.edit.kind)
        assertTrue(next.edit.path.endsWith(" (2).md"))
        assertContentEquals(newer.bytes, next.edit.retainedBytes)
        for (scope in listOf(SyncScopeKey.User(v.otherUser), v.groupScope)) {
            assertEquals(SyncLibraryEdit.Kind.RESCUE, copy(local, restarted, v.device, candidates = listOf(SyncConflictCopyCandidate(scope, existing))).edit.kind)
        }
    }

    @Test fun copyOfMarkedCopyKeepsRootOriginAndNeverReusesItself() {
        val h = SyncJournalHarness()
        val first = copy(put(h, "Original losing version"), h)
        h.local.prompts.put(first.edit.bytes!!, "Renamed copy.md")
        val source = h.mutations.read("Renamed copy.md")!!
        val next = SyncConflictPolicy.copy(source, SyncPromptOrigin.ConflictOf(v.groupPrompt), v.user, device = "Device", at = date,
            freshID = v.device, occupiedPaths = listOf(source.path), existingCopies = listOf(SyncConflictCopyCandidate(v.userScope, source)), mutations = h.mutations)
        assertEquals(SyncLibraryEdit.Kind.RESCUE, next.edit.kind)
        assertEquals(origin, next.origin)
        assertEquals(origin, SyncConflictMetadata.origin(next.edit.bytes!!, "Copy.md"))
        val rescuedBytes = SyncConflictMetadata.settingOrigin(SyncPromptOrigin.Rescued, source.bytes, "Copy.md")
        h.local.prompts.put(rescuedBytes, "Rescued copy.md")
        assertEquals(SyncPromptOrigin.Rescued, copy(h.mutations.read("Rescued copy.md")!!, h, v.device).origin)
    }

    @Test fun equalBodiedRescuesFromDistinctSourcesCannotReuseLineage() {
        val h = SyncJournalHarness()
        val firstSource = put(h, "Same body", path = "Groups/Team/First.md")
        val first = SyncConflictPolicy.copy(firstSource, SyncPromptOrigin.Rescued, v.user, device = "Device", at = date,
            freshID = v.device, occupiedPaths = listOf(firstSource.path), mutations = h.mutations)
        h.local.prompts.put(first.edit.bytes!!, first.edit.path)
        val secondSource = put(h, "Same body", path = "Groups/Team/Second.md", id = v.groupPrompt)
        val second = SyncConflictPolicy.copy(secondSource, SyncPromptOrigin.Rescued, v.user, device = "Device", at = date,
            freshID = v.otherUser, occupiedPaths = listOf(first.edit.path), existingCopies = listOf(SyncConflictCopyCandidate(v.userScope, h.mutations.read(first.edit.path)!!)), mutations = h.mutations)
        assertEquals(SyncLibraryEdit.Kind.RESCUE, second.edit.kind)
        assertNotEquals(first.edit.path, second.edit.path)
        assertContentEquals(secondSource.bytes, second.edit.retainedBytes)
    }

    @Test fun batchExcludesEveryLosingOrRemovedCandidateAndReservesSameMinuteNames() {
        val h = SyncJournalHarness(seed = false)
        val first = put(h, "Losing version")
        val oldCopy = copy(first, h)
        h.local.prompts.put(oldCopy.edit.bytes!!, "other/a.md")
        val second = h.mutations.read("other/a.md")!!
        val old = SyncState(h.binding, v.uuid, mapOf(v.userScope to "old"), prompts = mapOf(
            v.personalID to SyncPromptState(v.userScope, "a.md", 1, SyncHash.of(bytes("Base"))),
            v.groupID to SyncPromptState(v.userScope, second.path, 1, second.hash, origin)))
        h.states.update(h.binding) { old }
        val plan = SyncReconciliationPlan(SyncReconciliationPlan.Mode.NORMAL, old, old.copy(cursors = mapOf(v.userScope to "new"), prompts = emptyMap()),
            listOf(SyncReconciliationOperation.Preserve(SyncReconciliationPreservation(v.personal, SyncReconciliationPreservation.Reason.DIRTY_REMOVAL, first, null)),
                SyncReconciliationOperation.Preserve(SyncReconciliationPreservation(v.groupPrompt, SyncReconciliationPreservation.Reason.DIRTY_REMOVAL, second, null))),
            setOf(first.path, second.path), setOf(v.personalID, v.groupID))
        val ids = listOf(v.device, v.otherUser).iterator()
        val copies = SyncConflictPolicy.copies(plan, "Device", date, { ids.next() }, listOf(SyncConflictCopyCandidate(v.userScope, second)), h.mutations)
        assertEquals(2, copies.size)
        assertTrue(copies.values.all { it.edit.kind == SyncLibraryEdit.Kind.RESCUE })
        assertTrue(copies.values.any { it.edit.path.endsWith(" (2).md") })
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(SyncReconciler.application(plan, h.mutations, copies)))
        assertEquals(2, h.local.prompts.listFiles().size)
        assertEquals("new", h.states.snapshot.value!!.cursors[v.userScope])
        val removedPlan = SyncReconciliationPlan(plan.mode, old, plan.nextState, listOf(plan.operations.first(), SyncReconciliationOperation.Remove(second)),
            plan.occupiedPaths, plan.localIdentities)
        val removed = SyncConflictPolicy.copies(removedPlan, "Device", date, { v.device }, listOf(SyncConflictCopyCandidate(v.userScope, second)), h.mutations)
        assertEquals(SyncLibraryEdit.Kind.RESCUE, removed.getValue(first.path).edit.kind)
    }

    @Test fun incomingServerConflictShapedPathCannotBeAllocatedToALocalCopy() {
        val h = ReconciliationHarness()
        h.baseline(h.record())
        val local = h.put("Losing")
        val incoming = SyncNaming.conflict(local.path, null, "Device", date, emptyList())
        h.collected(h.scope(items = listOf(h.upsert(10, rev = 2), h.upsert(11, v.groupPrompt, incoming)))).use { pull ->
            val plan = h.plan(pull)
            val copies = SyncConflictPolicy.copies(plan, "Device", date, { v.device }, mutations = h.mutations)
            assertNotEquals(incoming, copies.getValue(local.path).edit.path)
            assertEquals(SyncApplyOutcome.Committed, h.apply(plan, copies))
            assertContentEquals(h.bytes("Server", v.groupPrompt), h.files.read(incoming))
        }
    }

    @Test fun reusedCopyIsCheckedDurablyBeforeSourceAndRaceLeavesBothVersionsIntact() {
        for (race in listOf(false, true)) {
            val h = ReconciliationHarness()
            val local = h.put("Losing local bytes")
            val first = copy(local, h.rig)
            h.files.put(first.edit.bytes!!, "Renamed copy.md")
            val existing = h.mutations.read("Renamed copy.md")!!
            h.baseline(h.record(), h.record(v.groupPrompt, existing.path, bytes = existing.bytes, rev = 4))
            h.collected(h.scope(items = listOf(h.upsert(10, rev = 2)))).use { pull ->
                val plan = h.plan(pull)
                val copies = SyncConflictPolicy.copies(plan, "Device", date, { v.device }, listOf(SyncConflictCopyCandidate(v.userScope, existing)), h.mutations)
                assertEquals(SyncLibraryEdit.Kind.APPLY, copies.getValue(local.path).edit.kind)
                val application = SyncReconciler.application(plan, h.mutations, copies)
                if (race) {
                    val edited = bytes("Edited preserved copy", v.groupPrompt)
                    h.files.put(edited, existing.path)
                    assertIs<SyncApplyOutcome.ReplanAsConflict>(h.rig.journal.apply(application))
                    assertContentEquals(local.bytes, h.files.read(local.path))
                    assertContentEquals(edited, h.files.read(existing.path))
                    assertEquals("old personal cursor", h.states.snapshot.value!!.cursors[v.userScope])
                } else {
                    assertEquals(SyncApplyOutcome.Committed, h.rig.journal.apply(application))
                    assertContentEquals(h.bytes("Server"), h.files.read(local.path))
                    assertContentEquals(existing.bytes, h.files.read(existing.path))
                    assertEquals(4, h.states.snapshot.value!!.prompts.getValue(v.groupID).rev)
                    assertTrue(h.retained().any { it.contentEquals(local.bytes) })
                }
            }
        }
    }

    @Test fun batchUsesRecordedGroupFolderAndRestoreMissingIsRescued() {
        val h = ReconciliationHarness()
        h.baseline(h.record(scope = v.groupScope))
        val local = h.put("Losing", "Groups/Team/a.md")
        h.collected(h.scope(), h.scope(v.groupScope, items = listOf(h.upsert(10, rev = 2, bytes = h.groupBytes("Server"))))).use { pull ->
            val copies = SyncConflictPolicy.copies(h.plan(pull), "Device", date, { v.device }, mutations = h.mutations)
            assertTrue(copies.getValue(local.path).edit.path.startsWith("Conflicts/Team/"))
        }
        h.collected(h.scope(mode = Mode.SNAPSHOT, head = 0), h.scope(v.groupScope, Mode.SNAPSHOT, head = 0), database = ReconciliationHarness.restored).use { pull ->
            val copies = SyncConflictPolicy.copies(h.plan(pull), "Device", date, { v.device }, mutations = h.mutations)
            assertEquals(SyncPromptOrigin.Rescued, copies.getValue(local.path).origin)
            assertTrue(copies.getValue(local.path).edit.path.startsWith("Conflicts/rescued-"))
        }
    }

    @Test fun forensicFutureAndMalformedCopiesKeepRawBytesWithoutInjectingText() {
        for (raw in listOf(byteArrayOf(-1, 0, -2), "---\nformat: 2\n---\nFuture".encodeToByteArray(), "---\ntitle: [\n---\nMalformed".encodeToByteArray(),
            bytes("Body", extra = "x-monkeyspaw-rescued: 'true'\n"))) {
            val h = SyncJournalHarness()
            h.local.prompts.put(raw, "Groups/Team/a.md")
            val local = h.mutations.read("Groups/Team/a.md")!!
            val copy = SyncConflictPolicy.copy(local, SyncPromptOrigin.Rescued, v.user, device = "Device", at = date,
                freshID = v.groupPrompt, occupiedPaths = listOf(local.path), mutations = h.mutations)
            assertContentEquals(raw, copy.edit.bytes)
            assertContentEquals(raw, copy.edit.retainedBytes)
            assertNotNull(copy.edit.heldIssue)
            assertNull(copy.edit.copyID)
            assertEquals(SyncApplyOutcome.Committed, h.journal.apply(h.plan(listOf(copy.edit))))
            assertContentEquals(raw, h.local.prompts.read(copy.edit.path))
        }
    }

    @Test fun failedCopyFlushReplaysTheChosenIDAndDestinationTwiceWithoutTrashingWinner() {
        val h = ReconciliationHarness()
        h.baseline(h.record())
        val local = h.put("Losing\r\n")
        h.collected(h.scope(items = listOf(h.upsert(10, path = "Moved.md", rev = 2)))).use { pull ->
            val plan = h.plan(pull)
            var calls = 0
            val copies = SyncConflictPolicy.copies(plan, "Device", date, { calls++; v.device }, mutations = h.mutations)
            val copy = copies.getValue(local.path)
            h.rig.libraryOperations.onOperation = { call ->
                if (call == "publish-file-flush:${copy.edit.path}") h.rig.libraryOperations.failAt = h.rig.libraryOperations.calls.size
            }
            assertFails { h.apply(plan, copies) }
            assertContentEquals(local.bytes, h.files.read(local.path))
            assertEquals(plan.expectedState, h.states.snapshot.value)
            h.rig.libraryOperations.failAt = null
            h.rig.libraryOperations.onOperation = null
            val restarted = h.rig.restart()
            assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
            val files = h.files.bytesSnapshot()
            assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
            assertEquals(files, h.files.bytesSnapshot())
            assertEquals(1, calls)
            assertEquals(v.device, PromptCodec.parseFile(h.files.read(copy.edit.path), "Copy.md").frontMatter.id)
            assertContentEquals(h.bytes("Server"), h.files.read("Moved.md"))
            assertTrue(h.retained().any { it.contentEquals(local.bytes) })
        }
    }

    private fun bytes(body: String, id: ULID = v.personal, extra: String = ""): ByteArray =
        "---\nid: '${id.rawValue}'\ntitle: Exact\n$extra---\n$body".encodeToByteArray()
    private fun sent(body: String, id: ULID, scope: SyncScopeKey): ByteArray = bytes(body, id).let {
        if (scope is SyncScopeKey.Group) CanonicalForm.group(it, "a.md").bytes else it
    }
    private fun intent(operation: SyncOperation = SyncOperation.PUT, base: Long = 1, scope: SyncScopeKey = v.userScope,
                       path: String = "a.md", body: String = "Sent", access: Long = 0): SyncConflictIntent =
        SyncConflictIntent(v.personal, operation, base, scope, path, if (operation == SyncOperation.DELETE) null else sent(body, v.personal, scope), bytes(body), access)
    private fun wire(scope: SyncScopeKey): PromptScope = if (scope is SyncScopeKey.User) PromptScope.User else PromptScope.Group(scope.id.rawValue)
    private fun head(body: String, rev: Long = 2, scope: SyncScopeKey = v.userScope, path: String = "a.md"): ConflictHead =
        ConflictHead(rev, wire(scope), path, sent(body, v.personal, scope).decodeToString())
    private fun prompt(body: String, id: ULID = v.personal, scope: SyncScopeKey = v.userScope, path: String = "a.md"): Prompt =
        Prompt(id.rawValue, 2, wire(scope), path, sent(body, id, scope).decodeToString())
    private fun put(h: SyncJournalHarness, body: String, path: String = "a.md", id: ULID = v.personal): SyncLibraryFile {
        h.local.prompts.put(bytes(body, id), path)
        return h.mutations.read(path)!!
    }
    private fun resolve(error: SyncHTTPClientError, request: SyncConflictIntent = intent(), local: SyncLibraryFile? = null,
                        recorded: SyncPromptState? = null, accessible: Prompt? = null, occupied: List<String> = emptyList()): SyncConflictOutcome? =
        SyncConflictPolicy.resolve(error, request, v.user, local, recorded, accessible, occupied)
    private fun copy(file: SyncLibraryFile, h: SyncJournalHarness, fresh: ULID = v.groupPrompt, occupied: List<String> = emptyList(),
                     candidates: List<SyncConflictCopyCandidate> = emptyList()): SyncReconciliationCopy =
        SyncConflictPolicy.copy(file, origin, v.user, device = "Device", at = date, freshID = fresh,
            occupiedPaths = occupied, existingCopies = candidates, mutations = h.mutations)
}
