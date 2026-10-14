package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.sync.SyncError
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.SyncWorkPermit
import kotlinx.coroutines.Job
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.*

class SyncCapabilityTest {
    @Test fun capabilityBytesAreOwnedValuesAndDiagnosticsAreRedacted() {
        val input = byteArrayOf(1, 2, 3)
        val bytes = SyncBytes(input)
        val expected = SyncFileExpectation.Matching(FileStamp("private-token"), input)
        val result = SyncFilePublication(input)
        val error = SyncFileOperationError(SyncFileFailureCode.DURABILITY_FAILED, SyncFileMutationEffect.APPLIED, input)
        input.fill(0)
        bytes.copyBytes().fill(0)
        expected.bytes.fill(0)
        result.displacedBytes!!.fill(0)
        error.displacedBytes!!.fill(0)
        val original = byteArrayOf(1, 2, 3)
        assertEquals(SyncBytes(original), bytes)
        assertEquals(SyncBytes(original).hashCode(), bytes.hashCode())
        assertContentEquals(original, expected.bytes)
        assertContentEquals(original, result.displacedBytes)
        assertContentEquals(original, error.displacedBytes)
        assertEquals(SyncFileMutationEffect.APPLIED, error.effect)
        assertNull(error.cause)
        for (value in listOf(bytes, expected, result, error, expected.stamp)) {
            assertFalse(value.toString().contains("private-token"))
            assertFalse(value.toString().contains("[1, 2, 3]"))
        }
        assertEquals("readOnly", SyncFileMode.READ_ONLY.rawValue)
        assertEquals("normal", SyncFileMode.NORMAL.rawValue)
    }

    @Test fun journalStampsRoundTripOpaqueTokensWithinAnIndependentBound() {
        val token = "é".repeat(Limits.syncStampMaxBytes / 2)
        val stamp = FileStamp.fromJournalToken(token)
        assertEquals(FileStamp(token), stamp)
        assertEquals(token, stamp.journalToken())
        for (bad in listOf("", token + "a", "\ud800")) {
            assertFailsWith<SyncFileOperationError> { FileStamp.fromJournalToken(bad) }
            assertFailsWith<SyncFileOperationError> { FileStamp(bad).journalToken() }
        }
    }

    @Test fun retirementRejectsNewWorkButAdmittedDurableWorkCompletes() {
        val job = Job()
        val permit = SyncWorkPermit(SyncTestValues.binding(), 7, job)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val worker = Executors.newSingleThreadExecutor()
        try {
            val completion = worker.submit<String> {
                permit.mutate {
                    entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS))
                    "files-state-journal-deletion-durable"
                }
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            assertFalse(permit.revoke())
            job.cancel()
            assertFalse(permit.isDrained)
            assertFailsWith<CancellationException> { permit.check() }
            assertFailsWith<CancellationException> { permit.mutate { fail("retired admission") } }
            release.countDown()
            assertEquals("files-state-journal-deletion-durable", completion.get(5, TimeUnit.SECONDS))
            assertTrue(permit.isDrained)
            assertTrue(permit.revoke())
        } finally { release.countDown(); worker.shutdownNow() }
    }

    @Test fun permitChecksBindingCancellationAndReleasesFailedAdmissions() {
        val permit = SyncWorkPermit(SyncTestValues.binding(), 1)
        permit.validate(SyncTestValues.binding())
        assertFailsWith<SyncError.BindingMismatch> { permit.validate(SyncTestValues.binding("/other")) }
        assertFailsWith<StoreError.IOFailure> { permit.mutate { throw StoreError.IOFailure } }
        assertTrue(permit.isDrained)
        assertEquals(3, permit.mutate { 3 })
        val job = Job().also { it.cancel() }
        assertFailsWith<CancellationException> { SyncWorkPermit(SyncTestValues.binding(), 2, job).mutate { fail() } }
        assertFailsWith<SyncError.InvalidState> { SyncWorkPermit(SyncTestValues.binding(), -1) }
        Thread.currentThread().interrupt()
        try { assertFailsWith<CancellationException> { permit.check() } }
        finally { Thread.interrupted() }
    }
}
