package ch.lkmc.monkeyspaw.core.sync

import ch.lkmc.monkeyspaw.core.domain.ULID
import ch.lkmc.monkeyspaw.core.domain.format.PromptCodec
import ch.lkmc.monkeyspaw.core.domain.library.PromptProvenance
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import java.time.Instant
import kotlin.test.*

class SyncAdoptionTest {
    private val v = SyncTestValues
    private val date = Instant.ofEpochSecond(1_791_925_200)

    @Test fun copiedIDInstallsVerbatimServerBytesAndFullHashWithoutUpload() {
        val h = ScanHarness()
        h.put(ScanHarness.bytes(extra = "# local comment\n"))
        val bytes = "---\r\n# server comment\r\nid: '${v.personal.rawValue}'\r\ntitle: Exact\r\n---\r\nBody\r\n".encodeToByteArray()
        val head = remote(h, bytes)
        val snapshot = h.scan().snapshot
        val decision = assertIs<SyncAdoptionDecision.Adopt>(SyncAdoption.match(head, snapshot, emptyMap()))
        val plan = application(decision, h, snapshot)
        assertNull(plan.nextState.databaseID)
        assertTrue(plan.nextState.cursors.isEmpty())
        assertContentEquals(bytes, plan.edits.single().bytes)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertContentEquals(bytes, h.files.read("a.md"))
        assertEquals(head.hash, h.states.snapshot.value!!.prompts[v.personalID]!!.canonicalHash)
        assertEquals(head.rev, h.states.snapshot.value!!.prompts[v.personalID]!!.rev)
        assertNull(h.scan().preparation)
        assertTrue(h.scan().changes.isEmpty())
    }

    @Test fun idlessAndAlternativeIDMigrateAllKeyedDataAndBoundProvenance() {
        for (id in listOf(null, v.groupPrompt)) {
            val h = ScanHarness()
            val bytes = ScanHarness.bytes(id = id, extra = "# copied\n")
            h.put(bytes)
            val source = PromptIdentity.at("a.md", id)
            h.rig.local.history.snapshot(bytes, source, date)
            h.rig.local.usage.recordUse(source)
            h.rig.local.values.record(source, mapOf("field" to "remembered"))
            val provenance = """{"version":1,"contentSHA256":"${SyncHash.of(bytes).rawValue}","origin":"llm","timestamp":"2026-10-14T01:02:03.000Z","providerHost":"example.test","model":"model","usage":null,"opaque":"kept"}"""
            h.rig.local.state.put(provenance, "history/${source.storageKey}/head.json")
            val head = remote(h)
            val snapshot = h.scan().snapshot
            val decision = assertIs<SyncAdoptionDecision.Adopt>(SyncAdoption.match(head, snapshot, emptyMap()))
            assertEquals(source, decision.local.identity)
            assertEquals(SyncApplyOutcome.Committed, h.journal.apply(application(decision, h, snapshot)))
            assertContentEquals(head.bytes, h.files.read("a.md"))
            assertEquals(1, h.rig.local.history.revisions(v.personalID).size)
            assertTrue(h.rig.local.history.revisions(source).isEmpty())
            assertEquals(1, h.rig.local.usage.useEvents(v.personalID).size)
            assertTrue(h.rig.local.usage.useEvents(source).isEmpty())
            assertEquals(mapOf("field" to "remembered"), h.rig.local.values.rememberedValues(v.personalID))
            assertTrue(h.rig.local.values.rememberedValues(source).isEmpty())
            val migrated = h.rig.local.state.text("history/${v.personalID.storageKey}/head.json")
            assertTrue(migrated.contains(head.hash.rawValue))
            assertEquals(PromptProvenance(Instant.parse("2026-10-14T01:02:03.000Z"), "example.test", "model", null),
                h.rig.local.library.provenance("a.md"))
            assertNull(h.states.snapshot.value!!.prompts[source])
            assertTrue(h.scan().changes.isEmpty())
        }
    }

