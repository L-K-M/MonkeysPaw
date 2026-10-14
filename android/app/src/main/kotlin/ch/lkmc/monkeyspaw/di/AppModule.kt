package ch.lkmc.monkeyspaw.di

import android.content.Context
import androidx.datastore.core.DataStoreFactory
import ch.lkmc.monkeyspaw.core.ports.*
import ch.lkmc.monkeyspaw.core.services.EditingService
import ch.lkmc.monkeyspaw.core.services.LibraryService
import ch.lkmc.monkeyspaw.data.*
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.*
import java.io.File
import java.security.SecureRandom
import java.time.Instant
import java.util.logging.Logger
import javax.inject.Qualifier
import javax.inject.Singleton

@Qualifier
@Retention(AnnotationRetention.BINARY)
internal annotation class IoDispatcher

@Qualifier
@Retention(AnnotationRetention.BINARY)
internal annotation class ApplicationScope

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
    fun state(@ApplicationContext context: Context): StateStore = AndroidStateStore(File(context.filesDir, "state"))

    @Provides
    @Singleton
    fun clock(): Clock = Clock { Instant.now() }

    @Provides
    @Singleton
    fun entropy(): Entropy {
        val random = SecureRandom()
        return Entropy { count -> ByteArray(count).also(random::nextBytes) }
    }

    @Provides
    @Singleton
    fun library(prompts: PromptStore, state: StateStore, clock: Clock, entropy: Entropy): LibraryService =
        LibraryService(prompts, state, clock, entropy)

    @Provides
    @Singleton
    fun editing(library: LibraryService): EditingService = EditingService(library)

    @Provides
    @Singleton
    fun repository(library: LibraryService, editing: EditingService, prompts: AndroidPromptStore,
        @IoDispatcher io: CoroutineDispatcher): LibraryRepository = LibraryRepository(library, editing, prompts, io)

    @Provides
    @Singleton
    fun settings(@ApplicationContext context: Context, @ApplicationScope scope: CoroutineScope): AndroidSettingsStore =
        AndroidSettingsStore(DataStoreFactory.create(serializer = SettingsSerializer, scope = scope,
            produceFile = { File(context.filesDir, "datastore/settings.json") }))

    @Provides
    @Singleton
    fun seedCatalog(@ApplicationContext context: Context): AndroidSeedCatalog =
        AndroidSeedCatalog { path -> context.assets.open(path).use { it.readBytes() } }

    @Provides
    @Singleton
    fun seedInstaller(repository: LibraryRepository, settings: AndroidSettingsStore, catalog: AndroidSeedCatalog,
        @IoDispatcher io: CoroutineDispatcher): SeedInstaller = SeedInstaller(repository, settings, catalog, io)
}
