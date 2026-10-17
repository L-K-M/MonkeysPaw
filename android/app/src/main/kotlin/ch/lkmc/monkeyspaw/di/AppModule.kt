package ch.lkmc.monkeyspaw.di

import android.content.Context
import androidx.datastore.core.DataStoreFactory
import androidx.hilt.work.HiltWorkerFactory
import androidx.work.WorkerFactory
import android.os.Build
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.EditingService
import ch.lkmc.monkeyspaw.core.services.FillService
import ch.lkmc.monkeyspaw.core.services.LibraryService
import ch.lkmc.monkeyspaw.core.services.ProviderSettingsStore
import ch.lkmc.monkeyspaw.core.services.ProviderSettingsService
import ch.lkmc.monkeyspaw.core.services.ProviderStateStore
import ch.lkmc.monkeyspaw.core.services.AssistantConnectionService
import ch.lkmc.monkeyspaw.core.services.AssistantAccess
import ch.lkmc.monkeyspaw.core.services.AssistantService
import ch.lkmc.monkeyspaw.core.llm.AnthropicClient
import ch.lkmc.monkeyspaw.core.llm.OpenAIClient
import ch.lkmc.monkeyspaw.core.services.SyncEngine
import ch.lkmc.monkeyspaw.core.services.SyncAccountService
import ch.lkmc.monkeyspaw.data.*
import dagger.Module
import dagger.Provides
import dagger.Lazy
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.*
import okhttp3.OkHttp
import java.io.File
import java.security.SecureRandom
import java.util.logging.Logger
import javax.inject.Qualifier
import javax.inject.Singleton

@Qualifier
@Retention(AnnotationRetention.BINARY)
internal annotation class IoDispatcher

@Qualifier
@Retention(AnnotationRetention.BINARY)
internal annotation class ApplicationScope

@Qualifier
@Retention(AnnotationRetention.BINARY)
internal annotation class SyncWorkerFactory

@Module
@InstallIn(SingletonComponent::class)
internal object AppModule {
    @Provides
    @IoDispatcher
    fun ioDispatcher(): CoroutineDispatcher = Dispatchers.IO

    @Provides
    @Singleton
    @ApplicationScope
    fun applicationScope(@IoDispatcher io: CoroutineDispatcher): CoroutineScope =
        CoroutineScope(SupervisorJob() + io + CoroutineExceptionHandler { _, _ ->
            Logger.getLogger("MonkeysPaw").severe("Application background operation failed.")
        })

    @Provides
    @Singleton
    fun prompts(@ApplicationContext context: Context): AndroidPromptStore = AndroidPromptStore(File(context.filesDir, "library"))

    @Provides
    fun promptStore(prompts: AndroidPromptStore): PromptStore = prompts

    @Provides
    @Singleton
    fun state(@ApplicationContext context: Context, settings: AndroidSettingsStore): AndroidStateStore =
        AndroidStateStore(File(context.filesDir, "state"), settings = settings)

    @Provides
    @Singleton
    fun stateStore(state: AndroidStateStore): StateStore = state

    @Provides
    @Singleton
    fun androidClock(): AndroidClock = AndroidClock()

    @Provides
    @Singleton
    fun clock(clock: AndroidClock): Clock = clock

    @Provides
    @Singleton
    fun clipboard(@ApplicationContext context: Context): Clipboard = AndroidClipboard(context)

    @Provides
    @Singleton
    fun fill(library: LibraryService, clipboard: Clipboard, clock: AndroidClock): FillService =
        FillService(library, clipboard, clock::zone)

    @Provides
    @Singleton
    fun monotonicClock(): MonotonicClock = MonotonicClock(System::nanoTime)

    @Provides
    @Singleton
    fun httpTransport(@ApplicationContext context: Context, clock: MonotonicClock,
        @ApplicationScope scope: CoroutineScope): HttpTransport {
        // Preserve OkHttp's Android context setup, outside component-only/IME startup.
        OkHttp.initialize(context)
        return OkHttpHttpTransport(clock, scope, syncTlsTrust = AndroidSyncTlsTrust())
    }

    @Provides
    @Singleton
    fun entropy(): Entropy {
        val random = SecureRandom()
        return Entropy { count -> ByteArray(count).also(random::nextBytes) }
    }

    @Provides
    @Singleton
    fun library(prompts: PromptStore, state: StateStore, clock: Clock, entropy: Entropy,
        access: AssistantAccess): LibraryService = LibraryService(prompts, state, clock, entropy, access)

    // Z18 supplies live group roles through this same authority for context and publication.
    @Provides
    @Singleton
    fun assistantAccess(): AssistantAccess = AssistantAccess.LOCAL

    @Provides
    @Singleton
    fun editing(library: LibraryService): EditingService = EditingService(library)

    @Provides
    @Singleton
    fun repository(library: LibraryService, editing: EditingService, prompts: AndroidPromptStore,
        @IoDispatcher io: CoroutineDispatcher, startup: AndroidSyncStartup): LibraryRepository =
        LibraryRepository(library, editing, prompts, io) { startup.ready() }

    @Provides
    @Singleton
    fun syncStartup(@ApplicationContext context: Context, library: LibraryService, prompts: AndroidPromptStore,
        state: AndroidStateStore, @IoDispatcher io: CoroutineDispatcher): AndroidSyncStartup =
        AndroidSyncStartup(library, prompts, state, File(context.filesDir, "library").absolutePath, io)

