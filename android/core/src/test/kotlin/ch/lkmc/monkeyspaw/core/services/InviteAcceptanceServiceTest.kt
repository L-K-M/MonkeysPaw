@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.llm.*
import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.sync.*
import ch.lkmc.monkeyspaw.core.syncapi.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import kotlin.test.*

/** Stateful synthetic remote consumption; real-server and Keystore proof belong to the later harness. */
private class InviteHarness(scheduler: TestCoroutineScheduler, scope: CoroutineScope) {
    val r = AccountHarness(scheduler, scope)
    val service = InviteAcceptanceService(r.service)
    val token = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also(SecureRandom()::nextBytes))
    val password = SecretValue("Runtime-password-" + UUID.randomUUID())
    var consumed = false
    var joined = false
    var joinRole = Role.VIEWER
    var membershipRole = Role.VIEWER
    var registerCalls = 0
    var joinCalls = 0
    var intercept: (suspend (HttpRequest) -> HttpResponse?)? = null
    val group get() = GroupMembership(SyncTestValues.group.rawValue, "Team", membershipRole)
    val link get() = linkFor(r.server)

    init {
        r.respond = { request -> intercept?.invoke(request) ?: when {
            request.url.endsWith("/auth/register") -> {
                registerCalls++
                val body = RegisterRequest.codec.decode(request.body!!)
                assertTrue(body.inviteToken == token, "Wrong invitation in request")
                password.withValue { assertTrue(body.password == it, "Wrong password in request") }
                assertFalse(request.headers.containsKey("Authorization"), "Registration forwarded a bearer")
                if (consumed) EngineHarness.errorResponse(400, FailureCode.MALFORMED_REQUEST)
                else {
                    consumed = true
                    joined = true
                    HttpResponse(200, body = AuthResponse.codec.encode(AuthResponse(r.token, r.userDTO())))
                }
            }
            request.url.endsWith("/groups/join") -> {
                joinCalls++
                val body = JoinGroupRequest.codec.decode(request.body!!)
                assertTrue(body.inviteToken == token, "Wrong invitation in request")
                if (consumed) EngineHarness.errorResponse(400, FailureCode.MALFORMED_REQUEST)
                else {
                    consumed = true
                    joined = true
                    HttpResponse(200, body = GroupMembership.codec.encode(group.copy(role = joinRole)))
                }
            }
            request.url.endsWith("/me") -> HttpResponse(200, body = MeResponse.codec.encode(
                r.me?.invoke() ?: MeResponse(r.userDTO(), if (joined) listOf(group) else emptyList(), listOf(r.deviceDTO()))))
            request.url.endsWith("/sync/pull") -> {
                val scopes = listOf(SyncScope(ScopeIdentity.User(r.user.rawValue), Mode.SNAPSHOT, 0, "user", false, emptyList())) +
                    if (joined) listOf(SyncScope(ScopeIdentity.Group(group.groupID, group.name, group.role), Mode.SNAPSHOT, 0, "group", false, emptyList())) else emptyList()
                HttpResponse(200, body = PullResponse.codec.encode(PullResponse(SyncTestValues.uuid.toString(), scopes, emptyList())))
            }
            else -> null
        } }
    }

    fun linkFor(server: String) = "monkeyspaw://join?server=" + server.encodeToByteArray().joinToString("") {
        "%" + (it.toInt() and 255).toString(16).padStart(2, '0')
    } + "&token=$token"
    fun stage(server: String? = null) = service.stage(server?.let(::linkFor) ?: link)
    suspend fun register(staged: StagedInvite = stage()) = service.accept(staged, InviteAcceptance.NEW_ACCOUNT, "person", password, "Android")
    fun assertNoInviteOrPasswordPersistence(retiredTokens: List<String> = emptyList()) {
        val values = listOf(token, link) + password.withValue { listOf(it) }
        val needles = values + values.map { Base64.getEncoder().encodeToString(it.encodeToByteArray()) }
        val bearers = retiredTokens + r.token
        for (file in r.h.data.listFiles()) {
            val text = r.h.data.text(file.relativePath)
            assertFalse(needles.any(text::contains) || bearers.any(text::contains), "Credential in non-secret state")
        }
        for (bytes in r.h.files.bytesSnapshot().values) {
            val text = bytes.toByteArray().decodeToString()
            assertFalse(needles.any(text::contains) || bearers.any(text::contains), "Credential in non-secret library")
        }
        for (secret in r.secrets.values.values) secret.value.withValue { text ->
            assertFalse(needles.any(text::contains), "Invite/password in SecretStore")
        }
    }
}

