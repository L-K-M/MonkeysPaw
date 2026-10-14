package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.ports.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.StandardTestDispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.SocketEffect
import mockwebserver3.SocketHandler
import okhttp3.Dispatcher
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.Buffer
import okio.GzipSink
import okio.Socket
import okio.buffer
import java.io.IOException
import java.nio.file.Files
import java.security.KeyStore
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit.MILLISECONDS
import java.util.concurrent.TimeUnit.SECONDS
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.CoroutineContext
import kotlin.test.*

internal class OkHttpHttpTransportTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val dispatcher = Dispatcher()
    private val clock = MonotonicClock(System::nanoTime)
    private val transport = OkHttpHttpTransport(clock, scope, dispatcher)
    private val servers = mutableListOf<MockWebServer>()

    @AfterTest fun closeResources() {
        scope.cancel()
        dispatcher.cancelAll()
        servers.forEach { it.close() }
        dispatcher.executorService.shutdown()
    }

    @Test fun `request and bounded error response preserve bytes headers method and query`() = runBlocking {
        val server = server()
        server.enqueue(MockResponse.Builder().code(429).addHeader("X-Reply", "received")
            .addHeader("Retry-After", "2").body("provider detail").build())
        val request = request(server, method = HttpMethod.POST, path = "/v1/messages?after_id=one",
            headers = mapOf("Authorization" to "Bearer test-key", "Content-Type" to "application/json", "X-Text" to "café"),
            body = "{\"input\":\"hello\"}".encodeToByteArray())
        val response = transport.send(request)
        assertEquals(429, response.statusCode)
        assertEquals("received", response.headers["x-reply"])
        assertEquals("2", response.headers["retry-after"])
        assertTrue(response.headers.keys.all { it == it.lowercase() })
        assertContentEquals("provider detail".encodeToByteArray(), response.body)
        val observed = server.takeRequest(2, SECONDS)!!
        assertEquals("POST", observed.method)
        assertEquals("/v1/messages?after_id=one", observed.target)
        assertEquals("Bearer test-key", observed.headers["Authorization"])
        assertEquals("café", observed.headers["X-Text"])
        assertContentEquals(request.body, observed.body!!.toByteArray())
    }

    @Test fun `exact caps chunked and close delimited bodies succeed`() = runBlocking {
        val server = server()
        val responses = listOf(MockResponse.Builder().body("abcdefgh"),
            MockResponse.Builder().chunkedBody("abcdefgh", 3),
            MockResponse.Builder().body("abcdefgh").removeHeader("Content-Length").addHeader("Connection", "close")
                .onResponseEnd(SocketEffect.CloseSocket()))
        for (response in responses) {
            server.enqueue(response.build())
            assertContentEquals("abcdefgh".encodeToByteArray(), transport.send(request(server, cap = 8)).body)
        }
        val large = "a".repeat(Limits.responseCap + 1)
        server.enqueue(MockResponse.Builder().body(large).build())
        assertEquals(large.length, transport.send(request(server, cap = Limits.syncResponseCap)).bodyByteCount)
    }

    @Test fun `every 3xx with or without Location is refused without contacting target`() = runBlocking {
        val source = server()
        val target = server()
        for (method in listOf(HttpMethod.GET, HttpMethod.POST)) {
            for (status in listOf(300, 301, 302, 303, 304, 305, 306, 307, 308, 310, 399)) {
                for (location in listOf(null, target.url("/secret").toString(), "http://[invalid")) {
                    val response = MockResponse.Builder().code(status)
                    if (location != null) response.addHeader("Location", location)
                    source.enqueue(response.build())
                    assertEquals(HttpTransportError.RedirectRefused, errorOf { transport.send(request(source, method)) })
                }
            }
        }
        assertEquals(66, source.requestCount)
        assertEquals(0, target.requestCount)
    }

    @Test fun `authentication timeout service unavailable and misdirected responses never replay`() = runBlocking {
        val server = server()
        val responses = listOf(
            MockResponse.Builder().code(401).addHeader("WWW-Authenticate", "Basic realm=\"test\""),
            MockResponse.Builder().code(401).addHeader("WWW-Authenticate", "Digest realm=\"test\", nonce=\"nonce\""),
            MockResponse.Builder().code(401).addHeader("WWW-Authenticate", "NTLM"),
            MockResponse.Builder().code(401).addHeader("WWW-Authenticate", "Negotiate"),
            MockResponse.Builder().code(407).addHeader("Proxy-Authenticate", "Basic realm=\"test\""),
            MockResponse.Builder().code(408).addHeader("Retry-After", "0"),
            MockResponse.Builder().code(503).addHeader("Retry-After", "0"),
            MockResponse.Builder().code(503).addHeader("Retry-After", "999999999999999999999999"),
            MockResponse.Builder().code(421),
        ).map { it.body("bounded error").build() }
        var count = 0
        for ((method, body) in listOf(HttpMethod.GET to null, HttpMethod.POST to null, HttpMethod.POST to byteArrayOf(1, 2))) {
            for (response in responses) {
                server.enqueue(response)
                val actual = withTimeout(3000) { transport.send(request(server, method, body = body)) }
                assertEquals(response.code, actual.statusCode)
                assertEquals(response.headers["Retry-After"], actual.headers["retry-after"])
                assertContentEquals("bounded error".encodeToByteArray(), actual.body)
                assertEquals(++count, server.requestCount)
            }
        }
    }

    @Test fun `connection failures are body free and never replay GET or POST`() = runBlocking {
        for (method in listOf(HttpMethod.GET, HttpMethod.POST)) {
            val server = server()
            server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build())
            server.enqueue(MockResponse.Builder().body("unexpected retry").build())
            val error = errorOf { transport.send(request(server, method, headers = mapOf("x-api-key" to "sentinel-key"))) }
            assertEquals(HttpTransportError.NetworkFailure, error)
            assertNull(error.cause)
            assertFalse(error.stackTraceToString().contains("sentinel-key"))
            assertFalse(error.stackTraceToString().contains(server.url("/").toString()))
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun `coalesced HTTP2 GET 421 preserves the response without a fresh attempt`() = runBlocking {
        val certificate = HeldCertificate.Builder().commonName("localhost")
            .addSubjectAlternativeName("localhost").addSubjectAlternativeName("127.0.0.1").build()
        val certificates = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val server = MockWebServer().also { servers += it }
        server.useHttps(certificates.sslSocketFactory())
        server.start()
        server.enqueue(MockResponse.Builder().body("warm connection").build())
        server.enqueue(MockResponse.Builder().code(421).body("bounded misdirected response").build())
        server.enqueue(MockResponse.Builder().body("unexpected replay").build())

        // Give the JVM's ordinary trust manager a test trust anchor, with no driver TLS override.
        val trustStore = Files.createTempFile("monkeyspaw-l7-trust-", ".jks")
        val properties = listOf("javax.net.ssl.trustStore", "javax.net.ssl.trustStoreType", "javax.net.ssl.trustStorePassword")
        val original = properties.associateWith(System::getProperty)
        try {
            val password = "test-only".toCharArray()
            val store = KeyStore.getInstance("JKS").apply { load(null, password); setCertificateEntry("test", certificate.certificate) }
            Files.newOutputStream(trustStore).use { store.store(it, password) }
            System.setProperty(properties[0], trustStore.toString())
            System.setProperty(properties[1], "JKS")
            System.setProperty(properties[2], String(password))
            val driver = OkHttpHttpTransport(clock, scope, dispatcher)
            assertEquals(200, driver.send(request(url = "https://localhost:${server.port}/warm")).statusCode)
            val response = driver.send(request(url = "https://127.0.0.1:${server.port}/models"))
            assertEquals(421, response.statusCode)
            assertContentEquals("bounded misdirected response".encodeToByteArray(), response.body)
            val first = server.takeRequest(2, SECONDS)!!
            val second = server.takeRequest(2, SECONDS)!!
            assertEquals("HTTP/2", first.version)
            assertEquals("HTTP/2", second.version)
            assertEquals(first.connectionIndex, second.connectionIndex)
            assertEquals(2, server.requestCount)
        } finally {
            original.forEach { (name, value) -> if (value == null) System.clearProperty(name) else System.setProperty(name, value) }
            Files.deleteIfExists(trustStore)
        }
    }

    @Test fun `URL policy refuses LAN deceptive loopback credentials and unsafe paths before I O`() = runBlocking {
        val urls = listOf(
            "http://192.168.1.1/v1", "http://10.0.0.1", "http://server.local", "http://localhost.evil",
            "http://127.1", "http://127.00.0.1", "http://2130706433", "http://0x7f000001",
            "http://[::ffff:127.0.0.1]", "http://[::2]", "http://user:key@localhost",
            "https://user:key@example.com", "http://localhost/a/../b", "http://localhost/a%2fb",
            "http://localhost/a%5cb", "http://localhost\\@evil", "http://localhost/#fragment",
            "http://localhost/\u0000", "http://localhost:65536", "ftp://localhost/",
            "http://localhost/models?after_id=\uDB40\uDC01",
        )
        for (url in urls) {
            val error = errorOf { transport.send(request(url = url)) }
            assertTrue(error in listOf(HttpTransportError.InvalidURL, HttpTransportError.InsecureURL, HttpTransportError.CredentialsInURL))
        }
        val server = server()
        assertEquals(HttpTransportError.InvalidRequest, errorOf { transport.send(request(server, body = byteArrayOf())) })
        assertEquals(0, server.requestCount)
    }

    @Test fun `normalized localhost spelling uses the literal loopback policy`() = runBlocking {
        val server = server()
        server.enqueue(MockResponse.Builder().body("ok").build())
        val url = "HTTP://LOCALHOST.:${server.port}/v1/models"
        assertContentEquals("ok".encodeToByteArray(), transport.send(request(url = url)).body)
    }

    @Test fun `advertised oversize refuses headers while the body is withheld and closes receipt`() = runBlocking {
        for (length in listOf("65", "999999999999999999999999999")) {
            val closed = CountDownLatch(1)
            val server = server()
            server.enqueue(stalled(closed, length))
            assertEquals(HttpTransportError.ResponseTooLarge, errorOf { transport.send(request(server, cap = 64)) })
            assertTrue(closed.await(2, SECONDS))
        }
    }

    @Test fun `chunked oversize stops before final chunk and closes receipt`() = runBlocking {
        val closed = CountDownLatch(1)
        val server = server()
        server.enqueue(chunkedOversize(closed))
        assertEquals(HttpTransportError.ResponseTooLarge, errorOf { transport.send(request(server, cap = 64)) })
        assertTrue(closed.await(2, SECONDS))
    }

    @Test fun `decompressed body is capped independently of compressed Content Length`() = runBlocking {
        val server = server()
        val compressed = Buffer()
        GzipSink(compressed).buffer().use { it.writeUtf8("a".repeat(1025)) }
        assertTrue(compressed.size < 128)
        server.enqueue(MockResponse.Builder().body(compressed).addHeader("Content-Encoding", "gzip").build())
        assertEquals(HttpTransportError.ResponseTooLarge, errorOf { transport.send(request(server, cap = 128)) })
        val exact = Buffer()
        GzipSink(exact).buffer().use { it.writeUtf8("a".repeat(128)) }
        server.enqueue(MockResponse.Builder().body(exact).addHeader("Content-Encoding", "gzip").build())
        assertEquals(128, transport.send(request(server, cap = 128)).bodyByteCount)
    }

    @Test fun `absolute deadline interrupts a stalled body and closes receipt`() = runBlocking {
        val closed = CountDownLatch(1)
        val server = server()
        server.enqueue(stalled(closed))
        assertEquals(HttpTransportError.DeadlineExceeded, errorOf { transport.send(request(server, budgetMillis = 500)) })
        assertTrue(closed.await(2, SECONDS))
    }

    @Test fun `absolute deadline interrupts continuous bytes and closes receipt`() = runBlocking {
        val closed = CountDownLatch(1)
        val writes = AtomicInteger()
        val server = server()
        server.enqueue(MockResponse.Builder().addHeader("Transfer-Encoding", "chunked").removeHeader("Content-Length")
            .socketHandler(object : SocketHandler {
                override fun handle(socket: Socket) {
                    try {
                        val sink = socket.sink.buffer()
                        repeat(200) {
                            sink.writeUtf8("1\r\na\r\n").flush()
                            writes.incrementAndGet()
                            Thread.sleep(20)
                        }
                    } catch (_: IOException) { closed.countDown() }
                }
            }).build())
        assertEquals(HttpTransportError.DeadlineExceeded, errorOf { transport.send(request(server, budgetMillis = 500)) })
        assertTrue(writes.get() > 2)
        assertTrue(closed.await(2, SECONDS))
    }

    @Test fun `caller cancellation interrupts stalled receipt promptly`() = runBlocking {
        val closed = CountDownLatch(1)
        val server = server()
        server.enqueue(stalled(closed))
        val outcome = CompletableDeferred<HttpTransportError>()
        val job = launch { outcome.complete(errorOf { transport.send(request(server)) }) }
        withContext(Dispatchers.IO) { assertNotNull(server.takeRequest(2, SECONDS)) }
        job.cancel()
        assertEquals(HttpTransportError.Cancelled, withTimeout(2000) { outcome.await() })
        assertTrue(closed.await(2, SECONDS))
        job.join()
    }

    @Test fun `dispatcher queue consumes the same deadline and expired call never sends`() = runBlocking {
        dispatcher.maxRequests = 1
        dispatcher.maxRequestsPerHost = 1
        val closed = CountDownLatch(1)
        val blocker = server()
        val queued = server()
        // Hold headers so the first async OkHttp call continues to occupy its dispatcher slot.
        blocker.enqueue(stalled(closed).newBuilder().headersDelay(3, SECONDS).build())
        val firstOutcome = CompletableDeferred<HttpTransportError>()
        val first = launch { firstOutcome.complete(errorOf { transport.send(request(blocker)) }) }
        withContext(Dispatchers.IO) { assertNotNull(blocker.takeRequest(2, SECONDS)) }
        assertEquals(HttpTransportError.DeadlineExceeded, errorOf { transport.send(request(queued, budgetMillis = 300)) })
        assertEquals(0, queued.requestCount)
        first.cancel()
        assertEquals(HttpTransportError.Cancelled, firstOutcome.await())
        first.join()
        val idle = CountDownLatch(1)
        dispatcher.idleCallback = Runnable { idle.countDown() }
        if (dispatcher.runningCallsCount() != 0) assertTrue(idle.await(2, SECONDS))
        assertEquals(0, queued.requestCount)
    }

    @Test fun `IO queue and expired deadlines finish without dispatching network work`() = runBlocking {
        val io = StandardTestDispatcher()
        val waitingScope = CoroutineScope(SupervisorJob() + io)
        try {
            val driver = OkHttpHttpTransport(clock, waitingScope, dispatcher)
            val server = server()
            assertEquals(HttpTransportError.DeadlineExceeded, errorOf { driver.send(request(server, budgetMillis = 100)) })
            io.scheduler.runCurrent()
            assertEquals(HttpTransportError.DeadlineExceeded, errorOf { transport.send(request(server, budgetMillis = -1)) })
            assertEquals(0, server.requestCount)
        } finally { waitingScope.cancel() }
    }

    @Test fun `observed cap failure wins over cancellation before result dispatcher runs`() = runBlocking {
        for (advertised in listOf(true, false)) {
            val work = LinkedBlockingQueue<Runnable>()
            val ui = object : CoroutineDispatcher() {
                override fun dispatch(context: CoroutineContext, block: Runnable) { work.add(block) }
            }
            val closed = CountDownLatch(1)
            val server = server()
            server.enqueue(if (advertised) stalled(closed, "65") else chunkedOversize(closed))
            val outcome = CompletableDeferred<HttpTransportError>()
            val callerScope = CoroutineScope(SupervisorJob() + ui)
            val caller = callerScope.launch(start = CoroutineStart.UNDISPATCHED) {
                outcome.complete(errorOf { transport.send(request(server, cap = 64, budgetMillis = 500)) })
            }
            try {
                // Peer closure and queued completion follow the committed cap failure.
                assertTrue(closed.await(2, SECONDS))
                val resume = assertNotNull(work.poll(2, SECONDS))
                delay(550) // Resume only after the original deadline, with a later caller cancel.
                caller.cancel()
                resume.run()
                assertEquals(HttpTransportError.ResponseTooLarge, withTimeout(2000) { outcome.await() })
                caller.join()
            } finally {
                callerScope.cancel()
                while (true) (work.poll() ?: break).run()
            }
        }
    }

    @Test fun `nanoTime wraparound retains the requested remaining budget`() = runBlocking {
        val wrappingClock = MonotonicClock { System.nanoTime() + Long.MAX_VALUE }
        val driver = OkHttpHttpTransport(wrappingClock, scope, dispatcher)
        val server = server()
        server.enqueue(MockResponse.Builder().body("ok").build())
        val request = HttpRequest(server.url("/").toString(), HttpMethod.GET,
            deadlineNanos = wrappingClock.nowNanos() + SECONDS.toNanos(3))
        assertContentEquals("ok".encodeToByteArray(), driver.send(request).body)
    }

    @Test fun `responses create neither cookies nor cache or diagnostic content`() = runBlocking {
        val server = server()
        repeat(2) { server.enqueue(MockResponse.Builder().addHeader("Set-Cookie", "secret=sentinel-cookie; Path=/")
            .addHeader("Cache-Control", "public, max-age=86400").body("sentinel-body").build()) }
        repeat(2) {
            val response = transport.send(request(server, headers = mapOf("x-api-key" to "sentinel-key")))
            assertEquals("<HTTP response redacted>", response.toString())
            assertNull(server.takeRequest(2, SECONDS)!!.headers["Cookie"])
        }
        assertEquals(2, server.requestCount)
        server.enqueue(MockResponse.Builder().body("sentinel-not-gzip").addHeader("Content-Encoding", "gzip").build())
        val error = errorOf { transport.send(request(server)) }
        assertEquals(HttpTransportError.NetworkFailure, error)
        assertNull(error.cause)
        assertEquals("networkFailure", error.toString())
        assertFalse(error.stackTraceToString().contains("sentinel"))
    }

    @Test fun `normal TLS rejects an untrusted certificate with no HTTP request`() = runBlocking {
        val certificate = HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
        val certificates = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val server = MockWebServer().also { servers += it }
        server.useHttps(certificates.sslSocketFactory())
        server.enqueue(MockResponse.Builder().body("must not arrive").build())
        server.start()
        val error = errorOf { transport.send(request(server)) }
        assertEquals(HttpTransportError.NetworkFailure, error)
        assertNull(error.cause)
        assertEquals(0, server.requestCount)
    }

    private fun server(): MockWebServer = MockWebServer().also { servers += it; it.start() }

    private fun request(server: MockWebServer, method: HttpMethod = HttpMethod.GET, path: String = "/",
        headers: Map<String, String> = emptyMap(), body: ByteArray? = null, cap: Int = Limits.responseCap,
        budgetMillis: Long = 3000): HttpRequest = request(server.url(path).toString(), method, headers, body, cap, budgetMillis)

    private fun request(url: String, method: HttpMethod = HttpMethod.GET, headers: Map<String, String> = emptyMap(),
        body: ByteArray? = null, cap: Int = Limits.responseCap, budgetMillis: Long = 3000): HttpRequest =
        HttpRequest(url, method, headers, body, responseByteCap = cap, deadlineNanos = clock.nowNanos() + MILLISECONDS.toNanos(budgetMillis))

    private suspend fun errorOf(operation: suspend () -> Any): HttpTransportError {
        try { operation() } catch (error: HttpTransportError) { return error }
        fail("Expected a typed transport error")
    }

    private fun stalled(closed: CountDownLatch, length: String = "64"): MockResponse = MockResponse.Builder()
        .setHeader("Content-Length", length).socketHandler(object : SocketHandler {
            override fun handle(socket: Socket) {
                socket.sink.flush()
                observeClose(socket, closed)
            }
        }).build()

    private fun chunkedOversize(closed: CountDownLatch): MockResponse = MockResponse.Builder()
        .addHeader("Transfer-Encoding", "chunked").removeHeader("Content-Length")
        .socketHandler(object : SocketHandler {
            override fun handle(socket: Socket) {
                socket.sink.buffer().apply { writeUtf8("40\r\n${"a".repeat(64)}\r\n1\r\nb\r\n"); flush() }
                observeClose(socket, closed)
            }
        }).build()

    private fun observeClose(socket: Socket, closed: CountDownLatch) {
        socket.source.timeout().timeout(4, SECONDS)
        try {
            if (socket.source.read(Buffer(), 1) == -1L) closed.countDown()
        } catch (_: IOException) { closed.countDown() }
    }
}
