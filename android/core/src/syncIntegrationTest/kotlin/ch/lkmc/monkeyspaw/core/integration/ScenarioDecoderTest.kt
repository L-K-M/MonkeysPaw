package ch.lkmc.monkeyspaw.core.integration

import ch.lkmc.monkeyspaw.core.syncapi.*
import java.nio.file.Files
import java.nio.file.Path
import java.util.Comparator
import kotlin.test.*

internal fun <T> withPrivateTestRoot(prepare: (Path) -> Unit = ::privateDirectory, body: (Path) -> T): T {
    val root = Files.createTempDirectory("monkeyspaw-sync-test-")
    try { prepare(root); return body(root) }
    finally { Files.walk(root).use { stream -> stream.sorted(Comparator.reverseOrder()).forEach { Files.delete(it) } } }
}

class ScenarioDecoderTest {
    private val directory get() = Path.of(System.getProperty("monkeyspaw.fixtures"), "sync")
    private val source get() = Files.readAllBytes(directory.resolve("01-round-trip.json"))
    private fun changed(pointer: String, value: WireValue): ByteArray = WireJson.canonical(WireJson.parse(source).patching(mapOf(pointer to value)))

    @Test fun privateRootIsRemovedWhenDirectoryPreparationFails() {
        var allocated: Path? = null
        try {
            assertFailsWith<ScenarioFailure> {
                withPrivateTestRoot(prepare = { root ->
                    allocated = root
                    throw ScenarioFailure("injected directory preparation failure")
                }) { fail("body ran after failed preparation") }
            }
            assertFalse(Files.exists(assertNotNull(allocated)))
        } finally { allocated?.let(Files::deleteIfExists) }
    }

    @Test fun currentCorpusIsStructurallyDecodedWithoutClaimingExecution() {
        val (files, cases) = SyncScenarioCorpus.load(directory)
        assertTrue(files.size >= 24)
        assertEquals(cases.size, cases.map { it.id }.toSet().size)
        assertTrue(cases.any { it.id == "01-round-trip" })
        assertTrue(cases.any { it.steps.any { step -> step.action == "kill_client" } })
        println("Sync structural decode: ${files.size} files, ${cases.size} cases; execution belongs to ScenarioRunnerTest")
    }

    @Test fun schemaRequiresNumericOneAndClosedEnvelope() {
        for (value in listOf(wireBoolean(true), wireString("1"), wireLong(0), wireLong(2), WireValue.Null)) {
            assertFailsWith<ScenarioFailure> { ScenarioDecoder.decode(changed("/schema", value)) }
        }
        val value = WireJson.parse(source).obj()
        assertFailsWith<ScenarioFailure> { ScenarioDecoder.decode(WireJson.canonical(WireValue.ObjectValue(value + ("unused" to wireLong(1))))) }
        assertFailsWith<ScenarioFailure> { ScenarioDecoder.decode(changed("/cases", WireValue.ArrayValue(emptyList()))) }
    }

    @Test fun everyNumberIsAnExactInt64AndNeverABoolean() {
        val text = source.decodeToString()
        for (token in listOf("1.5", "9223372036854775808", "-9223372036854775809", "1e99")) {
            assertFailsWith<ScenarioFailure> { ScenarioDecoder.decode(text.replace("\"schema\": 1", "\"schema\": $token").encodeToByteArray()) }
        }
        assertEquals(1, ScenarioDecoder.decode(text.replace("\"schema\": 1", "\"schema\": 1.0").encodeToByteArray()).size)
        assertFailsWith<ScenarioFailure> { ScenarioDecoder.decode(changed("/cases/0/steps/4/expected/file_count", wireBoolean(true))) }
        assertFailsWith<ScenarioFailure> { ScenarioDecoder.decode(changed("/cases/0/steps/4/expected/file_count", wireLong(-1))) }
        assertEquals(1, ScenarioDecoder.decode(changed("/cases/0/steps/4/expected/file_count", wireLong(Long.MAX_VALUE))).size)
        assertFailsWith<ScenarioFailure> { ScenarioDecoder.decode(byteArrayOf(-1)) }
        assertFailsWith<ScenarioFailure> { ScenarioDecoder.decode("{\"schema\":01}".encodeToByteArray()) }
    }

    @Test fun utcSecondsRequireExactSpellingAndARealGregorianDate() {
        for (time in listOf("2026-10-14T00:00:00.000Z", "2026-10-14T00:00:00+00:00", "2026-02-30T00:00:00Z", "2026-10-14T00:00:60Z", "2026-10-14")) {
            assertFailsWith<ScenarioFailure> { ScenarioDecoder.decode(changed("/cases/0/now", wireString(time))) }
        }
        assertEquals("2026-10-14T00:00:00Z", ScenarioDecoder.decode(source).single().now.toString())
    }