class InviteAcceptanceServiceTest {
    @Test fun persistenceScanDetectsCurrentAndRetiredBearersInStateAndLibrary() = runTest {
        for (retired in listOf(true, false)) for (library in listOf(false, true)) {
            val h = InviteHarness(testScheduler, backgroundScope)
            val bearer = h.r.token
            val retiredTokens = if (retired) {
                h.r.token = "C".repeat(42) + "A"
                listOf(bearer)
            } else emptyList()
            val files = if (library) h.r.h.files else h.r.h.data
            files.put(bearer, "credential-sentinel.txt")
            assertFailsWith<AssertionError>("Bearer scan missed retired=$retired library=$library") {
                h.assertNoInviteOrPasswordPersistence(retiredTokens)
            }
        }
    }

    @Test fun stagingOnlyDisplaysDestinationAndAccountWithoutSecretOrIO() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        val before = h.r.h.data.bytesSnapshot()
        val staged = h.stage()
        assertEquals(h.r.server, staged.destination.serverURL)
        assertNull(staged.destination.currentAccount)
        assertFalse(staged.destination.canJoin)
        assertTrue(staged.canAccept)
        assertTrue(h.r.requests.isEmpty())
        assertTrue(h.r.secrets.reads.isEmpty())
        assertEquals(before, h.r.h.data.bytesSnapshot())
        assertEquals("<staged invite redacted>", staged.toString())
        assertEquals("<invite destination redacted>", staged.destination.toString())
        staged.clear()
        assertFalse(staged.canAccept)
        assertSame(InviteAcceptanceIssue.NoInvite, assertFailsWith<InviteAcceptanceIssue> {
            h.service.accept(staged, InviteAcceptance.EXISTING_ACCOUNT)
        })
        assertTrue(h.r.requests.isEmpty())
        h.assertNoInviteOrPasswordPersistence()
    }

    @Test fun bareStagingRequiresSelectedServerAndDisplaysHTTPWarning() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        assertSame(InviteAcceptanceIssue.ServerRequired, assertFailsWith<InviteAcceptanceIssue> { h.service.stage(h.token) })
        assertSame(InviteAcceptanceIssue.InvalidLink, assertFailsWith<InviteAcceptanceIssue> { h.service.stage("invalid", h.r.server) })
        val staged = h.service.stage(h.token, "http://10.0.0.1:8080/paw/api/v1/")
        assertEquals("http://10.0.0.1:8080/paw", staged.destination.serverURL)
        assertTrue(staged.destination.usesHTTP)
        assertTrue(h.r.requests.isEmpty())
        assertTrue(h.r.secrets.reads.isEmpty())
    }

    @Test fun acceptJoinsRefreshesAndRequestsTheNewGroupSnapshot() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        val account = h.r.login().account
        val stage = h.stage()
        assertTrue(stage.destination.canJoin)
        assertEquals(account, stage.destination.currentAccount)
        val before = h.r.requests.size
        val trigger = h.r.h.engine.scheduling.value.triggerVersion
        val result = h.service.accept(stage, InviteAcceptance.EXISTING_ACCOUNT)
        assertTrue(result.accepted)
        assertNull(result.issue)
        assertEquals(listOf(h.group), result.snapshot.me?.groups)
        assertFalse(stage.canAccept)
        assertEquals(listOf("join", "me"), h.r.requests.drop(before).take(2).map { it.url.substringAfterLast('/') })
        assertTrue(h.r.h.engine.scheduling.value.triggerVersion > trigger)
        h.r.h.engine.runBackground(version = h.r.h.engine.scheduling.value.triggerVersion)
        assertEquals(1, h.r.h.pulls)
        assertEquals("group", h.r.h.state.cursors[SyncScopeKey.Group(SyncTestValues.group)])
        assertEquals(Role.VIEWER, h.r.h.state.groups[SyncTestValues.group]?.role)
        assertEquals(1, h.joinCalls)
        assertEquals(0, h.registerCalls)
        h.assertNoInviteOrPasswordPersistence()
    }

    @Test fun authoritativeHigherRolesAreRetainedWithoutApplyingAnInviteRoleLocally() = runTest {
        for (role in Role.entries) {
            val h = InviteHarness(testScheduler, backgroundScope)
            h.r.login()
            h.joinRole = Role.VIEWER
            h.membershipRole = role
            val result = h.service.accept(h.stage(), InviteAcceptance.EXISTING_ACCOUNT)
            assertEquals(role, result.snapshot.me?.groups?.single()?.role)
            assertEquals(1, h.joinCalls)
        }
    }

    @Test fun joinNeverForwardsBearerToAnotherSchemeHostPortOrDeployment() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        h.r.server = "https://localhost/paw"
        h.r.login()
        for (server in listOf("http://localhost/paw", "https://other.test/paw", "https://localhost:8443/paw", "https://localhost/paw2", "https://localhost/paw/child")) {
            val stage = h.stage(server)
            val requests = h.r.requests.size
            val reads = h.r.secrets.reads.size
            assertFalse(stage.destination.canJoin)
            assertSame(InviteAcceptanceIssue.WrongServer, assertFailsWith<InviteAcceptanceIssue> {
                h.service.accept(stage, InviteAcceptance.EXISTING_ACCOUNT)
            })
            assertEquals(requests, h.r.requests.size)
            assertEquals(reads, h.r.secrets.reads.size)
            assertFalse(stage.canAccept)
        }
    }

    @Test fun equivalentNormalizedDeploymentCanJoin() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        h.r.login()
        val stage = h.stage("HTTPS://EXAMPLE.test:443/paw/api/v1/")
        assertTrue(stage.destination.canJoin)
        assertTrue(h.service.accept(stage, InviteAcceptance.EXISTING_ACCOUNT).accepted)
        assertEquals(1, h.joinCalls)
    }

    @Test fun changedUserConnectionOrSignOutRejectsBothModesBeforeHTTP() = runTest {
        for (change in listOf("user", "connection", "signout")) {
            val h = InviteHarness(testScheduler, backgroundScope)
            h.r.login()
            val stages = InviteAcceptance.entries.associateWith { h.stage() }
            if (change == "signout") h.r.service.signOut()
            else {
                if (change == "user") h.r.user = SyncTestValues.otherUser
                h.r.login()
            }
            val requests = h.r.requests.size
            val reads = h.r.secrets.reads.size
            for ((mode, stage) in stages) {
                assertSame(InviteAcceptanceIssue.AccountChanged, assertFailsWith<InviteAcceptanceIssue> {
                    h.service.accept(stage, mode, "person", h.password, "Android")
                })
                assertFalse(stage.canAccept)
            }
            assertEquals(requests, h.r.requests.size)
            assertEquals(reads, h.r.secrets.reads.size)
            assertEquals(0, h.registerCalls)
            assertEquals(0, h.joinCalls)
        }
    }

    @Test fun signInAfterSignedOutStagingRejectsRegistrationAndJoin() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        val stages = InviteAcceptance.entries.associateWith { h.stage() }
        h.r.login()
        val requests = h.r.requests.size
        for ((mode, stage) in stages) {
            val error = assertFailsWith<InviteAcceptanceIssue> { h.service.accept(stage, mode, "person", h.password, "Android") }
            if (mode == InviteAcceptance.NEW_ACCOUNT) assertSame(InviteAcceptanceIssue.AccountChanged, error)
            else assertIs<InviteAcceptanceIssue.Account>(error)
        }
        assertEquals(requests, h.r.requests.size)
    }

    @Test fun registrationChecksPersistedAccountExpectationInsideAdmission() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        val stage = h.stage()
        val account = SyncAccount(h.r.binding.account, "person", h.r.device, "Android", UUID(2, 2))
        h.r.h.accounts.saveInactive(account, emptyList())
        assertSame(InviteAcceptanceIssue.AccountChanged, assertFailsWith<InviteAcceptanceIssue> { h.register(stage) })
        assertTrue(h.r.requests.isEmpty())
        assertTrue(h.r.secrets.reads.isEmpty())
        assertFalse(h.consumed)
    }

    @Test fun successfulRegistrationUsesAnonymousAuthThenBoundActivation() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        val result = h.register()
        assertTrue(result.accepted)
        assertNull(result.issue)
        assertTrue(result.snapshot.enabled)
        assertEquals(listOf(h.group), result.snapshot.me?.groups)
        assertEquals(listOf("register", "me"), h.r.requests.map { it.url.substringAfterLast('/') })
        val account = result.snapshot.account!!
        assertEquals(h.r.server, account.identity.serverURL)
        assertEquals(SecretTier.KEYSTORE, result.snapshot.tier)
        assertEquals(SyncAccountActivation.ENABLED, h.r.h.accounts.loadConnection().activation)
        val secret = h.r.secrets.values[account.secretAccount]!!.value.withValue { WireObject(WireJson.parse(it.encodeToByteArray())) }
        assertEquals(account.identity.serverURL, secret.string("server_url"))
        assertEquals(account.connectionID.toString(), secret.string("connection_id"))
        assertEquals(account.identity.userID.rawValue, secret.string("user_id"))
        h.assertNoInviteOrPasswordPersistence()
    }

    @Test fun explicitCrossServerRegistrationNeverSendsTheOldTokenAndHoldsOldFiles() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        val old = h.r.login().account!!
        h.r.h.files.put(EngineHarness.source(id = null), "old.md")
        val stage = h.stage("https://other.test/paw")
        val before = h.r.requests.size
        val oldToken = h.r.token
        h.r.user = SyncTestValues.otherUser
        h.r.token = "C".repeat(42) + "A"
        val result = h.register(stage)
        assertEquals("https://other.test/paw", result.snapshot.account?.identity?.serverURL)
        assertEquals(h.r.user, result.snapshot.account?.identity?.userID)
        val requests = h.r.requests.drop(before)
        assertTrue(requests.first().url.endsWith("/auth/register"))
        for (request in requests.filter { it.url.startsWith("https://other.test/") }) {
            assertFalse(request.headers.values.any { it.contains(oldToken) }, "Old bearer forwarded")
        }
        assertEquals(1, h.r.logouts.size)
        assertTrue(h.r.logouts.single().url.startsWith(old.identity.serverURL))
        assertEquals(1, h.r.h.accounts.binding(h.r.root)?.holds?.size)
        assertTrue("old.md" in h.r.h.files.bytesSnapshot())
        assertFalse(h.r.secrets.values.containsKey(old.secretAccount))
        h.assertNoInviteOrPasswordPersistence(listOf(oldToken))
    }

    @Test fun expiredUsedAndUnknownInvitesHaveFixedEndpointSpecificErrors() = runTest {
        for (state in listOf("expired", "used", "unknown")) for (mode in InviteAcceptance.entries) {
            val h = InviteHarness(testScheduler, backgroundScope)
            if (mode == InviteAcceptance.EXISTING_ACCOUNT) h.r.login()
            h.intercept = { request -> if (request.url.endsWith("/groups/join") || request.url.endsWith("/auth/register")) {
                EngineHarness.errorResponse(400, FailureCode.MALFORMED_REQUEST)
            } else null }
            val before = h.r.requests.size
            val stage = h.stage()
            val issue = assertFailsWith<InviteAcceptanceIssue>("Unavailable invite accepted ($state)") {
                h.service.accept(stage, mode, "person", h.password, "Android")
            }
            if (mode == InviteAcceptance.EXISTING_ACCOUNT) {
                assertSame(InviteAcceptanceIssue.UnavailableInvite, issue)
                assertEquals("This invite could not be used. It may have expired or already been used.", issue.message)
            } else {
                val account = assertIs<InviteAcceptanceIssue.Account>(issue)
                assertEquals(SyncHTTPClientError.MalformedRequest, assertIs<SyncAccountIssue.Http>(account.failure.issue).error)
                assertFalse(account.failure.registrationCommitted)
            }
            assertNull(issue.cause)
            assertEquals(before + 1, h.r.requests.size)
            assertTrue(h.r.logouts.isEmpty())
            assertFalse(stage.canAccept)
            h.assertNoInviteOrPasswordPersistence()
        }
    }

    @Test fun forbiddenMissingAndOfflineJoinErrorsStayTypedWithoutClaimingAcceptance() = runTest {
        for ((status, code, expected) in listOf(Triple(403, FailureCode.FORBIDDEN, SyncHTTPClientError.Forbidden),
            Triple(404, FailureCode.NOT_FOUND, SyncHTTPClientError.NotFound))) {
            val h = InviteHarness(testScheduler, backgroundScope)
            h.r.login()
            h.intercept = { if (it.url.endsWith("/groups/join")) EngineHarness.errorResponse(status, code) else null }
            val issue = assertIs<InviteAcceptanceIssue.Account>(assertFailsWith<InviteAcceptanceIssue> {
                h.service.accept(h.stage(), InviteAcceptance.EXISTING_ACCOUNT)
            })
            assertEquals(expected, assertIs<SyncAccountIssue.Http>(issue.failure.issue).error)
            assertTrue(h.r.service.snapshot.enabled)
        }
        val h = InviteHarness(testScheduler, backgroundScope)
        h.r.login()
        h.intercept = { if (it.url.endsWith("/groups/join")) throw IllegalStateException("secret diagnostic " + h.token) else null }
        val stage = h.stage()
        val error = assertFailsWith<InviteAcceptanceIssue> { h.service.accept(stage, InviteAcceptance.EXISTING_ACCOUNT) }
        assertFalse(error.stackTraceToString().contains(h.token), "Driver diagnostic leaked")
        assertNull(error.cause)
        assertFalse(stage.canAccept)
    }

    @Test fun unauthorizedJoinOrRefreshRetiresAuthenticationAndStopsSync() = runTest {
        for (endpoint in listOf("/groups/join", "/me")) {
            val h = InviteHarness(testScheduler, backgroundScope)
            h.r.login()
            h.intercept = { if (it.url.endsWith(endpoint)) EngineHarness.errorResponse(401, FailureCode.UNAUTHORIZED) else null }
            val stage = h.stage()
            if (endpoint == "/groups/join") assertIs<InviteAcceptanceIssue.Account>(assertFailsWith<InviteAcceptanceIssue> {
                h.service.accept(stage, InviteAcceptance.EXISTING_ACCOUNT)
            }) else {
                val result = h.service.accept(stage, InviteAcceptance.EXISTING_ACCOUNT)
                assertTrue(result.accepted)
                assertIs<InviteAcceptanceIssue.RefreshIncomplete>(result.issue)
                assertNull(result.snapshot.me)
            }
            assertFalse(h.r.service.snapshot.enabled)
            assertTrue(h.r.h.engine.reports.value.needsSignIn)
            assertFalse(h.r.h.engine.reports.value.enabled)
            val requests = h.r.requests.size
            h.r.h.engine.syncNow()
            h.r.h.engine.runBackground()
            assertEquals(requests, h.r.requests.size)
            assertFalse(stage.canAccept)
        }
    }

    @Test fun consumedJoinReportsRefreshFailureAndClearsStaleMembershipsWithoutRetry() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        h.joined = true
        h.membershipRole = Role.OWNER
        h.r.login()
        h.joined = false
        h.intercept = { if (it.url.endsWith("/me")) throw HttpTransportError.NetworkFailure else null }
        val stage = h.stage()
        val result = h.service.accept(stage, InviteAcceptance.EXISTING_ACCOUNT)
        assertTrue(result.accepted)
        val issue = assertIs<InviteAcceptanceIssue.RefreshIncomplete>(result.issue)
        assertEquals(HttpTransportError.NetworkFailure, assertIs<SyncHTTPClientError.Transport>(assertIs<SyncAccountIssue.Http>(issue.failure.issue).error).error)
        assertNull(result.snapshot.me)
        assertTrue(result.snapshot.enabled)
        assertEquals(1, h.joinCalls)
        assertSame(InviteAcceptanceIssue.NoInvite, assertFailsWith<InviteAcceptanceIssue> {
            h.service.accept(stage, InviteAcceptance.EXISTING_ACCOUNT)
        })
        h.intercept = null
        assertEquals(listOf(h.group), h.r.service.refresh().me?.groups)
        assertEquals(1, h.joinCalls)
    }

    @Test fun changedCurrentDeviceAfterConsumedJoinReportsPartialAndRequiresSignIn() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        h.r.login()
        h.r.me = { MeResponse(h.r.userDTO(), listOf(h.group), listOf(h.r.deviceDTO(SyncTestValues.otherUser))) }
        val result = h.service.accept(h.stage(), InviteAcceptance.EXISTING_ACCOUNT)
        assertTrue(result.accepted)
        assertEquals(SyncAccountIssue.TokenBindingMismatch, assertIs<InviteAcceptanceIssue.RefreshIncomplete>(result.issue).failure.issue)
        assertFalse(result.snapshot.enabled)
        assertNull(result.snapshot.me)
    }

    @Test fun registrationAuthenticationFailureNeverClaimsConsumptionOrCompensatesUnknownToken() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        h.intercept = { if (it.url.endsWith("/auth/register")) EngineHarness.errorResponse(401, FailureCode.UNAUTHORIZED) else null }
        val error = assertIs<InviteAcceptanceIssue.Account>(assertFailsWith<InviteAcceptanceIssue> { h.register() })
        assertFalse(error.failure.registrationCommitted)
        assertTrue(h.r.logouts.isEmpty())
        assertTrue(h.r.secrets.values.isEmpty())
        assertNull(h.r.h.accounts.loadAccount())
        h.assertNoInviteOrPasswordPersistence()
    }

    @Test fun registrationRequestRejectionDoesNotClaimTheInviteIsUnavailable() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        // A taken username has the same response as an unavailable invite.
        h.intercept = { if (it.url.endsWith("/auth/register")) EngineHarness.errorResponse(400, FailureCode.MALFORMED_REQUEST) else null }
        val stage = h.stage()
        val issue = assertIs<InviteAcceptanceIssue.Account>(assertFailsWith<InviteAcceptanceIssue> { h.register(stage) })
        assertEquals(SyncHTTPClientError.MalformedRequest, assertIs<SyncAccountIssue.Http>(issue.failure.issue).error)
        assertFalse(issue.failure.registrationCommitted)
        assertFalse(stage.canAccept)
        assertFalse(h.consumed)
        assertTrue(h.r.secrets.values.isEmpty())
        assertTrue(h.r.logouts.isEmpty())
        h.assertNoInviteOrPasswordPersistence()
    }

    @Test fun invalidRegistrationFieldsConsumeOnlyTheLocalStageBeforeAnyRequest() = runTest {
        for (field in listOf("username", "password", "device")) {
            val h = InviteHarness(testScheduler, backgroundScope)
            val stage = h.stage()
            val error = assertIs<InviteAcceptanceIssue.Account>(assertFailsWith<InviteAcceptanceIssue> {
                h.service.accept(stage, InviteAcceptance.NEW_ACCOUNT, if (field == "username") "UPPER" else "person",
                    if (field == "password") SecretValue("short") else h.password, if (field == "device") "" else "Android")
            })
            assertFalse(error.failure.registrationCommitted)
            assertFalse(stage.canAccept)
            assertTrue(h.r.requests.isEmpty())
            assertTrue(h.r.secrets.values.isEmpty())
            assertFalse(h.consumed)
            h.assertNoInviteOrPasswordPersistence()
        }
    }

    @Test fun failedAccountReplacementRetainsTheOldSecretAndCompensatesOnlyTheCandidate() = runTest {
        for (boundary in listOf("me", "write", "enabled")) {
            val h = InviteHarness(testScheduler, backgroundScope)
            val old = h.r.login().account!!
            val oldSecret = h.r.secrets.values.getValue(old.secretAccount)
            val oldToken = h.r.token
            val stage = h.stage("https://other.test/paw")
            h.r.user = SyncTestValues.otherUser
            h.r.token = "C".repeat(42) + "A"
            when (boundary) {
                "me" -> h.intercept = { if (it.url.endsWith("/me")) throw HttpTransportError.NetworkFailure else null }
                "write" -> h.r.secrets.writeError = SecretStoreError.WriteFailed
                "enabled" -> {
                    var publications = 0
                    h.r.h.data.fault = { op, path -> if (op == MemoryStore.Operation.PRIVATE_WRITE && path == "sync/account.json" && ++publications == 3) StoreError.IOFailure else null }
                }
            }
            val result = h.register(stage)
            assertIs<InviteAcceptanceIssue.RegistrationIncomplete>(result.issue)
            assertEquals(old, result.snapshot.account)
            assertEquals(old, h.r.h.accounts.loadAccount())
            assertEquals(oldSecret, h.r.secrets.values[old.secretAccount])
            assertEquals(1, h.r.secrets.values.size)
            assertEquals(boundary == "me", result.snapshot.enabled)
            assertEquals(1, h.r.logouts.size)
            assertTrue(h.r.logouts.single().url.startsWith("https://other.test/"))
            assertTrue(h.r.puts.isEmpty())
            if (boundary != "me") {
                assertEquals(SyncAccountActivation.INACTIVE, h.r.h.accounts.loadConnection().activation)
                val requests = h.r.requests.size
                h.r.reopen().startup()
                assertEquals(requests, h.r.requests.size)
            }
            h.assertNoInviteOrPasswordPersistence(listOf(oldToken))
        }
    }

    @Test fun remotelyConsumedRegistrationCompensatesEveryActivationBoundary() = runTest {
        for (boundary in listOf("me", "identity", "read", "write", "inactive", "enabled", "flush", "reserved")) {
            val h = InviteHarness(testScheduler, backgroundScope)
            when (boundary) {
                "me" -> h.intercept = { if (it.url.endsWith("/me")) throw HttpTransportError.NetworkFailure else null }
                "identity" -> h.r.me = { MeResponse(h.r.userDTO(SyncTestValues.otherUser), emptyList(), listOf(h.r.deviceDTO())) }
                "read" -> h.r.secrets.readError = SecretStoreError.ReadFailed
                "write" -> h.r.secrets.writeError = SecretStoreError.WriteFailed
                "inactive", "enabled" -> {
                    var writes = 0
                    val failAt = if (boundary == "inactive") 2 else 3
                    h.r.h.data.fault = { op, path -> if (op == MemoryStore.Operation.PRIVATE_WRITE && path == "sync/account.json" && ++writes == failAt) StoreError.IOFailure else null }
                }
                "flush" -> {
                    var flushes = 0
                    h.r.h.rig.dataOperations.onOperation = { if (it == "file:sync/account.json" && ++flushes == 3) throw StoreError.IOFailure }
                }
                "reserved" -> h.r.h.rig.libraryOperations.putDirectory("Groups")
            }
            val stage = h.stage()
            val result = h.register(stage)
            val issue = assertIs<InviteAcceptanceIssue.RegistrationIncomplete>(result.issue, "Activation failure was hidden ($boundary)")
            assertTrue(result.accepted)
            assertTrue(issue.failure.registrationCommitted)
            assertFalse(result.snapshot.enabled)
            assertEquals(SyncRemoteRevocation.REVOKED, result.cleanup.remote)
            assertEquals(1, h.r.logouts.size)
            assertTrue(h.r.secrets.values.isEmpty())
            assertFalse(stage.canAccept)
            assertTrue(h.consumed)
            val requests = h.r.requests.size
            h.r.reopen().startup()
            assertEquals(requests, h.r.requests.size)
            assertEquals(1, h.registerCalls)
            h.assertNoInviteOrPasswordPersistence()
        }
    }

    @Test fun consumedRegistrationRecoversBySignInWithoutRedeemingAgain() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        h.r.secrets.writeError = SecretStoreError.WriteFailed
        val result = h.register()
        assertIs<InviteAcceptanceIssue.RegistrationIncomplete>(result.issue)
        assertTrue(h.consumed)
        val rejected = assertIs<InviteAcceptanceIssue.Account>(assertFailsWith<InviteAcceptanceIssue> { h.register() })
        assertEquals(SyncHTTPClientError.MalformedRequest, assertIs<SyncAccountIssue.Http>(rejected.failure.issue).error)
        assertEquals(2, h.registerCalls)
        h.r.secrets.writeError = null
        val newService = h.r.reopen()
        val recovered = newService.login(h.r.server, "person", h.password, "Android")
        assertTrue(recovered.enabled)
        assertEquals(listOf(h.group), recovered.me?.groups)
        assertEquals(2, h.registerCalls)
        assertEquals(1, h.r.requests.count { it.url.endsWith("/auth/login") })
        h.assertNoInviteOrPasswordPersistence()
    }

    @Test fun incompleteCompensationPreservesCleanupUUIDAndReportsItForExplicitRetry() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        h.r.h.rig.libraryOperations.putDirectory("Groups")
        h.r.secrets.deleteError = SecretStoreError.DeleteFailed
        h.intercept = { if (it.url.endsWith("/auth/logout")) throw HttpTransportError.NetworkFailure else null }
        val id = h.r.nextID
        val result = h.register()
        assertIs<InviteAcceptanceIssue.RegistrationIncomplete>(result.issue)
        assertFalse(result.cleanup.isComplete)
        assertEquals(SyncRemoteRevocation.UNCONFIRMED, result.cleanup.remote)
        assertEquals(listOf(id), result.cleanup.secretFailures)
        assertEquals(listOf(id), h.r.h.rig.restart().accounts.loadConnection().cleanupConnections)
        h.r.secrets.deleteError = null
        h.intercept = null
        assertTrue(h.r.reopen().signOut().isComplete)
        assertTrue(h.r.secrets.values.isEmpty())
        assertTrue(h.r.h.accounts.loadConnection().cleanupConnections.isEmpty())
        h.assertNoInviteOrPasswordPersistence()
    }

    @Test fun accountBusyAndRepeatedAcceptCannotDispatchAnInvitation() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        h.r.login()
        val stage = h.stage()
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        h.intercept = { if (it.url.endsWith("/me")) { started.complete(Unit); release.await() }; null }
        val pending = async { h.r.service.refresh() }
        started.await()
        val before = h.r.requests.size
        val issue = assertIs<InviteAcceptanceIssue.Account>(assertFailsWith<InviteAcceptanceIssue> {
            h.service.accept(stage, InviteAcceptance.EXISTING_ACCOUNT)
        })
        assertEquals(SyncAccountIssue.Busy, issue.failure.issue)
        assertFalse(stage.canAccept)
        assertSame(InviteAcceptanceIssue.NoInvite, assertFailsWith<InviteAcceptanceIssue> {
            h.service.accept(stage, InviteAcceptance.EXISTING_ACCOUNT)
        })
        assertEquals(before, h.r.requests.size)
        release.complete(Unit)
        pending.await()
        assertFalse(h.r.service.isBusy)
    }

    @Test fun concurrentAcceptDispatchesTheSingleUseInviteOnce() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        h.r.login()
        val stage = h.stage()
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        h.intercept = { if (it.url.endsWith("/groups/join")) { started.complete(Unit); release.await() }; null }
        val pending = async { h.service.accept(stage, InviteAcceptance.EXISTING_ACCOUNT) }
        started.await()
        assertSame(InviteAcceptanceIssue.NoInvite, assertFailsWith<InviteAcceptanceIssue> {
            h.service.accept(stage, InviteAcceptance.EXISTING_ACCOUNT)
        })
        release.complete(Unit)
        assertTrue(pending.await().accepted)
        assertEquals(1, h.joinCalls)
    }

    @Test fun cancellationDuringJoinDropsTheStageAndRetainsNoAutomaticRetry() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        h.r.login()
        val stage = h.stage()
        val started = CompletableDeferred<Unit>()
        h.intercept = { if (it.url.endsWith("/groups/join")) { started.complete(Unit); awaitCancellation() }; null }
        val task = async { h.service.accept(stage, InviteAcceptance.EXISTING_ACCOUNT) }
        started.await()
        task.cancelAndJoin()
        assertFalse(h.r.service.isBusy)
        assertTrue(h.r.service.snapshot.enabled)
        assertFalse(h.r.h.engine.reports.value.needsSignIn)
        assertFalse(stage.canAccept)
        assertEquals(1, h.r.requests.count { it.url.endsWith("/groups/join") })
        assertSame(InviteAcceptanceIssue.NoInvite, assertFailsWith<InviteAcceptanceIssue> { h.service.accept(stage, InviteAcceptance.EXISTING_ACCOUNT) })
        h.assertNoInviteOrPasswordPersistence()
    }

    @Test fun cancellationDuringRegistrationSecretWriteFinishesCompensationBeforeReturning() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        val stage = h.stage()
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        h.r.secrets.beforeWrite = { started.complete(Unit); release.await() }
        val task = async { h.register(stage) }
        try {
            started.await()
            task.cancel()
            runCurrent()
            assertFalse(task.isCompleted)
            assertTrue(h.r.service.isBusy)
        } finally { release.complete(Unit) }
        task.join()
        assertFalse(h.r.service.isBusy)
        assertTrue(h.r.secrets.values.isEmpty())
        assertEquals(1, h.r.logouts.size)
        assertFalse(h.r.service.snapshot.enabled)
        assertFalse(stage.canAccept)
        assertTrue(h.consumed)
        h.assertNoInviteOrPasswordPersistence()
    }

    @Test fun allInviteOutputsErrorsAndDescriptionsRedactRuntimeCredentials() = runTest {
        val h = InviteHarness(testScheduler, backgroundScope)
        h.r.secrets.writeError = SecretStoreError.WriteFailed
        val stage = h.stage()
        val result = h.register(stage)
        val values = listOf(stage, stage.destination, h.service, result, result.snapshot, result.cleanup, result.issue,
            (result.issue as InviteAcceptanceIssue.RegistrationIncomplete).failure)
        for (value in values) {
            val text = value.toString() + ((value as? Throwable)?.stackTraceToString().orEmpty())
            assertFalse(text.contains(h.token) || text.contains(h.link), "Invite in diagnostics")
            h.password.withValue { assertFalse(text.contains(it), "Password in diagnostics") }
        }
        assertFalse(h.r.service.snapshot.toString().contains(h.token))
        h.assertNoInviteOrPasswordPersistence()
    }
}
