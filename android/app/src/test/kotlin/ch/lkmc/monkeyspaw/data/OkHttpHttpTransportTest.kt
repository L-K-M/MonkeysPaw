package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.domain.Limits
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.SyncServerURL
import ch.lkmc.monkeyspaw.core.syncapi.ErrorResponse
import ch.lkmc.monkeyspaw.core.syncapi.FailureCode
import kotlinx.coroutines.*
import kotlinx.coroutines.test.StandardTestDispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.SocketEffect
import mockwebserver3.SocketHandler
import okhttp3.Dispatcher
import okhttp3.Protocol
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.Buffer
import okio.GzipSink
import okio.Socket
import okio.buffer
import java.io.IOException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.nio.file.Files
import java.security.KeyStore
import java.security.cert.X509Certificate
import javax.net.ssl.X509TrustManager
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ConcurrentLinkedQueue
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

    @Test fun `sync policy validates the bound server and permits its explicit trust choice`() = runBlocking {
        val server = server()
        val bound = SyncServerURL(server.url("/").toString().trimEnd('/'))
        val other = server()
        fun sync(url: String, trust: SyncTLSTrust = SyncTLSTrust.SYSTEM) = HttpRequest(url, HttpMethod.GET,
            deadlineNanos = clock.nowNanos() + MILLISECONDS.toNanos(3000), urlPolicy = HttpUrlPolicy.Sync(bound, trust))
        assertEquals(HttpTransportError.ServerMismatch, errorOf { transport.send(sync(other.url("/api/v1/me").toString())) })
        server.enqueue(MockResponse.Builder().body("{}").build())
        assertContentEquals("{}".encodeToByteArray(),
            transport.send(sync(server.url("/api/v1/me").toString(), SyncTLSTrust.SYSTEM_AND_USER)).body)
        assertEquals(1, server.requestCount)
        assertEquals(0, other.requestCount)
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

    @Test fun `explicit encoding and range headers still receive bounded decoded bytes`() = runBlocking {
        val server = server()
        for (headers in listOf(mapOf("Accept-Encoding" to "gzip"), mapOf("Accept-Encoding" to "identity"), mapOf("Range" to "bytes=0-"))) {
            val oversized = Buffer()
            GzipSink(oversized).buffer().use { it.writeUtf8("a".repeat(1025)) }
            assertTrue(oversized.size < 128)
            server.enqueue(MockResponse.Builder().body(oversized).addHeader("Content-Encoding", "gzip").build())
            assertEquals(HttpTransportError.ResponseTooLarge,
                errorOf { transport.send(request(server, headers = headers, cap = 128)) })
            val observed = server.takeRequest(2, SECONDS)!!
            headers.forEach { (name, value) -> assertEquals(value, observed.headers[name]) }

            val exact = Buffer()
            GzipSink(exact).buffer().use { it.writeUtf8("a".repeat(128)) }
            server.enqueue(MockResponse.Builder().code(503).addHeader("Retry-After", "0")
                .body(exact).addHeader("Content-Encoding", "gzip").build())
            val response = transport.send(request(server, headers = headers, cap = 128))
            assertEquals(503, response.statusCode)
            assertEquals("0", response.headers["retry-after"])
            assertContentEquals("a".repeat(128).encodeToByteArray(), response.body)
            assertNull(response.headers["content-encoding"])
            assertNull(response.headers["content-length"])
            assertNotNull(server.takeRequest(2, SECONDS))
        }
        assertEquals(6, server.requestCount)
    }

    @Test fun `gzip cap closes incomplete chunked receipts with automatic or explicit decoding`() = runBlocking {
        for (headers in listOf(emptyMap(), mapOf("Accept-Encoding" to "gzip"))) {
            val closed = CountDownLatch(1)
            val compressed = Buffer()
            GzipSink(compressed).buffer().use { it.writeUtf8("a".repeat(1025)) }
            assertTrue(compressed.size < 128)
            val server = server()
            server.enqueue(MockResponse.Builder().addHeader("Content-Encoding", "gzip")
                .addHeader("Transfer-Encoding", "chunked").removeHeader("Content-Length")
                .socketHandler(object : SocketHandler {
                    override fun handle(socket: Socket) {
                        socket.sink.buffer().apply {
                            writeHexadecimalUnsignedLong(compressed.size).writeUtf8("\r\n")
                            writeAll(compressed)
                            writeUtf8("\r\n").flush() // Withhold the final HTTP chunk.
                        }
                        observeClose(socket, closed)
                    }
                }).build())
            assertEquals(HttpTransportError.ResponseTooLarge,
                errorOf { transport.send(request(server, headers = headers, cap = 128)) })
            assertTrue(closed.await(2, SECONDS))
        }
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

    @Test fun `caller cancellation never escapes a launch as an unhandled failure`() = runBlocking {
        val unhandled = ConcurrentLinkedQueue<Throwable>()
        val callerScope = CoroutineScope(SupervisorJob() + Dispatchers.Default +
            CoroutineExceptionHandler { _, error -> unhandled.add(error) })
        val closed = CountDownLatch(1)
        val server = server()
        server.enqueue(stalled(closed))
        try {
            val caller = callerScope.launch { transport.send(request(server)) }
            withContext(Dispatchers.IO) { assertNotNull(server.takeRequest(2, SECONDS)) }
            caller.cancelAndJoin()
            assertTrue(closed.await(2, SECONDS))
            assertTrue(unhandled.isEmpty(), "Unhandled failures: $unhandled")
        } finally { callerScope.cancel() }
    }

    @Test fun `close observer does not report a read timeout as peer closure`() {
        val closed = CountDownLatch(1)
        val observed = CountDownLatch(1)
        val server = server()
        server.enqueue(MockResponse.Builder().socketHandler(object : SocketHandler {
            override fun handle(socket: Socket) {
                socket.sink.flush()
                observeClose(socket, closed)
                observed.countDown()
            }
        }).build())
        java.net.Socket(server.hostName, server.port).use { peer ->
            peer.getOutputStream().write("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".encodeToByteArray())
            assertTrue(observed.await(6, SECONDS), "Close observer did not finish")
            assertFalse(closed.await(0, SECONDS), "An open peer was reported closed")
        }
    }

    @Test fun `adapter work cancellation keeps its typed cause without cancelling the caller scope`() = runBlocking {
        val io = StandardTestDispatcher()
        val waitingScope = CoroutineScope(SupervisorJob() + io)
        val server = server()
        try {
            val driver = OkHttpHttpTransport(clock, waitingScope, dispatcher)
            val outcome = CompletableDeferred<CancellationException>()
            val caller = launch(start = CoroutineStart.UNDISPATCHED) {
                try { driver.send(request(server)) }
                catch (cancelled: CancellationException) { outcome.complete(cancelled); throw cancelled }
            }
            waitingScope.cancel()
            io.scheduler.runCurrent()
            val cancelled = withTimeout(2000) { outcome.await() }
            assertSame(HttpTransportError.Cancelled, cancelled.cause)
            caller.join()
            assertTrue(caller.isCancelled)
            assertTrue(currentCoroutineContext().isActive)
            assertEquals(0, server.requestCount)
        } finally { waitingScope.cancel() }
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

    @Test fun `observed receipt failure survives later cancellation without an unhandled exception`() = runBlocking {
        val cases = listOf("advertised" to HttpTransportError.ResponseTooLarge,
            "chunked" to HttpTransportError.ResponseTooLarge,
            "deadline" to HttpTransportError.DeadlineExceeded,
            "redirect" to HttpTransportError.RedirectRefused)
        for ((fixture, expected) in cases) {
            val work = LinkedBlockingQueue<Runnable>()
            val ui = object : CoroutineDispatcher() {
                override fun dispatch(context: CoroutineContext, block: Runnable) { work.add(block) }
            }
            val closed = CountDownLatch(1)
            val server = server()
            server.enqueue(when (fixture) {
                "advertised" -> stalled(closed, "65")
                "chunked" -> chunkedOversize(closed)
                "redirect" -> stalled(closed).newBuilder().code(302).build()
                else -> stalled(closed)
            })
            val outcome = CompletableDeferred<Exception>()
            val unhandled = ConcurrentLinkedQueue<Throwable>()
            val callerScope = CoroutineScope(SupervisorJob() + ui +
                CoroutineExceptionHandler { _, error -> unhandled.add(error) })
            val caller = callerScope.launch(start = CoroutineStart.UNDISPATCHED) {
                try { transport.send(request(server, cap = 64, budgetMillis = 500)) }
                catch (error: Exception) { outcome.complete(error); throw error }
            }
            try {
                // Hold the committed failure until the deadline passes and the caller cancels.
                assertTrue(closed.await(2, SECONDS))
                val resume = assertNotNull(work.poll(2, SECONDS))
                delay(550) // Resume only after the original deadline, with a later caller cancel.
                caller.cancel()
                resume.run()
                val cancelled = assertIs<CancellationException>(withTimeout(2000) { outcome.await() })
                assertSame(expected, cancelled.cause)
                caller.join()
                assertTrue(unhandled.isEmpty(), "Unhandled failures for $fixture: $unhandled")
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

    @Test fun `user anchors reach only opted in sync and never assistant default trust or a wrong deployment`() = runBlocking {
        val ca = HeldCertificate.Builder().certificateAuthority(0).build()
        val leaf = HeldCertificate.Builder().addSubjectAlternativeName("localhost").signedBy(ca).build()
        val source = tlsServer(leaf, ca)
        val other = tlsServer(leaf, ca)
        val bound = SyncServerURL(source.url("/paw/").toString())
        val creates = AtomicInteger()
        val checks = AtomicInteger()
        val manager = trustFactory(ca).create()
        val driver = OkHttpHttpTransport(clock, scope, dispatcher, SyncTlsTrustFactory {
            creates.incrementAndGet()
            object : X509TrustManager by manager {
                override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                    checks.incrementAndGet()
                    manager.checkServerTrusted(chain, authType)
                }
            }
        })
        source.enqueue(MockResponse.Builder().body("{}").build())
        val canonical = "HTTPS://LOCALHOST.:${source.port}/paw/api/v1/%6De?after_id=one"
        assertContentEquals("{}".encodeToByteArray(), driver.send(syncRequest(source, url = canonical, bound = bound)).body)
        val observed = source.takeRequest(2, SECONDS)!!
        assertEquals("/paw/api/v1/me?after_id=one", observed.target)
        assertEquals("Bearer synthetic-device-token", observed.headers["Authorization"])
        assertEquals(1, creates.get())
        assertTrue(checks.get() > 0)
        val priorChecks = checks.get()

        assertEquals(HttpTransportError.NetworkFailure, errorOf { driver.send(request(source, path = "/v1/models")) })
        assertEquals(HttpTransportError.NetworkFailure,
            errorOf { driver.send(syncRequest(source, bound = bound, path = "/paw/api/v1/me", trust = SyncTLSTrust.SYSTEM)) })
        for (url in listOf(other.url("/paw/api/v1/me").toString(), source.url("/other/api/v1/me").toString(),
            source.url("/paw/api/v10/me").toString(), source.url("/paw/api/v1/../outside").toString(),
            source.url("/paw/api/v1/me").toString().replace("localhost", "127.0.0.1"))) {
            assertEquals(HttpTransportError.ServerMismatch, errorOf { driver.send(syncRequest(source, url = url, bound = bound)) })
        }
        // A new server's default choice also cannot reuse the previously accepted TLS connection.
        assertEquals(HttpTransportError.NetworkFailure,
            errorOf { driver.send(syncRequest(other, trust = SyncTLSTrust.SYSTEM)) })
        assertEquals(1, creates.get())
        assertEquals(priorChecks, checks.get())
        assertFailsWith<HttpTransportError.RequestTooLarge> {
            HttpRequest(bound.apiURL + "/auth/logout", HttpMethod.POST, body = "{}".encodeToByteArray(),
                requestByteCap = 1, deadlineNanos = clock.nowNanos() + SECONDS.toNanos(3),
                urlPolicy = HttpUrlPolicy.Sync(bound, SyncTLSTrust.SYSTEM_AND_USER))
        }
        assertEquals(1, source.requestCount)
        assertEquals(0, other.requestCount)
    }

    @Test fun `native trust factory keeps both anchor sets and every opted in request owns its connection`() = runBlocking {
        val system = HeldCertificate.Builder().certificateAuthority(0).build()
        val user = HeldCertificate.Builder().certificateAuthority(0).build()
        val driver = OkHttpHttpTransport(clock, scope, dispatcher, trustFactory(system, user))
        for (ca in listOf(system, user)) {
            val leaf = HeldCertificate.Builder().addSubjectAlternativeName("localhost").signedBy(ca).build()
            val source = tlsServer(leaf, ca)
            repeat(2) {
                source.enqueue(MockResponse.Builder().body("{}").build())
                assertContentEquals("{}".encodeToByteArray(), driver.send(syncRequest(source)).body)
            }
            assertNotEquals(source.takeRequest(2, SECONDS)!!.connectionIndex, source.takeRequest(2, SECONDS)!!.connectionIndex)
            assertEquals(2, source.requestCount)
        }
    }

    @Test fun `removing a user anchor is observed on the next sync request without retaining its TLS session`() = runBlocking {
        val system = HeldCertificate.Builder().certificateAuthority(0).build()
        val user = HeldCertificate.Builder().certificateAuthority(0).build()
        val leaf = HeldCertificate.Builder().addSubjectAlternativeName("localhost").signedBy(user).build()
        val source = tlsServer(leaf, user)
        var anchors = arrayOf(system, user)
        val driver = OkHttpHttpTransport(clock, scope, dispatcher, AndroidSyncTlsTrust {
            KeyStore.getInstance("JKS").apply {
                load(null)
                anchors.forEachIndexed { index, anchor -> setCertificateEntry("anchor-$index", anchor.certificate) }
            }
        })
        source.enqueue(MockResponse.Builder().body("{}").build())
        driver.send(syncRequest(source))
        anchors = arrayOf(system)
        assertEquals(HttpTransportError.NetworkFailure, errorOf { driver.send(syncRequest(source)) })
        assertEquals(1, source.requestCount)
    }

    @Test fun `sync opt in still rejects untrusted expired and wrong hostname certificates`() = runBlocking {
        val ca = HeldCertificate.Builder().certificateAuthority(0).build()
        val otherCa = HeldCertificate.Builder().certificateAuthority(0).build()
        val driver = OkHttpHttpTransport(clock, scope, dispatcher, trustFactory(ca))
        val leaves = listOf(
            HeldCertificate.Builder().addSubjectAlternativeName("localhost").signedBy(otherCa).build() to otherCa,
            HeldCertificate.Builder().addSubjectAlternativeName("wrong.invalid").signedBy(ca).build() to ca,
            HeldCertificate.Builder().addSubjectAlternativeName("localhost").validityInterval(0, 1).signedBy(ca).build() to ca,
        )
        for ((leaf, root) in leaves) {
            val source = tlsServer(leaf, root)
            val error = errorOf { driver.send(syncRequest(source)) }
            assertEquals(HttpTransportError.NetworkFailure, error)
            assertNull(error.cause)
            assertTrue(error.suppressed.isEmpty())
            assertEquals(0, source.requestCount)
        }
        val broken = AndroidSyncTlsTrust { throw IOException("synthetic certificate diagnostic") }
        val error = assertFailsWith<HttpTransportError> { broken.create() }
        assertSame(HttpTransportError.NetworkFailure, error)
        assertFalse(error.stackTraceToString().contains("synthetic certificate diagnostic"))
    }

    @Test fun `opted in sync refuses redirects to the same server another server or HTTP without forwarding credentials`() = runBlocking {
        val ca = HeldCertificate.Builder().certificateAuthority(0).build()
        val leaf = HeldCertificate.Builder().addSubjectAlternativeName("localhost").signedBy(ca).build()
        val source = tlsServer(leaf, ca)
        val target = tlsServer(leaf, ca)
        val plaintext = server()
        val driver = OkHttpHttpTransport(clock, scope, dispatcher, trustFactory(ca))
        var count = 0
        for (method in listOf(HttpMethod.GET, HttpMethod.POST)) {
            for (status in listOf(300, 301, 302, 303, 304, 305, 306, 307, 308, 310, 399)) {
                for (location in listOf(null, source.url("/api/v1/other").toString(), target.url("/api/v1/me").toString(),
                    plaintext.url("/api/v1/me").toString(), "http://[invalid")) {
                    val response = MockResponse.Builder().code(status).body(syncError())
                    if (location != null) response.addHeader("Location", location)
                    source.enqueue(response.build())
                    assertEquals(HttpTransportError.RedirectRefused, errorOf { driver.send(syncRequest(source, method = method)) })
                    assertEquals(++count, source.requestCount)
                }
            }
        }
        assertEquals(110, source.requestCount)
        assertEquals(0, target.requestCount)
        assertEquals(0, plaintext.requestCount)
    }

    @Test fun `sync envelopes preserve exact decoded caps duplicate Retry After and one attempt statuses`() = runBlocking {
        val ca = HeldCertificate.Builder().certificateAuthority(0).build()
        val leaf = HeldCertificate.Builder().addSubjectAlternativeName("localhost").signedBy(ca).build()
        val source = tlsServer(leaf, ca)
        val driver = OkHttpHttpTransport(clock, scope, dispatcher, trustFactory(ca))
        val body = syncError()
        var count = 0
        for (builder in listOf(MockResponse.Builder().body(body), MockResponse.Builder().chunkedBody(body, 3),
            MockResponse.Builder().body(body).removeHeader("Content-Length").addHeader("Connection", "close")
                .onResponseEnd(SocketEffect.CloseSocket()))) {
            source.enqueue(builder.code(500).build())
            assertContentEquals(body.encodeToByteArray(), driver.send(syncRequest(source, cap = body.length)).body)
            assertEquals(++count, source.requestCount)
        }
        source.enqueue(MockResponse.Builder().body(body).build())
        assertEquals(HttpTransportError.ResponseTooLarge, errorOf { driver.send(syncRequest(source, cap = body.length - 1)) })
        count++
        val compressed = Buffer()
        val large = body + " ".repeat(Limits.responseCap)
        GzipSink(compressed).buffer().use { it.writeUtf8(large) }
        source.enqueue(MockResponse.Builder().body(compressed.clone()).addHeader("Content-Encoding", "gzip").build())
        assertContentEquals(large.encodeToByteArray(), driver.send(syncRequest(source, cap = Limits.syncResponseCap)).body)
        count++
        source.enqueue(MockResponse.Builder().body(compressed).addHeader("Content-Encoding", "gzip").build())
        assertEquals(HttpTransportError.ResponseTooLarge, errorOf { driver.send(syncRequest(source)) })
        count++
        source.enqueue(MockResponse.Builder().code(429).body(syncError(FailureCode.RATE_LIMITED))
            .addHeader("Retry-After", "2").addHeader("retry-after", "3").build())
        assertEquals("2, 3", driver.send(syncRequest(source)).headers["retry-after"])
        count++
        for ((status, header) in listOf(401 to "WWW-Authenticate", 407 to "Proxy-Authenticate", 408 to "Retry-After",
            421 to "Retry-After", 503 to "Retry-After")) {
            source.enqueue(MockResponse.Builder().code(status).body(body)
                .addHeader(header, if (status in listOf(401, 407)) "Basic realm=\"test\"" else "0").build())
            val response = driver.send(syncRequest(source, method = HttpMethod.POST))
            assertEquals(status, response.statusCode)
            assertContentEquals(body.encodeToByteArray(), response.body)
            assertEquals(++count, source.requestCount)
        }
        assertEquals(count, source.requestCount)
    }

    @Test fun `sync caps deadlines and cancellation close opted in receipts`() = runBlocking {
        val ca = HeldCertificate.Builder().certificateAuthority(0).build()
        val leaf = HeldCertificate.Builder().addSubjectAlternativeName("localhost").signedBy(ca).build()
        val source = tlsServer(leaf, ca)
        val driver = OkHttpHttpTransport(clock, scope, dispatcher, trustFactory(ca))
        for (fixture in listOf("advertised", "chunked", "deadline", "cancel")) {
            val closed = CountDownLatch(1)
            source.enqueue(when (fixture) {
                "advertised" -> stalled(closed, "65")
                "chunked" -> chunkedOversize(closed, syncError().padEnd(65))
                else -> stalled(closed)
            })
            val outcome = CompletableDeferred<HttpTransportError>()
            val caller = launch { outcome.complete(errorOf { driver.send(syncRequest(source, cap = 64,
                budgetMillis = if (fixture == "deadline") 500 else 3000)) }) }
            assertNotNull(withContext(Dispatchers.IO) { source.takeRequest(2, SECONDS) })
            if (fixture == "cancel") caller.cancel()
            assertEquals(when (fixture) {
                "deadline" -> HttpTransportError.DeadlineExceeded
                "cancel" -> HttpTransportError.Cancelled
                else -> HttpTransportError.ResponseTooLarge
            }, withTimeout(2000) { outcome.await() })
            assertTrue(closed.await(2, SECONDS), "Receipt was not closed for $fixture")
            caller.join()
        }
        assertEquals(4, source.requestCount)
    }

    @Test fun `opted in sync clients share dispatcher admission and queued expiry never sends`() = runBlocking {
        dispatcher.maxRequests = 1
        dispatcher.maxRequestsPerHost = 1
        val ca = HeldCertificate.Builder().certificateAuthority(0).build()
        val leaf = HeldCertificate.Builder().addSubjectAlternativeName("localhost").signedBy(ca).build()
        val source = tlsServer(leaf, ca)
        val queued = tlsServer(leaf, ca)
        val driver = OkHttpHttpTransport(clock, scope, dispatcher, trustFactory(ca))
        val closed = CountDownLatch(1)
        source.enqueue(stalled(closed).newBuilder().headersDelay(3, SECONDS).build())
        val outcome = CompletableDeferred<HttpTransportError>()
        val first = launch { outcome.complete(errorOf { driver.send(syncRequest(source)) }) }
        assertNotNull(withContext(Dispatchers.IO) { source.takeRequest(2, SECONDS) })
        assertEquals(HttpTransportError.DeadlineExceeded, errorOf { driver.send(syncRequest(queued, budgetMillis = 200)) })
        assertEquals(0, queued.requestCount)
        first.cancel()
        assertEquals(HttpTransportError.Cancelled, outcome.await())
        first.join()
        withTimeout(2000) { scope.coroutineContext.job.children.toList().joinAll() }
        assertEquals(0, queued.requestCount)
        assertEquals(1, source.requestCount)
    }

    @Test fun `trust discovery consumes the deadline and cannot dispatch after expiry or cancellation`() = runBlocking {
        val ca = HeldCertificate.Builder().certificateAuthority(0).build()
        val leaf = HeldCertificate.Builder().addSubjectAlternativeName("localhost").signedBy(ca).build()
        val source = tlsServer(leaf, ca)
        val manager = trustFactory(ca).create()
        for (cancel in listOf(false, true)) {
            val started = CountDownLatch(1)
            val release = CountDownLatch(1)
            val driver = OkHttpHttpTransport(clock, scope, dispatcher, SyncTlsTrustFactory {
                started.countDown()
                check(release.await(3, SECONDS))
                manager
            })
            val outcome = CompletableDeferred<HttpTransportError>()
            val caller = launch { outcome.complete(errorOf { driver.send(syncRequest(source, budgetMillis = if (cancel) 3000 else 200)) }) }
            try {
                assertTrue(withContext(Dispatchers.IO) { started.await(2, SECONDS) })
                if (cancel) caller.cancel()
                assertEquals(if (cancel) HttpTransportError.Cancelled else HttpTransportError.DeadlineExceeded,
                    withTimeout(2000) { outcome.await() })
                caller.join()
            } finally { release.countDown() }
            withTimeout(2000) { scope.coroutineContext.job.children.toList().joinAll() }
            assertEquals(0, source.requestCount)
        }
    }

    private fun syncRequest(server: MockWebServer, method: HttpMethod = HttpMethod.GET, path: String = "/api/v1/me",
        url: String = server.url(path).toString(), bound: SyncServerURL = SyncServerURL(server.url("/").toString()),
        trust: SyncTLSTrust = SyncTLSTrust.SYSTEM_AND_USER, cap: Int = Limits.responseCap, budgetMillis: Long = 3000): HttpRequest =
        HttpRequest(url, method, mapOf("Authorization" to "Bearer synthetic-device-token", "Accept" to "application/json"),
            body = if (method == HttpMethod.POST) "{}".encodeToByteArray() else null,
            responseByteCap = cap, deadlineNanos = clock.nowNanos() + MILLISECONDS.toNanos(budgetMillis),
            urlPolicy = HttpUrlPolicy.Sync(bound, trust))

    private fun syncError(code: FailureCode = FailureCode.INTERNAL_ERROR): String =
        ErrorResponse.codec.encode(ErrorResponse.Failure(code)).decodeToString()

    private fun trustFactory(vararg anchors: HeldCertificate): AndroidSyncTlsTrust = AndroidSyncTlsTrust {
        KeyStore.getInstance("JKS").apply {
            load(null)
            anchors.forEachIndexed { index, anchor -> setCertificateEntry("anchor-$index", anchor.certificate) }
        }
    }

    private fun tlsServer(leaf: HeldCertificate, ca: HeldCertificate): MockWebServer = MockWebServer().also {
        servers += it
        it.protocols = listOf(Protocol.HTTP_1_1) // Socket-handler closure assertions need an HTTP/1 receipt.
        it.useHttps(HandshakeCertificates.Builder().heldCertificate(leaf, ca.certificate).build().sslSocketFactory())
        it.start()
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
        catch (cancelled: CancellationException) { return cancelled.cause as? HttpTransportError ?: throw cancelled }
        fail("Expected a typed transport error")
    }

    private fun stalled(closed: CountDownLatch, length: String = "64"): MockResponse = MockResponse.Builder()
        .setHeader("Content-Length", length).socketHandler(object : SocketHandler {
            override fun handle(socket: Socket) {
                socket.sink.flush() // MockWebServer 5.5.0 writes the response head before this handler.
                observeClose(socket, closed)
            }
        }).build()

    private fun chunkedOversize(closed: CountDownLatch, body: String = "a".repeat(64) + "b"): MockResponse = MockResponse.Builder()
        .addHeader("Transfer-Encoding", "chunked").removeHeader("Content-Length")
        .socketHandler(object : SocketHandler {
            override fun handle(socket: Socket) {
                socket.sink.buffer().apply { writeUtf8("40\r\n${body.take(64)}\r\n1\r\n${body.drop(64)}\r\n"); flush() }
                observeClose(socket, closed)
            }
        }).build()

    private fun observeClose(socket: Socket, closed: CountDownLatch) {
        socket.source.timeout().timeout(4, SECONDS)
        try {
            if (socket.source.read(Buffer(), 1) == -1L) closed.countDown()
        } catch (_: SocketTimeoutException) {
            // A read timeout proves no peer closure was observed.
        } catch (_: SocketException) { closed.countDown() }
    }
}
