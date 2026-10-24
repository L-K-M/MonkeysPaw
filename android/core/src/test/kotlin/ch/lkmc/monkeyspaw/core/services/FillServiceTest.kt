package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.format.*
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.ports.*
import java.time.Instant
import java.time.ZoneOffset
import kotlin.test.*

class FillServiceTest {
    @Test fun oversizedExpansionNeverReachesClipboardDeliveryOrLearning() {
        val h = ServiceHarness()
        val entry = h.put("{{f}}".repeat(2049))
        val values = mapOf("f" to "a".repeat(1024))
        val before = h.state.bytesSnapshot()
        h.clipboard.text = "prior clipboard"
        assertEquals(PromptRenderError.OutputTooLarge,
            assertFailsWith<PromptRenderError> { h.fill.copy(entry.document, values, PromptBuiltinValues()) })
        for (mode in DeliveryMode.entries) {
            assertEquals(PromptRenderError.OutputTooLarge,
                assertFailsWith<PromptRenderError> {
                    h.fill.deliver(entry.document, values, PromptBuiltinValues(), mode,
                        TextDelivery { _, _ -> fail("Oversized output must not reach delivery") })
                })
        }
        assertEquals("prior clipboard", h.clipboard.text)
        assertEquals(0, h.clipboard.reads)
        assertEquals(before, h.state.bytesSnapshot())
        assertEquals(FillPreview.Blocked(PromptRenderError.OutputTooLarge, entry.document.issues),
            h.fill.preview(entry.document, values, PromptBuiltinValues()))
    }

    @Test fun everyModeDeliversTheSameLiteralRenderAndDoesNotLearnAtTheEffect() {
        val h = ServiceHarness()
        val entry = h.put("{{f}}|{{clipboard}}|{{f}}")
        val before = h.state.bytesSnapshot()
        for (mode in DeliveryMode.entries) {
            var calls = 0
            val result = h.fill.deliver(entry.document, mapOf("f" to "{{raw}}\n"),
                PromptBuiltinValues(clipboard = "snapshot"), mode, TextDelivery { received, text ->
                    calls++
                    assertEquals(mode, received)
                    assertTrue(text == "{{raw}}\n|snapshot|{{raw}}\n")
                    assertEquals(before, h.state.bytesSnapshot())
                    TextDeliveryResult.ACCEPTED
                })
            assertEquals(TextDeliveryResult.ACCEPTED, result)
            assertEquals(1, calls)
        }
        assertEquals(0, h.clipboard.reads)
        assertEquals(before, h.state.bytesSnapshot())
    }

    @Test fun blockedRefusedStaleAndThrowingEndpointsNeverLearn() {
        val h = ServiceHarness()
        val entry = h.put("{{f}}")
        for (mode in DeliveryMode.entries) {
            assertFailsWith<PromptRenderError.MissingRequiredValue> {
                h.fill.deliver(entry.document, mapOf("f" to ""), PromptBuiltinValues(), mode,
                    TextDelivery { _, _ -> fail("Validation must precede the endpoint") })
            }
            for (result in listOf(TextDeliveryResult.REFUSED, TextDeliveryResult.STALE)) {
                assertEquals(result, h.fill.deliver(entry.document, mapOf("f" to "value"),
                    PromptBuiltinValues(), mode, TextDelivery { _, _ -> result }))
            }
            val failure = assertFailsWith<LibraryError.OperationFailed> {
                h.fill.deliver(entry.document, mapOf("f" to "value"), PromptBuiltinValues(), mode,
                    TextDelivery { _, _ -> throw IllegalStateException("private endpoint failure") })
            }
            assertNull(failure.cause)
        }
        assertTrue(h.state.bytesSnapshot().isEmpty())
    }

    @Test fun unusedBuiltinsNeverSampleTheClockZoneOrClipboard() {
        val h = ServiceHarness()
        val fill = FillService(h.library, h.clipboard) { fail("Unused zone must not be read") }
        var snapshots = 0
        fill.builtinSnapshot(h.draft("{{f}}")) { snapshots++; assertEquals(PromptBuiltinValues(), it) }
        fill.builtinSnapshot(h.draft("{{clipboard}}")) { snapshots++; assertEquals("", it.clipboard) }
        assertEquals(2, snapshots)
        assertEquals(0, h.clock.samples)
        assertEquals(1, h.clipboard.reads)
    }