    @Test fun idOnlyHeaderAdoptsPlainBodyWithoutChangingFrontMatterBoundary() {
        val h = ScanHarness()
        h.put("Plain body\r\n".encodeToByteArray())
        val head = remote(h, "---\nid: '${v.personal.rawValue}'\n---\nPlain body\r\n".encodeToByteArray())
        assertIs<SyncAdoptionDecision.Adopt>(SyncAdoption.match(head, h.scan().snapshot, emptyMap()))
        h.put("---\n---\n---\ntitle: Exact\n---\nBody\r\n".encodeToByteArray())
        assertIs<SyncAdoptionDecision.Clash>(SyncAdoption.match(remote(h), h.scan().snapshot, emptyMap()))
    }

    @Test fun differingIDMatchPreservesLocalWithFreshConflictCopyBeforeInstall() {
        val h = ScanHarness()
        val bytes = ScanHarness.bytes("Local edits\r\n")
        h.put(bytes)
        val head = remote(h, ScanHarness.bytes("Server edits\n"))
        val snapshot = h.scan().snapshot
        val decision = assertIs<SyncAdoptionDecision.Conflict>(SyncAdoption.match(head, snapshot, emptyMap()))
        val plan = application(decision, h, snapshot)
        assertEquals(listOf(SyncLibraryEdit.Kind.RESCUE, SyncLibraryEdit.Kind.ADOPT), plan.edits.map { it.kind })
        val copy = plan.edits[0]
        assertContentEquals(bytes, copy.retainedBytes)
        assertEquals(SyncPromptOrigin.ConflictOf(v.personal), copy.copyOrigin)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertContentEquals(head.bytes, h.files.read("a.md"))
        assertEquals("Local edits\r\n", PromptCodec.parseFile(h.files.read(copy.path), "copy.md").body)
        assertEquals(v.device, PromptCodec.parseFile(h.files.read(copy.path), "copy.md").frontMatter.id)
        assertEquals(SyncPromptOrigin.ConflictOf(v.personal), h.states.snapshot.value!!.prompts[PromptIdentity.Assigned(v.device)]!!.origin)
        assertNull(h.states.snapshot.value!!.databaseID)
    }

    @Test fun originalIDAcrossScopesWinsBeforeEqualTargetOccupant() {
        val h = ScanHarness()
        val groups = ScanHarness.groups()
        h.state(groups)
        h.put(ScanHarness.bytes("Original"), "Groups/Team/elsewhere.md")
        h.put(ScanHarness.bytes("Server", v.groupPrompt))
        val head = remote(h, ScanHarness.bytes("Server"))
        assertEquals("a.md", assertIs<SyncAdoptionDecision.Clash>(SyncAdoption.match(head, h.scan().snapshot, groups)).occupant.path)
        h.files.delete("a.md")
        val snapshot = h.scan().snapshot
        val decision = assertIs<SyncAdoptionDecision.Conflict>(SyncAdoption.match(head, snapshot, groups))
        assertEquals("Groups/Team/elsewhere.md", decision.local.path)
        val plan = application(decision, h, snapshot, groups)
        assertTrue(plan.edits[0].path.startsWith("Conflicts/Team/"))
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertNull(h.files.stamp("Groups/Team/elsewhere.md"))
        assertContentEquals(head.bytes, h.files.read("a.md"))
    }

    @Test fun alternativeIDRequiresScopePathAndEveryNeutralMetadataValue() {
        val h = ScanHarness()
        val groups = ScanHarness.groups()
        h.state(groups)
        h.put(ScanHarness.bytes(id = v.groupPrompt), "Groups/Team/a.md")
        h.put(ScanHarness.bytes(id = v.device), "elsewhere.md")
        assertEquals(SyncAdoptionDecision.Unmatched, SyncAdoption.match(remote(h), h.scan().snapshot, groups))
        h.files.delete("elsewhere.md")
        h.files.delete("Groups/Team/a.md")
        for (extra in listOf("favorite: true\n", "private: true\n", "x-extra: value\n", "description: ''\n")) {
            h.put(ScanHarness.bytes(id = v.groupPrompt, extra = extra))
            assertIs<SyncAdoptionDecision.Clash>(SyncAdoption.match(remote(h), h.scan().snapshot, groups))
        }
    }