    @Test fun participantsNamesSeedsAndPromptIdsAreStrict() {
        for ((pointer, value) in listOf(
            "/cases/0/servers" to WireValue.ArrayValue(emptyList()),
            "/cases/0/users/1" to wireString("alice"),
            "/cases/0/devices/1/name" to wireString("a"),
            "/cases/0/devices/0/name" to wireString("Upper"),
            "/cases/0/devices/0/entropy_seed" to wireLong(0),
            "/cases/0/devices/0/entropy_seed" to wireLong(0xffff_ffffL),
            "/cases/0/devices/1/entropy_seed" to wireLong(1),
            "/cases/0/prompts/p" to wireString("01arz3ndektsv4rrffq69g5faz"),
        )) assertFailsWith<ScenarioFailure> { ScenarioDecoder.decode(changed(pointer, value)) }
        val envelope = WireJson.parse(source).obj()
        val case = envelope.getValue("cases").array().single()
        assertFailsWith<ScenarioFailure> { ScenarioDecoder.decode(WireJson.canonical(WireValue.ObjectValue(envelope +
            ("cases" to WireValue.ArrayValue(listOf(case, case)))))) }
    }

    @Test fun actionsAndNestedCheckpointsRejectUnknownMissingAndMistypedMembers() {
        val write = WireJson.parse(source).at("/cases/0/steps/0").obj()
        for (fields in listOf(write + ("action" to wireString("future_action")), write + ("unused" to wireBoolean(true)), write - "content")) {
            assertFailsWith<ScenarioFailure> { ScenarioDecoder.decodeStep(WireValue.ObjectValue(fields)) }
        }
        val malformed = listOf(
            wireObject("files" to WireValue.ArrayValue(listOf(wireObject("path" to wireString("p.md"))))),
            wireObject("state" to WireValue.ArrayValue(listOf(wireObject("id" to wireString("p"), "scope" to wireString("s"), "path" to wireString("p.md"), "rev" to wireBoolean(true))))),
            wireObject("groups" to WireValue.ArrayValue(listOf(wireObject("id" to wireString("g"), "name" to wireString("n"), "folder" to wireString("f"), "role" to wireString("viewer"), "unused" to wireLong(1))))),
            wireObject("pages" to WireValue.ArrayValue(listOf(wireObject("item_count" to wireLong(1), "has_more" to wireBoolean(false),
                "contains" to WireValue.ArrayValue(listOf(wireObject("id" to wireString("i"), "scope" to wireString("s"), "kind" to wireString("upsert"), "unused" to wireLong(1)))))))),
            wireObject("requests" to WireValue.ArrayValue(emptyList())),
            wireObject("future_checkpoint" to wireLong(0)),
        )
        for (expected in malformed) assertFailsWith<ScenarioFailure> {
            ScenarioDecoder.decodeStep(wireObject("action" to wireString("expect"), "device" to wireString("a"), "expected" to expected))
        }
    }

    @Test fun hookFormsAndMaintenanceCountsStayClosed() {
        val write = WireJson.parse(source).at("/cases/0/steps/0")
        val advance = wireObject("action" to wireString("advance_server"), "device" to wireString("a"), "server" to wireString("main"), "seconds" to wireLong(1))
        fun hook(then: WireValue) = wireObject("action" to wireString("after_next_response"), "device" to wireString("a"),
            "method" to wireString("POST"), "path" to wireString("/api/v1/sync/pull"), "then" to then)
        ScenarioDecoder.decodeStep(hook(write))
        ScenarioDecoder.decodeStep(hook(WireValue.ArrayValue(listOf(advance))))
        for (then in listOf(advance, WireValue.ArrayValue(listOf(write)), WireValue.ArrayValue(emptyList()))) {
            assertFailsWith<ScenarioFailure> { ScenarioDecoder.decodeStep(hook(then)) }
        }
        assertFailsWith<ScenarioFailure> { ScenarioDecoder.decodeStep(advance.patching(mapOf("/seconds" to wireLong(0)))) }
    }
    @Test fun serverBindingsAndCrashExpectationsCannotBypassTheClosedLanguage() {
        for (action in listOf("advance_server", "retention", "server_expect", "backup")) {
            val scenario = SyncScenarioCorpus.load(directory).second.first { scenario -> scenario.steps.any { it.action == action } }
            val step = scenario.steps.first { it.action == action }
            val value = WireValue.ObjectValue(step.fields + mapOf("action" to wireString(action), "device" to wireString(step.device),
                "bind" to wireString("unused")))
            assertFailsWith<ScenarioFailure> { ScenarioDecoder.decodeStep(value) }
        }
        for (action in listOf("kill_client", "resume_client")) {
            val scenario = SyncScenarioCorpus.load(directory).second.first { scenario -> scenario.steps.any { it.action == action } }
            val step = scenario.steps.first { it.action == action }
            val value = WireValue.ObjectValue(step.fields + mapOf("action" to wireString(action), "device" to wireString(step.device),
                "expected" to wireObject("file_count" to wireLong(0))))
            assertFailsWith<ScenarioFailure> { ScenarioDecoder.decodeStep(value) }
        }
        val step = SyncScenarioCorpus.load(directory).second.flatMap { it.steps }.first { it.action == "collect" }
        assertFailsWith<ScenarioFailure> { ScenarioDecoder.decodeStep(WireValue.ObjectValue(step.fields + mapOf(
            "action" to wireString("collect"), "device" to wireString(step.device), "unused" to wireLong(1)))) }
    }