    @Provides
    @Singleton
    fun syncRepository(startup: AndroidSyncStartup, library: LibraryService, repository: LibraryRepository,
        @ApplicationScope scope: CoroutineScope, @IoDispatcher io: CoroutineDispatcher, clock: Clock,
        entropy: Entropy, monotonic: MonotonicClock, secrets: Lazy<SecretStore>, http: Lazy<HttpTransport>,
        settings: AndroidSettingsStore, work: SyncWorkHooks = SyncWorkHooks.None): AndroidSyncRepository =
        AndroidSyncRepository(startup, library, repository, scope, io,
            { local -> SyncEngine(local, scope, io, clock, entropy, monotonic) },
            { engine, local -> SyncAccountService(engine, local.accounts, secrets.get(), http.get(), startup.libraryRoot, io, monotonic,
                tlsTrust = { server -> settings.read().syncTls?.trustFor(server) ?: SyncTLSTrust.SYSTEM }) }, settings, work)

    @Provides
    @Singleton
    fun syncWorkHooks(scheduler: Lazy<SyncWorkScheduler>): SyncWorkHooks = object : SyncWorkHooks {
        override suspend fun authenticated(connection: String) { scheduler.get().authenticated(connection) }
        override suspend fun signedOut() { scheduler.get().signedOut() }
        override suspend fun authenticationStopped() = scheduler.get().authenticationStopped()
        override suspend fun saved() { scheduler.get().saved() }
        override suspend fun changed() { scheduler.get().changed() }
    }

    @Provides
    @Singleton
    fun syncWorkScheduler(@ApplicationContext context: Context, startup: AndroidSyncStartup, state: AndroidStateStore,
        repository: Lazy<AndroidSyncRepository>, clock: Clock, @IoDispatcher io: CoroutineDispatcher): SyncWorkScheduler =
        SyncWorkScheduler(SyncWorkPolicy(SyncWorkStateStore(state, state.syncOperations), AndroidSyncWorkQueue(context),
            AndroidSyncWorkSession(startup, repository), { clock.now().toEpochMilli() }, Build.VERSION.SDK_INT), io)

    @Provides
    @Singleton
    @SyncWorkerFactory
    fun syncWorkerFactory(factory: HiltWorkerFactory): WorkerFactory = factory

    @Provides
    @Singleton
    fun settings(@ApplicationContext context: Context, @IoDispatcher io: CoroutineDispatcher): AndroidSettingsStore =
        // DataStore returns IO failures to callers; its private scope must not emit IME diagnostics.
        AndroidSettingsStore(DataStoreFactory.create(serializer = SettingsSerializer,
            scope = CoroutineScope(SupervisorJob() + io + CoroutineExceptionHandler { _, _ -> }),
            produceFile = { File(context.filesDir, "datastore/settings.json") }))

    @Provides
    @Singleton
    fun seedCatalog(@ApplicationContext context: Context): AndroidSeedCatalog =
        AndroidSeedCatalog { path -> context.assets.open(path).use { it.readBytes() } }

    @Provides
    @Singleton
    fun seedInstaller(repository: LibraryRepository, settings: AndroidSettingsStore, catalog: AndroidSeedCatalog,
        @IoDispatcher io: CoroutineDispatcher): SeedInstaller = SeedInstaller(repository, settings, catalog, io)

    @Provides
    @Singleton
    fun secrets(@ApplicationContext context: Context, @ApplicationScope scope: CoroutineScope,
        @IoDispatcher io: CoroutineDispatcher): SecretStore =
        AndroidKeystoreSecretStore(DataStoreFactory.create(serializer = SecretsSerializer, scope = scope,
            produceFile = { File(context.filesDir, "datastore/secrets.json") }), AndroidKeystoreKeyProvider(context), io)

    // Resolve provider services through Lazy on IO: the metadata store loads synchronously.
    @Provides
    @Singleton
    fun providerSettingsStore(state: StateStore): ProviderSettingsStore = ProviderSettingsStore(state)

    @Provides
    @Singleton
    fun providerSettings(store: ProviderSettingsStore, secrets: SecretStore,
        @IoDispatcher io: CoroutineDispatcher): ProviderSettingsService = ProviderSettingsService(store, secrets, io)

    @Provides
    @Singleton
    fun providerState(state: StateStore): ProviderStateStore = ProviderStateStore(state)

    @Provides
    @Singleton
    fun anthropic(transport: HttpTransport, clock: MonotonicClock, utc: Clock): AnthropicClient =
        AnthropicClient(transport, clock, utc::now)

    @Provides
    @Singleton
    fun openAI(transport: HttpTransport, state: ProviderStateStore, clock: MonotonicClock, utc: Clock): OpenAIClient =
        OpenAIClient(transport, state, clock, utc::now)

    @Provides
    @Singleton
    fun assistantConnection(settings: ProviderSettingsService, anthropic: AnthropicClient,
        openAI: OpenAIClient, clock: MonotonicClock, @IoDispatcher io: CoroutineDispatcher): AssistantConnectionService =
        AssistantConnectionService(settings, anthropic, openAI, io, Dispatchers.Main.immediate, clock)

    @Provides
    @Singleton
    fun assistantService(settings: ProviderSettingsService, anthropic: AnthropicClient, openAI: OpenAIClient,
        @IoDispatcher io: CoroutineDispatcher, utc: Clock, entropy: Entropy, clock: MonotonicClock): AssistantService =
        AssistantService(settings, anthropic, openAI, io, utc, entropy, clock)

    @Provides
    @Singleton
    fun assistantGraph(service: AssistantService, access: AssistantAccess, clock: MonotonicClock): AssistantGraph =
        AssistantGraph(service, access, clock)

    @Provides
    @Singleton
    fun providerChanges(): AssistantProviderChanges = AssistantProviderChanges()
}