    @Test fun caseFoldAdoptionMigratesAndRetiresDistinctSourceOnlyAfterPublication() {
        val h = ScanHarness()
        val bytes = ScanHarness.bytes(id = v.groupPrompt)
        h.put(bytes, "Straße.md")
        h.rig.local.values.record(v.groupID, mapOf("field" to "remembered"))
        val snapshot = h.scan().snapshot
        val head = remote(h, path = "STRASSE.md")
        val plan = application(SyncAdoption.match(head, snapshot, emptyMap()), h, snapshot)
        assertEquals(listOf(SyncLibraryEdit.Kind.ADOPT, SyncLibraryEdit.Kind.TRASH), plan.edits.map { it.kind })
        assertContentEquals(bytes, plan.edits[0].adoptingSource!!.bytes)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertNull(h.files.stamp("Straße.md"))
        assertContentEquals(head.bytes, h.files.read("STRASSE.md"))
        assertEquals(mapOf("field" to "remembered"), h.rig.local.values.rememberedValues(v.personalID))
        assertTrue(h.rig.libraryOperations.calls.indexOf("publish-install:STRASSE.md") < h.rig.libraryOperations.calls.indexOf("trash-unlink:Straße.md"))
    }

    @Test fun viewerGroupAdoptionLiftsTrueFalseAbsentAndWritesExactCanonicalBytesOnce() {
        for (favorite in listOf("favorite: true\n", "favorite: false\n", "")) {
            val h = ScanHarness()
            val groups = ScanHarness.groups(Role.VIEWER)
            val bytes = ScanHarness.bytes(id = v.groupPrompt, extra = favorite + "private: false\n")
            h.put(bytes, "Groups/Team/a.md")
            h.state(groups, mapOf(v.groupID to ScanHarness.record(bytes, v.groupScope, rev = 0)), mapOf(v.groupID to true))
            val head = remote(h, scope = v.groupScope, groups = groups)
            val snapshot = h.scan().snapshot
            val plan = application(SyncAdoption.match(head, snapshot, groups), h, snapshot, groups)
            h.files.writes.clear()
            assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
            assertEquals(listOf("Groups/Team/a.md"), h.files.writes)
            assertEquals(if (favorite == "favorite: false\n") null else true, h.states.snapshot.value!!.favorites[v.personalID])
            assertNull(h.states.snapshot.value!!.favorites[v.groupID])
            assertContentEquals(head.bytes, h.files.read("Groups/Team/a.md"))
            assertEquals(SyncFileMode.READ_ONLY, h.rig.libraryOperations.modes["Groups/Team/a.md"])
            assertTrue(h.scan().changes.isEmpty())
        }
    }

    @Test fun groupToPrivateIDAdoptionClearsGroupFavoriteWhilePreservingConflict() {
        val h = ScanHarness()
        val groups = ScanHarness.groups()
        val bytes = ScanHarness.bytes("Group edits")
        h.put(bytes, "Groups/Team/a.md")
        h.state(groups, mapOf(v.personalID to ScanHarness.record(bytes, v.groupScope)), mapOf(v.personalID to true))
        val snapshot = h.scan().snapshot
        val plan = application(SyncAdoption.match(remote(h), snapshot, groups), h, snapshot, groups)
        assertNull(plan.nextState.favorites[v.personalID])
        assertEquals(v.userScope, plan.nextState.prompts[v.personalID]!!.scope)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
    }

    @Test fun caseFoldAdoptionReplaysAfterUncertainPublicationWithoutNewNamesOrIDs() {
        val h = ScanHarness()
        h.put(ScanHarness.bytes(id = v.groupPrompt), "Straße.md")
        h.rig.local.values.record(v.groupID, mapOf("field" to "remembered"))
        val snapshot = h.scan().snapshot
        val head = remote(h, path = "STRASSE.md")
        val plan = application(SyncAdoption.match(head, snapshot, emptyMap()), h, snapshot)
        h.rig.libraryOperations.calls.clear()
        h.rig.libraryOperations.failAt = 3
        assertFailsWith<SyncFileOperationError> { h.journal.apply(plan) }
        assertNull(h.states.snapshot.value)
        h.rig.libraryOperations.failAt = null
        val restarted = ScanHarness(h.rig.restart())
        assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
        assertEquals(SyncApplyOutcome.Committed, restarted.journal.replay())
        assertContentEquals(head.bytes, restarted.files.read("STRASSE.md"))
        assertNull(restarted.files.stamp("Straße.md"))
        assertEquals(mapOf("field" to "remembered"), restarted.rig.local.values.rememberedValues(v.personalID))
        assertTrue(restarted.rig.local.values.rememberedValues(v.groupID).isEmpty())
    }

