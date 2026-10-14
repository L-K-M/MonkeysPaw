package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.di.AppModule
import kotlinx.coroutines.*
import java.util.concurrent.Executors
import java.util.logging.Handler
import java.util.logging.LogRecord
import java.util.logging.Logger
import kotlin.test.*

internal class ApplicationScopeTest {
    @Test
    fun `application child failures are reported without secrets and siblings remain usable`() = runBlocking {
        val records = mutableListOf<LogRecord>()
        val uncaught = mutableListOf<Throwable>()
        val logger = Logger.getLogger("MonkeysPaw")
        val handler = object : Handler() {
            override fun publish(record: LogRecord) { records += record }
            override fun flush() = Unit
            override fun close() = Unit
        }
        val parentHandlers = logger.useParentHandlers
        logger.useParentHandlers = false
        logger.addHandler(handler)
        try {
            Executors.newSingleThreadExecutor { work ->
                Thread(work).apply { uncaughtExceptionHandler = Thread.UncaughtExceptionHandler { _, error -> uncaught += error } }
            }.asCoroutineDispatcher().use { worker ->
                val scope = AppModule.applicationScope(worker)
                try {
                    assertNotNull(scope.coroutineContext[CoroutineExceptionHandler])
                    val siblingStarted = CompletableDeferred<Unit>()
                    val releaseSibling = CompletableDeferred<Unit>()
                    val sibling = scope.async { siblingStarted.complete(Unit); releaseSibling.await(); 42 }
                    siblingStarted.await()
                    scope.launch { error("SECRET prompt and token") }.join()
                    scope.launch { throw AssertionError("SECRET field value") }.join()
                    releaseSibling.complete(Unit)
                    assertEquals(42, sibling.await())
                    assertEquals(7, scope.async { 7 }.await())
                    assertTrue(scope.isActive)
                    assertTrue(uncaught.isEmpty())
                    assertEquals(2, records.size)
                    for (record in records) {
                        assertEquals("Application background operation failed.", record.message)
                        assertNull(record.thrown)
                        assertNull(record.parameters)
                    }
                } finally { scope.coroutineContext.job.cancelAndJoin() }
            }
        } finally {
            logger.removeHandler(handler)
            logger.useParentHandlers = parentHandlers
        }
    }
}
