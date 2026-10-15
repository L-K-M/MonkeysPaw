package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantError
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class LlmJsonStackTest {
    @Test fun serializationAtEnvelopeCapOnSmallStack() {
        // Class loading has its own stack cost; isolate the parser's nesting cost.
        for (mode in AssistantJsonMode.entries) {
            LlmJsonParser("""{"warm":["text",0,true,false,null]}""".toByteArray(), mode = mode)
                .parse().member("warm").array().first().string()
        }
        assertFailsWith<AssistantError.InvalidOutput> { LlmJsonParser("[".toByteArray()).parse() }
        val failure = AtomicReference<Throwable?>()
        // A dedicated 128 KiB worker exposes per-container recursion on the JVM.
        val worker = Thread(null, {
            try {
                val depth = Limits.assistantEnvelopeNestingCap - 1
                val document = "\uFEFF{\"error\":\"json_schema is not supported\",\"unused\":" +
                    "[".repeat(depth) + "0" + "]".repeat(depth) + "}"
                val value = LlmJsonParser(document.toByteArray(), mode = AssistantJsonMode.SERIALIZATION).parse()
                assertEquals("json_schema is not supported", value.member("error").string())
                var leaf = value.member("unused")
                repeat(depth) { leaf = leaf.array().single() }
                assertTrue(leaf is LlmJsonValue.Number)
                for (mode in AssistantJsonMode.entries) {
                    val cap = if (mode == AssistantJsonMode.OUTPUT) Limits.llmJSONNestingCap else Limits.assistantEnvelopeNestingCap
                    for ((opening, closing) in listOf("[" to "]", "{\"x\":" to "}")) {
                        val prefix = opening.repeat(cap - 1)
                        val suffix = closing.repeat(cap - 1)
                        for (end in listOf("[]", "{}", opening + "true" + closing, opening + "\"leaf\"" + closing)) {
                            LlmJsonParser((prefix + end + suffix).toByteArray(), mode = mode).parse()
                        }
                        for (end in listOf(opening + "[]" + closing, opening + "{}" + closing)) {
                            assertFailsWith<AssistantError.InvalidOutput> {
                                LlmJsonParser((prefix + end + suffix).toByteArray(), mode = mode).parse()
                            }
                        }
                        val complete = prefix + "null" + suffix
                        for (invalid in listOf(complete.dropLast(1), complete + "x", "[" + complete + ",]",
                            "{\"x\":" + complete + ",\"bad\":[1,]}")) {
                            assertFailsWith<AssistantError.InvalidOutput> {
                                LlmJsonParser(invalid.toByteArray(), mode = mode).parse()
                            }
                        }
                        if (mode == AssistantJsonMode.SERIALIZATION) {
                            val duplicate = "{\"x\":" + complete + ",\"x\":\"last\"}"
                            assertEquals("last", LlmJsonParser(duplicate.toByteArray(), mode = mode).parse().member("x").string())
                        }
                    }
                }
            } catch (error: Throwable) { failure.set(error) }
        }, "llm-json-small-stack", 128 * 1024L)
        worker.start()
        worker.join(10_000)
        assertFalse(worker.isAlive, "Small-stack worker did not finish")
        failure.get()?.let { throw it }
    }
}