    @Test fun pathTakenRequiresBothSentAndFreshEqualityAndSameLiveLocation() {
        val h = ScanHarness()
        val sent = ScanHarness.bytes(id = v.groupPrompt)
        h.put(sent)
        val intent = SyncConflictIntent(v.groupPrompt, SyncOperation.PUT, 0, v.userScope, "a.md", sent, sent, 0)
        val head = remote(h)
        val existing = ExistingPrompt(v.personal.rawValue, head.rev, head.bytes.decodeToString())
        assertIs<SyncAdoptionDecision.Adopt>(SyncAdoption.pathTaken(existing, intent, h.scan().snapshot, emptyMap()))
        val latest = ScanHarness.bytes("Typed during HTTP", v.groupPrompt)
        h.put(latest)
        var snapshot = h.scan().snapshot
        val clash = SyncAdoption.pathTaken(existing, intent, snapshot, emptyMap())
        assertIs<SyncAdoptionDecision.Clash>(clash)
        assertFailsWith<SyncReconciliationError.RequiresPolicy> { application(clash, h, snapshot) }
        assertContentEquals(latest, h.files.read("a.md"))
        h.put()
        assertEquals(SyncAdoptionDecision.Replan, SyncAdoption.pathTaken(existing, intent, h.scan().snapshot, emptyMap()))
        h.put(sent, "moved.md")
        assertEquals(SyncAdoptionDecision.Replan, SyncAdoption.pathTaken(existing, intent, h.scan().snapshot, emptyMap()))
        // Fresh equality alone cannot acknowledge a different sent version.
        h.files.delete("moved.md")
        h.put(sent)
        val unequal = ScanHarness.bytes("Previously sent", v.groupPrompt)
        val differentIntent = SyncConflictIntent(v.groupPrompt, SyncOperation.PUT, 0, v.userScope, "a.md", unequal, unequal, 0)
        assertIs<SyncAdoptionDecision.Clash>(SyncAdoption.pathTaken(existing, differentIntent, h.scan().snapshot, emptyMap()))
    }

    @Test fun changedSourceOrOccupiedDestinationAfterPlanningRetainsBothVersions() {
        for (destinationRace in listOf(false, true)) {
            val h = ScanHarness()
            h.put(ScanHarness.bytes(id = v.groupPrompt), "Straße.md")
            val snapshot = h.scan().snapshot
            val head = remote(h, path = "STRASSE.md")
            val plan = application(SyncAdoption.match(head, snapshot, emptyMap()), h, snapshot)
            val latest = ScanHarness.bytes("Changed after planning", v.groupPrompt)
            h.put(latest, if (destinationRace) "STRASSE.md" else "Straße.md")
            assertIs<SyncApplyOutcome.ReplanAsConflict>(h.journal.apply(plan))
            assertContentEquals(latest, h.files.read(if (destinationRace) "STRASSE.md" else "Straße.md"))
            assertNull(h.states.snapshot.value)
            assertNotNull(h.journal.pending)
        }
    }

    @Test fun accountHoldsBlockIDIdlessAndAlternativeIDAdoptionAndForgedDecision() {
        for (id in listOf(v.personal, v.groupPrompt, null)) {
            val h = ScanHarness()
            val bytes = ScanHarness.bytes(id = id)
            h.put(bytes)
            val ownership = SyncLibraryBinding(h.binding.root, h.binding.account, holds = listOf(
                SyncHeldPrompt(PromptIdentity.at("a.md", id), "a.md", v.accountIdentity(userID = v.otherUser), SyncHash.of(bytes))))
            val snapshot = h.scan(ownership, ids = emptyList()).snapshot
            val head = remote(h)
            val decision = assertIs<SyncAdoptionDecision.Held>(SyncAdoption.match(head, snapshot, emptyMap()))
            assertEquals("a.md", decision.path)
            assertFailsWith<SyncReconciliationError.RequiresPolicy> { application(decision, h, snapshot) }
            assertFailsWith<SyncReconciliationError.RequiresPolicy> {
                application(SyncAdoptionDecision.Adopt(head, h.mutations.read("a.md")!!), h, snapshot)
            }
            assertContentEquals(bytes, h.files.read("a.md"))
            assertNull(h.states.snapshot.value)
        }
    }