    @Test fun ephemeralBookkeepingDoesNotReadOrWriteLearningState() {
        val h = ServiceHarness()
        val entry = h.put("{{f}}")
        h.state.fault = { _, _ -> fail("Ephemeral bookkeeping must not touch persistence") }
        assertTrue(h.fill.recordDelivery(entry, mapOf("f" to "value"), LearningPolicy.EPHEMERAL).isEmpty())
    }

    @Test fun normalBookkeepingRemembersEmptyPermittedValuesThenRecordsOneUseWithIndependentWarnings() {
        val h = ServiceHarness()
        val entry = h.put("---\nfields:\n  f:\n    optional: true\n  fresh:\n    remember: false\n---\n{{f}}/{{fresh}}")
        assertTrue(h.fill.recordDelivery(entry, mapOf("f" to "", "fresh" to "session"), LearningPolicy.NORMAL).isEmpty())
        assertTrue(h.values.rememberedValues(entry.identity) == mapOf("f" to ""))
        assertEquals(1, h.usage.useEvents(entry.identity).size)
        h.state.fault = { op, _ -> if (op == MemoryStore.Operation.PRIVATE_WRITE) StoreError.IOFailure else null }
        assertEquals(listOf(PersistenceWarning.REMEMBERED_VALUES_NOT_SAVED),
            h.fill.recordDelivery(entry, mapOf("f" to "later"), LearningPolicy.NORMAL))
        assertEquals(2, h.usage.useEvents(entry.identity).size)
        assertTrue(h.values.rememberedValues(entry.identity) == mapOf("f" to ""))
    }

    @Test fun copyWritesValidatedRawTextWithoutLearningOrAnExtraClipboardRead() {
        val h = ServiceHarness()
        val entry = h.put("{{f}} {{f}} {{clipboard}}")
        h.values.record(entry.identity, mapOf("f" to "prior"))
        h.usage.recordUse(entry.identity)
        val before = h.state.bytesSnapshot()
        val text = h.fill.copy(entry.document, mapOf("f" to "{{raw}}\n"), PromptBuiltinValues(clipboard = "snapshot"))
        assertEquals("{{raw}}\n {{raw}}\n snapshot", text)
        assertEquals(text, h.clipboard.text)
        assertEquals(0, h.clipboard.reads)
        assertEquals(before, h.state.bytesSnapshot())
    }

    @Test fun blockedAndFailedCopyTeachNothingAndPreserveTypedOrSanitizedErrors() {
        val h = ServiceHarness()
        val entry = h.put("{{f}}")
        h.values.record(entry.identity, mapOf("f" to "prior"))
        h.usage.recordUse(entry.identity)
        val before = h.state.bytesSnapshot()
        h.clipboard.text = "prior clipboard"
        assertFailsWith<PromptRenderError.MissingRequiredValue> { h.fill.copy(entry.document, mapOf("f" to ""), PromptBuiltinValues()) }
        assertEquals("prior clipboard", h.clipboard.text)
        h.clipboard.writeFailure = true
        assertFailsWith<StoreError.IOFailure> { h.fill.copy(entry.document, mapOf("f" to "typed"), PromptBuiltinValues()) }
        h.clipboard.writeFailure = false
        h.clipboard.writeError = IllegalStateException("private clipboard error body")
        val error = assertFailsWith<LibraryError.OperationFailed> { h.fill.copy(entry.document, mapOf("f" to "typed"), PromptBuiltinValues()) }
        assertNull(error.cause)
        assertEquals("prior clipboard", h.clipboard.text)
        assertEquals(before, h.state.bytesSnapshot())
    }