    @Test fun textExpansionUsesUtf8BytesAndAvoidsOverflow() {
        fun text(count: Long) = wireObject("action" to wireString("bind_text"), "device" to wireString("a"),
            "name" to wireString("large"), "unit" to wireString("🙂"), "count" to wireLong(count))
        ScenarioDecoder.decodeStep(text(65536))
        for (count in listOf(0L, 65537L, Long.MAX_VALUE)) assertFailsWith<ScenarioFailure> { ScenarioDecoder.decodeStep(text(count)) }
        assertFailsWith<ScenarioFailure> { ScenarioDecoder.decodeStep(text(1).patching(mapOf("/unit" to wireString("")))) }
    }

    @Test fun symbolicKeysBytesAndBindingFailuresMatchSwift() {
        val symbols = ScenarioSymbols()
        symbols.bind("user.main.alice", "01ARZ3NDEKTSV4RRFFQ69G5FAZ")
        symbols.bind("text.bytes", "e\u0301\r\n\uFEFF")
        assertContentEquals("e\u0301\r\n\uFEFF".encodeToByteArray(), symbols.expand("\${text.bytes}").encodeToByteArray())
        assertFalse(wireString("é") == wireString("e\u0301"))
        assertTrue(symbols.expand(wireObject("user:\${user.main.alice}" to wireString("\${text.bytes}"))).obj().containsKey("user:01ARZ3NDEKTSV4RRFFQ69G5FAZ"))
        symbols.bind("text.bytes", "e\u0301\r\n\uFEFF")
        assertFailsWith<ScenarioFailure> { symbols.bind("text.bytes", "changed") }
        for (reference in listOf("\${missing}", "\${unfinished")) assertFailsWith<ScenarioFailure> { symbols.expand(reference) }
        symbols.bind("recursive", "\${text.bytes}")
        assertFailsWith<ScenarioFailure> { symbols.expand("\${recursive}") }
        symbols.bind("key", "same")
        assertFailsWith<ScenarioFailure> { symbols.expand(wireObject("same" to wireLong(0), "\${key}" to wireLong(1))) }
    }

    @Test fun jsonPointersRequireExistingTargetsAndPreserveExactStrings() {
        val value = wireObject("a/b" to WireValue.ArrayValue(listOf(wireObject("~" to wireString("\r\n")))))
        assertEquals(wireString("\r\n"), value.at("/a~1b/0/~0"))
        assertEquals(wireString("é"), value.patching(mapOf("/a~1b/0/~0" to wireString("é"))).at("/a~1b/0/~0"))
        for (pointer in listOf("missing", "/missing", "/a~1b/-1", "/a~1b/1", "/a~1b/0/~0/next")) {
            assertFailsWith<ScenarioFailure> { value.at(pointer) }
        }
    }

    @Test fun entropyUsesTheSwiftSequenceAndPersistsAcrossReconstruction() {
        val entropy = ScenarioEntropy(1)
        assertContentEquals(byteArrayOf(0, 0, 0, 0, 0, 1, 0, 0, 0, 1), entropy.bytes(10))
        assertContentEquals(byteArrayOf(0, 0, 0, 2), entropy.bytes(4))
    }

    @Test fun corpusRejectsMissingOrphansDuplicatesVisibleNestingAndLinks() {
        fun copied(body: (Path) -> Unit) = withPrivateTestRoot { root ->
            Files.list(directory).use { stream -> stream.forEach { Files.copy(it, root.resolve(it.fileName)) } }
            body(root)
            assertFailsWith<ScenarioFailure> { SyncScenarioCorpus.load(root) }
        }
        copied { Files.delete(it.resolve("01-round-trip.json")) }
        copied { Files.createDirectory(it.resolve("nested")) }
        copied { Files.writeString(it.resolve("unexpected.txt"), "unconsumed") }
        copied { Files.createSymbolicLink(it.resolve("99-linked.json"), directory.resolve("01-round-trip.json")) }
        copied { Files.copy(directory.resolve("01-round-trip.json"), it.resolve("01-extra.json")) }
        copied { Files.write(it.resolve("01-round-trip.json"), changed("/cases/0/id", wireString("99-orphan"))) }
        withPrivateTestRoot { root ->
            val link = root.resolve("link")
            Files.createSymbolicLink(link, directory)
            assertFailsWith<ScenarioFailure> { SyncScenarioCorpus.load(link) }
        }
    }
}