    @Test fun rawFutureAndRetainedAccountRescuesAreHeldBeforeMatching() {
        for (bytes in listOf("---\ntitle: [\n---\nRaw".encodeToByteArray(), ScanHarness.bytes(extra = "format: 999\n"), byteArrayOf(-1))) {
            val h = ScanHarness()
            h.put(bytes)
            assertIs<SyncAdoptionDecision.Held>(SyncAdoption.match(remote(h), h.scan().snapshot, emptyMap()))
            assertContentEquals(bytes, h.files.read("a.md"))
        }
        val h = ScanHarness()
        h.put()
        val retained = SyncRetainedRescue(java.util.UUID.randomUUID(),
            v.binding(account = v.accountIdentity(userID = v.otherUser)), "old.md", "source.md", SyncHash.of(ScanHarness.bytes()),
            SyncIssueCode.LocalVisibility, SyncPromptOrigin.Rescued)
        val snapshot = h.scan(retained = listOf(retained), ids = emptyList()).snapshot
        assertIs<SyncAdoptionDecision.Held>(SyncAdoption.match(remote(h), snapshot, emptyMap()))
    }

    @Test fun orphanDuplicateUnavailableAndForeignScopeCannotAuthorizeAdoption() {
        val h = ScanHarness()
        h.put(path = "Groups/Unknown/a.md")
        h.put(ScanHarness.bytes(id = v.groupPrompt))
        assertFailsWith<SyncReconciliationError.RequiresPolicy> { SyncAdoption.match(remote(h), h.scan().snapshot, emptyMap()) }
        h.files.delete("Groups/Unknown/a.md")
        h.put(path = "z.md")
        h.put(path = "y.md")
        assertFailsWith<SyncReconciliationError.InvalidLocalSnapshot> {
            SyncAdoption.match(remote(h), SyncReconciliationSnapshot(h.binding, h.mutations.listedFiles()), emptyMap())
        }
        assertFailsWith<SyncReconciliationError.UnavailableLibrary> {
            SyncAdoption.match(remote(h), SyncReconciliationSnapshot(h.binding, emptyList(), SyncReconciliationSnapshot.Availability.UNAVAILABLE), emptyMap())
        }
        assertFailsWith<SyncError.BindingMismatch> { SyncAdoption.match(remote(h, scope = SyncScopeKey.User(v.otherUser)), h.scan().snapshot, emptyMap()) }
    }

    @Test fun acknowledgedAlternativeIDCannotBeSilentlyAdopted() {
        val h = ScanHarness()
        val bytes = ScanHarness.bytes(id = v.groupPrompt)
        h.put(bytes)
        h.state(prompts = mapOf(v.groupID to ScanHarness.record(bytes)))
        val snapshot = h.scan().snapshot
        val decision = assertIs<SyncAdoptionDecision.Adopt>(SyncAdoption.match(remote(h), snapshot, emptyMap()))
        assertFailsWith<SyncReconciliationError.RequiresPolicy> { application(decision, h, snapshot) }
    }

    @Test fun pathTakenFreshAccountHoldAndGroupScopeChangeRequirePreservationOrReplan() {
        val h = ScanHarness()
        val bytes = ScanHarness.bytes(id = v.groupPrompt)
        h.put(bytes)
        val intent = SyncConflictIntent(v.groupPrompt, SyncOperation.PUT, 0, v.userScope, "a.md", bytes, bytes, 0)
        val existing = ExistingPrompt(v.personal.rawValue, 7, ScanHarness.bytes().decodeToString())
        val owned = SyncLibraryBinding(h.binding.root, h.binding.account, holds = listOf(
            SyncHeldPrompt(v.groupID, "a.md", v.accountIdentity(userID = v.otherUser), SyncHash.of(bytes))))
        assertIs<SyncAdoptionDecision.Held>(SyncAdoption.pathTaken(existing, intent, h.scan(owned, ids = emptyList()).snapshot, emptyMap()))
        h.state(ScanHarness.groups())
        h.files.move("a.md", "Groups/Team/a.md")
        assertEquals(SyncAdoptionDecision.Replan, SyncAdoption.pathTaken(existing, intent, h.scan().snapshot, ScanHarness.groups()))
    }