    @Test fun builtinsUseOneGregorianLocalSnapshotAndNeverReadUnusedClipboard() {
        val h = ServiceHarness(ZoneOffset.ofHours(-5))
        h.clock.date = Instant.EPOCH
        val entry = h.put("{{date}} {{time}}")
        val snapshots = mutableListOf<PromptBuiltinValues>()
        h.fill.builtinSnapshot(entry.document, snapshots::add)
        assertEquals(1, h.clock.samples)
        assertEquals(0, h.clipboard.reads)
        assertEquals(PromptBuiltinValues(date = "1969-12-31", time = "19:00"), snapshots.single())
        assertEquals("1969-12-31 19:00", h.fill.render(entry.document, emptyMap(), snapshots.single()))
        val east = ServiceHarness(ZoneOffset.ofHoursMinutes(5, 30))
        east.clock.date = Instant.EPOCH
        east.fill.builtinSnapshot(east.draft("{{time}}"), snapshots::add)
        assertEquals("05:30", snapshots.last().time)
    }

    @Test fun deferredClipboardReadRetainsTheOpeningClockAndZoneSample() {
        val h = ServiceHarness()
        h.clock.date = Instant.EPOCH
        val entry = h.put("{{clipboard}} {{date}} {{time}} {{clipboard}}")
        h.clipboard.deferred = true
        val snapshots = mutableListOf<PromptBuiltinValues>()
        h.fill.builtinSnapshot(entry.document, snapshots::add)
        assertEquals(1, h.clock.samples)
        assertEquals(1, h.clipboard.reads)
        assertTrue(snapshots.isEmpty())
        h.clock.date = Instant.ofEpochSecond(86400)
        h.clipboard.pending!!.invoke("{{raw}}\nprivate text")
        assertEquals(PromptBuiltinValues(clipboard = "{{raw}}\nprivate text", date = "1970-01-01", time = "00:00"), snapshots.single())
        assertEquals(1, h.clock.samples)
    }

    @Test fun nullEmptyAndFailedClipboardReadStillCompleteWithRenderableEmptyText() {
        for (failed in listOf(false, true)) {
            val h = ServiceHarness()
            val entry = h.put("A{{clipboard}}B")
            h.clipboard.readFailure = failed
            val snapshots = mutableListOf<PromptBuiltinValues>()
            h.fill.builtinSnapshot(entry.document, snapshots::add)
            assertEquals("AB", h.fill.render(entry.document, emptyMap(), snapshots.single()))
            assertEquals("", snapshots.single().clipboard)
        }
        val h = ServiceHarness()
        h.clipboard.text = ""
        val snapshots = mutableListOf<PromptBuiltinValues>()
        h.fill.builtinSnapshot(h.draft("{{clipboard}}"), snapshots::add)
        assertEquals("", snapshots.single().clipboard)
    }

    @Test fun interruptedClipboardCopyPreservesTheExceptionAndInterruptStatus() {
        val h = ServiceHarness()
        val interruption = InterruptedException()
        h.clipboard.writeError = interruption
        try {
            assertSame(interruption, assertFailsWith<InterruptedException> {
                h.fill.copy(h.draft("Body"), emptyMap(), PromptBuiltinValues())
            })
            assertTrue(Thread.currentThread().isInterrupted)
        } finally { Thread.interrupted() }
        assertTrue(h.state.bytesSnapshot().isEmpty())
    }

    @Test fun formPreservesBodyOrderMetadataRememberFlagsAndEmptyRememberedText() {
        val h = ServiceHarness()
        val entry = h.put("""
            ---
            fields:
              second:
                type: choice
                label: Language
                description: Pick a language.
                options: [Rust, Python]
                default: Rust
              first:
                type: multiline
                optional: true
                default: default text
              noMemory:
                default: fresh
                remember: false
            ---
            {{first}} {{second}} {{implicit}} {{noMemory}} {{first}}
        """.trimIndent())
        h.values.record(entry.identity, mapOf("first" to "", "second" to "Python", "noMemory" to "old"))
        val form = h.fill.form(entry)
        assertEquals(listOf("first", "second", "implicit", "noMemory"), form.fields.map { it.field.name })
        assertEquals(listOf("", "Python", "", "fresh"), form.fields.map { it.prefill })
        assertEquals(listOf(FieldKind.MULTILINE, FieldKind.CHOICE, FieldKind.TEXT, FieldKind.TEXT), form.fields.map { it.field.kind })
        assertEquals("Language", form.fields[1].field.label)
        assertEquals("Pick a language.", form.fields[1].field.description)
        assertEquals(listOf("Rust", "Python"), form.fields[1].field.options.map { it.value })
        assertTrue(form.fields[0].field.optional)
        assertTrue(form.canRender)
        assertFalse(form.isReadOnly)
        assertNull(form.warning)
        assertEquals(0, h.clipboard.reads)
        assertEquals(0, h.clock.samples)
    }