    @Test fun remoteHashIDModeAndNonNfcPathAreValidatedBeforePublication() {
        val h = ScanHarness()
        h.put(ScanHarness.bytes(id = v.groupPrompt))
        val bytes = ScanHarness.bytes()
        val variants = listOf(
            SyncReconciliationRemote(v.personal, v.userScope, "a.md", "a.md", 7, bytes, v.hash, SyncFileMode.NORMAL),
            SyncReconciliationRemote(v.groupPrompt, v.userScope, "a.md", "a.md", 7, bytes, SyncHash.of(bytes), SyncFileMode.NORMAL),
            SyncReconciliationRemote(v.personal, v.userScope, "a.md", "a.md", 7, bytes, SyncHash.of(bytes), SyncFileMode.READ_ONLY),
            SyncReconciliationRemote(v.personal, v.userScope, "e\u0301.md", "e\u0301.md", 7, bytes, SyncHash.of(bytes), SyncFileMode.NORMAL))
        for (remote in variants) assertFailsWith<SyncReconciliationError.InvalidPull> { SyncAdoption.match(remote, h.scan().snapshot, emptyMap()) }
        assertNull(h.states.snapshot.value)
        assertNull(h.journal.pending)
    }

    @Test fun excludedRemotePathRecordsVisibilityWithoutAcknowledgementOrRetirement() {
        val h = ScanHarness()
        h.put()
        val old = h.state(prompts = mapOf(v.personalID to ScanHarness.record()))
        val head = remote(h, path = "_remote.md")
        assertIs<SyncAdoptionDecision.LocalVisibility>(SyncAdoption.match(head, h.scan().snapshot, emptyMap()))
        val plan = SyncAdoption.localVisibility(head, old, h.binding, emptyMap())
        assertTrue(plan.edits.isEmpty())
        assertEquals(old.cursors, plan.nextState.cursors)
        assertEquals(old.databaseID, plan.nextState.databaseID)
        assertEquals(old.prompts[v.personalID]!!.rev, plan.nextState.prompts[v.personalID]!!.rev)
        assertEquals(old.prompts[v.personalID]!!.canonicalHash, plan.nextState.prompts[v.personalID]!!.canonicalHash)
        assertEquals(SyncIssueCode.LocalVisibility, plan.nextState.prompts[v.personalID]!!.lastError!!.code)
        assertEquals(SyncApplyOutcome.Committed, h.journal.apply(plan))
        assertContentEquals(ScanHarness.bytes(), h.files.read("a.md"))
        assertNull(h.files.stamp("_remote.md"))
    }

    @Test fun adoptionRescanReconcilesSameCompletePullBeforeCursorCommit() {
        val h = ScanHarness()
        h.put(ScanHarness.bytes(id = v.groupPrompt, extra = "# copied\n"))
        val head = remote(h)
        val feeds = ReconciliationHarness(h.rig)
        feeds.collected(feeds.scope(mode = Mode.SNAPSHOT, head = 10, items = listOf(feeds.upsert(10, rev = head.rev, bytes = head.bytes)))).use { pull ->
            val snapshot = h.scan().snapshot
            val first = SyncReconciler.plan(pull, null, snapshot)
            assertIs<SyncReconciliationOperation.Adoption>(first.operations.single())
            assertEquals(SyncApplyOutcome.Committed, h.journal.apply(application(SyncAdoption.match(head, snapshot, emptyMap()), h, snapshot)))
            assertNull(h.states.snapshot.value!!.databaseID)
            assertTrue(h.states.snapshot.value!!.cursors.isEmpty())
            val scan = h.scan()
            val final = SyncReconciler.plan(pull, h.states.load(h.binding), scan.snapshot)
            assertTrue(final.operations.isEmpty())
            assertEquals(SyncApplyOutcome.Committed, SyncReconciler.apply(final, h.mutations, h.journal))
            assertEquals(pull.databaseID, h.states.snapshot.value!!.databaseID)
            assertEquals(pull.cursors, h.states.snapshot.value!!.cursors)
            assertTrue(h.scan().changes.isEmpty())
        }
    }

    @Test fun snapshotsPlansAndDecisionsOwnBytesCollectionsAndRedactContent() {
        val h = ScanHarness()
        val bytes = ScanHarness.bytes("sensitive-sentinel", v.groupPrompt)
        h.put(bytes)
        val snapshot = h.scan().snapshot
        val head = remote(h, ScanHarness.bytes("sensitive-sentinel"))
        val decision = SyncAdoption.match(head, snapshot, emptyMap())
        val plan = application(decision, h, snapshot)
        head.bytes.fill(0)
        plan.edits.single().bytes!!.fill(0)
        assertTrue(head.bytes.decodeToString().contains("sensitive-sentinel"))
        assertContentEquals(head.bytes, plan.edits.single().bytes)
        assertFailsWith<UnsupportedOperationException> { (plan.edits as MutableList).clear() }
        val scan = h.scan()
        assertFailsWith<UnsupportedOperationException> { (scan.changes as MutableList).clear() }
        assertFailsWith<UnsupportedOperationException> { (scan.issues as MutableMap).clear() }
        assertFalse(listOf(snapshot, head, decision, plan, scan).toString().contains("sensitive-sentinel"))
    }

    @Test fun exactCaseAliasAdoptionPublishesOnceMigratesOriginalKeyAndNeverTrashesAlias() {
        for (id in listOf(null, v.groupPrompt, v.personal)) for (uncertain in listOf(false, true)) {
            val store = AliasPromptStore()
            val operations = AliasFileOperations(store)
            val data = MemoryStore()
            val dataOperations = SyncMutationFiles(data)
            val library = LibraryService(store, data, TestClock(), TestEntropy())
            val mutations = SyncLibraryMutations(library, operations)
            val states = SyncStateStore(data, dataOperations)
            val binding = v.binding()
            val journal = SyncApplyJournal(data, dataOperations, mutations, states)
            val bytes = ScanHarness.bytes(id = id)
            store.write(bytes, "a.md")
            val source = PromptIdentity.at("a.md", id)
            library.values.record(source, mapOf("field" to "remembered"))
            val scan = SyncLocalScanner.scan(binding, null, availability = SyncReconciliationSnapshot.Availability.AVAILABLE,
                freshID = { v.device }, mutations = mutations)
            val remoteBytes = ScanHarness.bytes()
            val head = SyncReconciliationRemote(v.personal, v.userScope, "A.md", "A.md", 7, remoteBytes, SyncHash.of(remoteBytes), SyncFileMode.NORMAL)
            val decision = assertIs<SyncAdoptionDecision.Adopt>(SyncAdoption.match(head, scan.snapshot, emptyMap()))
            val plan = SyncAdoption.application(decision, null, scan.snapshot, emptyMap(), "Device", date, { v.device }, mutations)
            assertEquals(1, plan.edits.size)
            assertEquals("a.md", plan.edits.single().adoptingSource?.path)
            assertEquals(source.storageKey, plan.edits.single().transition?.source)
            operations.failAfterPublish = uncertain
            if (uncertain) {
                assertFailsWith<SyncFileOperationError> { journal.apply(plan) }
                assertNull(states.snapshot.value)
                val restartedLibrary = LibraryService(store, data, TestClock(), TestEntropy())
                val restartedStates = SyncStateStore(data, dataOperations)
                val replay = SyncApplyJournal(data, dataOperations, SyncLibraryMutations(restartedLibrary, operations), restartedStates)
                assertEquals(SyncApplyOutcome.Committed, replay.replay())
                assertEquals(SyncApplyOutcome.Committed, replay.replay())
                assertEquals(mapOf("field" to "remembered"), restartedLibrary.values.rememberedValues(v.personalID))
                assertEquals(head.hash, restartedStates.snapshot.value!!.prompts[v.personalID]!!.canonicalHash)
            } else {
                assertEquals(SyncApplyOutcome.Committed, journal.apply(plan))
                assertEquals(mapOf("field" to "remembered"), library.values.rememberedValues(v.personalID))
            }
            assertEquals(listOf("A.md"), store.listFiles().map { it.relativePath })
            assertContentEquals(remoteBytes, store.read("A.md"))
            assertEquals(listOf("A.md"), operations.publications)
            assertEquals(SyncFileMode.NORMAL, operations.modes["A.md"])
        }
    }

    @Test fun pathTakenRejectsUnpairedSurrogateWithFixedProtocolError() {
        val h = ScanHarness()
        val bytes = ScanHarness.bytes(id = v.groupPrompt)
        h.put(bytes)
        val intent = SyncConflictIntent(v.groupPrompt, SyncOperation.PUT, 0, v.userScope, "a.md", bytes, bytes, 0)
        val existing = ExistingPrompt(v.personal.rawValue, 7, "\uD800")
        assertFailsWith<SyncReconciliationError.InvalidPull> { SyncAdoption.pathTaken(existing, intent, h.scan().snapshot, emptyMap()) }
        assertContentEquals(bytes, h.files.read("a.md"))
        assertNull(h.states.snapshot.value)
    }