    @Test fun rejectedRememberedStateUsesDefaultsAndAWarningWithoutResetting() {
        val h = ServiceHarness()
        val entry = h.put("---\nfields:\n  f:\n    default: fallback\n---\n{{f}}")
        h.state.put("private corrupt state", "values.json")
        val form = h.fill.form(entry)
        assertEquals("fallback", form.fields.single().prefill)
        assertEquals(PersistenceWarning.REMEMBERED_VALUES_UNAVAILABLE, form.warning)
        assertEquals("private corrupt state", h.state.text("values.json"))
    }

    @Test fun previewPreservesTypedBlockingReasonsAndRawSinglePassValues() {
        val h = ServiceHarness()
        val required = h.draft("{{f}}")
        assertEquals(FillPreview.Blocked(PromptRenderError.MissingRequiredValue("f"), emptyList()), h.fill.preview(required, emptyMap(), PromptBuiltinValues()))
        val choice = h.draft("---\nfields:\n  c:\n    type: choice\n    options: [one, two]\n---\n{{c}}")
        assertEquals(FillPreview.Blocked(PromptRenderError.InvalidChoiceValue("c"), emptyList()), h.fill.preview(choice, mapOf("c" to "bad"), PromptBuiltinValues()))
        val broken = h.draft("---\ntitle: [bad\n---\nBody")
        assertEquals(FillPreview.Blocked(PromptRenderError.InvalidPrompt, broken.issues), h.fill.preview(broken, emptyMap(), PromptBuiltinValues()))
        val future = h.draft("---\nformat: 2\n---\nBody")
        assertEquals(FillPreview.Blocked(PromptRenderError.UnsupportedFormat(future.frontMatter.format), future.issues), h.fill.preview(future, emptyMap(), PromptBuiltinValues()))
        val builtin = h.draft("{{clipboard}}")
        assertEquals(FillPreview.Blocked(PromptRenderError.MissingBuiltin(BuiltinName.CLIPBOARD), emptyList()), h.fill.preview(builtin, emptyMap(), PromptBuiltinValues()))
        val raw = h.draft("{{f}} {{f}}")
        assertEquals(FillPreview.Rendered("{{raw}} {{raw}}"), h.fill.preview(raw, mapOf("f" to "{{raw}}"), PromptBuiltinValues()))
        assertFailsWith<PromptRenderError.MissingRequiredValue> { h.fill.render(raw, mapOf("f" to ""), PromptBuiltinValues()) }
        assertEquals(0, h.clipboard.reads)
        assertEquals(0, h.clock.samples)
        assertTrue(h.state.bytesSnapshot().isEmpty())
    }

    @Test fun explicitEmptyValuesDoNotFallBackAndOptionalEmptyChoicesRenderEmpty() {
        val h = ServiceHarness()
        val required = h.draft("---\nfields:\n  f:\n    default: fallback\n---\n{{f}}")
        assertEquals("fallback", h.fill.render(required, emptyMap(), PromptBuiltinValues()))
        assertFailsWith<PromptRenderError.MissingRequiredValue> { h.fill.render(required, mapOf("f" to ""), PromptBuiltinValues()) }
        val optional = h.draft("---\nfields:\n  f:\n    type: choice\n    options: [one, two]\n    default: one\n    optional: true\n---\n{{f}}")
        assertEquals("", h.fill.render(optional, mapOf("f" to ""), PromptBuiltinValues()))
        assertEquals("one", h.fill.render(optional, emptyMap(), PromptBuiltinValues()))
    }

    @Test fun learningIncludesOnlySuppliedRememberFieldsAndStoresEmptyVerbatim() {
        val h = ServiceHarness()
        val entry = h.put("---\nfields:\n  forget:\n    remember: false\n  empty:\n    optional: true\n  absent:\n    default: declared\n---\n{{keep}} {{forget}} {{empty}} {{absent}}")
        h.values.record(entry.identity, mapOf("previous" to "kept"))
        h.fill.rememberedOnDelivery(entry.identity, entry.document.effectiveFields,
            mapOf("keep" to "value", "forget" to "secret", "empty" to "", "extra" to "no"))
        assertEquals(mapOf("previous" to "kept", "keep" to "value", "empty" to ""), h.values.rememberedValues(entry.identity))
        assertTrue(h.state.isPrivate("values.json"))
        val nonRemembered = h.put("---\nfields:\n  f:\n    remember: false\n---\n{{f}}", "b.md")
        val before = h.state.bytesSnapshot()
        h.fill.rememberedOnDelivery(nonRemembered.identity, nonRemembered.document.effectiveFields, mapOf("f" to "ignored"))
        assertEquals(before, h.state.bytesSnapshot())
    }

    @Test fun preparingEditingPreviewingAndCancellingAFormTeachNothingEvenAfterLateSnapshot() {
        val h = ServiceHarness()
        val entry = h.put("{{f}} {{clipboard}} {{date}}")
        h.values.record(entry.identity, mapOf("f" to "prior"))
        h.usage.recordUse(entry.identity)
        val before = h.state.bytesSnapshot()
        h.clipboard.deferred = true
        val form = h.fill.form(entry)
        assertEquals("prior", form.fields.single().prefill)
        var snapshot: PromptBuiltinValues? = null
        h.fill.builtinSnapshot(entry.document) { snapshot = it }
        h.fill.preview(entry.document, mapOf("f" to "typed but cancelled"), PromptBuiltinValues())
        h.clipboard.pending!!.invoke("late clipboard")
        assertNotNull(snapshot)
        h.fill.render(entry.document, mapOf("f" to "typed but cancelled"), snapshot)
        assertEquals(before, h.state.bytesSnapshot())
    }

    @Test fun forgettingRestoresDefaultsRemovesStaleFieldsAndPreservesOtherPrompts() {
        val h = ServiceHarness()
        val first = h.put("---\nfields:\n  f:\n    default: fallback\n---\n{{f}}")
        val second = h.put("{{g}}", "b.md")
        h.values.record(first.identity, mapOf("f" to "", "stale" to "old"))
        h.values.record(second.identity, mapOf("g" to "kept"))
        h.fill.forgetValues(first.identity)
        assertEquals("fallback", h.fill.form(first).fields.single().prefill)
        assertEquals("kept", h.fill.form(second).fields.single().prefill)
        assertTrue(h.values.rememberedValues(first.identity).isEmpty())
        h.fill.forgetAllValues()
        assertEquals("", h.fill.form(second).fields.single().prefill)
        assertEquals(0, h.clipboard.reads)
        assertEquals(0, h.clock.samples)
    }

    @Test fun failedForgetKeepsRememberedStateAndCanBeRetried() {
        val h = ServiceHarness()
        val entry = h.put("{{f}}")
        h.values.record(entry.identity, mapOf("f" to "kept"))
        val before = h.state.bytesSnapshot()
        h.state.fault = { op, _ -> if (op == MemoryStore.Operation.PRIVATE_WRITE) StoreError.IOFailure else null }
        assertFailsWith<StoreError.IOFailure> { h.fill.forgetValues(entry.identity) }
        assertFailsWith<StoreError.IOFailure> { h.fill.forgetAllValues() }
        assertEquals(before, h.state.bytesSnapshot())
        h.state.fault = null
        assertEquals("kept", h.fill.form(entry).fields.single().prefill)
        h.fill.forgetValues(entry.identity)
        assertEquals("", h.fill.form(entry).fields.single().prefill)
        h.state.put("private corrupt text", "values.json")
        assertFailsWith<LibraryError.OperationFailed> { h.fill.forgetValues(entry.identity) }
        h.fill.forgetAllValues()
        assertNull(h.fill.form(entry).warning)
    }
}