    private fun remote(h: ScanHarness, bytes: ByteArray = ScanHarness.bytes(), path: String = "a.md",
                       scope: SyncScopeKey = v.userScope, groups: Map<ULID, SyncGroupState> = emptyMap()): SyncReconciliationRemote {
        val stored = SyncLocalScanner.canonical(bytes, path, scope).bytes
        val mode = if (scope is SyncScopeKey.Group && groups[scope.id]?.role == Role.VIEWER) SyncFileMode.READ_ONLY else SyncFileMode.NORMAL
        return SyncReconciliationRemote(v.personal, scope, path, SyncLocalScanner.rooted(path, scope, groups), 7, stored, SyncHash.of(stored), mode)
    }

    private fun application(decision: SyncAdoptionDecision, h: ScanHarness, snapshot: SyncReconciliationSnapshot,
                            groups: Map<ULID, SyncGroupState> = emptyMap()): SyncApplyPlan =
        SyncAdoption.application(decision, h.states.load(h.binding), snapshot, groups, "Device", date, { v.device }, h.mutations)
}

/** Case-insensitive lookup with exact-spelling replacement, matching the Swift alias test port. */
private class AliasPromptStore : PromptStore {
    val files = MemoryStore()
    fun actual(path: String): String? = files.listFiles().firstOrNull { SyncNaming.pathKey(it.relativePath) == SyncNaming.pathKey(path) }?.relativePath
    override fun listFiles(): List<StoredFile> = files.listFiles()
    override fun stamp(path: String): FileStamp? = actual(path)?.let(files::stamp)
    override fun read(path: String): ByteArray = files.read(actual(path) ?: throw StoreError.NotFound)
    override fun write(bytes: ByteArray, path: String) {
        actual(path)?.takeIf { it != path }?.let(files::delete)
        files.write(bytes, path)
    }
    override fun create(bytes: ByteArray, path: String) {
        if (actual(path) != null) throw StoreError.AlreadyExists
        files.create(bytes, path)
    }
    override fun delete(path: String) { files.delete(actual(path) ?: throw StoreError.NotFound) }
    override fun move(source: String, destination: String) {
        if (actual(destination) != null) throw StoreError.AlreadyExists
        files.move(actual(source) ?: throw StoreError.NotFound, destination)
    }
}

private class AliasFileOperations(private val store: AliasPromptStore,
                                  private val base: SyncMutationFiles = SyncMutationFiles(store.files)) : SyncFileOperations by base {
    val publications = mutableListOf<String>()
    val modes get() = base.modes
    var failAfterPublish = false

    override fun publish(bytes: ByteArray, path: String, expecting: SyncFileExpectation, mode: SyncFileMode): SyncFilePublication {
        when (expecting) {
            SyncFileExpectation.Absent -> if (store.stamp(path) != null) throw SyncFileOperationError(SyncFileFailureCode.OCCUPIED)
            is SyncFileExpectation.Matching -> if (store.stamp(path) != expecting.stamp || !store.read(path).contentEquals(expecting.bytes)) {
                throw SyncFileOperationError(SyncFileFailureCode.CHANGED)
            }
        }
        val displaced = if (store.stamp(path) == null) null else store.read(path)
        store.write(bytes, path)
        publications.add(path)
        base.modes[path] = mode
        if (failAfterPublish) {
            failAfterPublish = false
            throw SyncFileOperationError(SyncFileFailureCode.DURABILITY_FAILED, SyncFileMutationEffect.APPLIED, displaced)
        }
        base.flushFile(path)
        base.flushDirectory(null)
        return SyncFilePublication(displaced)
    }

    override fun trash(path: String, expecting: SyncFileExpectation) { fail("A live alias must never be trashed") }
    override fun flushFile(path: String) = base.flushFile(store.actual(path) ?: throw StoreError.NotFound)
    override fun setMode(mode: SyncFileMode, path: String) = base.setMode(mode, store.actual(path) ?: throw StoreError.NotFound)
}
