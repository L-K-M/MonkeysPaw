package ch.lkmc.monkeyspaw

import android.app.Application
import androidx.work.Configuration
import androidx.work.WorkerFactory
import ch.lkmc.monkeyspaw.data.LibraryRepository
import ch.lkmc.monkeyspaw.di.ApplicationScope
import ch.lkmc.monkeyspaw.di.SyncWorkerFactory
import dagger.Lazy
import dagger.hilt.android.HiltAndroidApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltAndroidApp
class MonkeysPawApplication : Application(), Configuration.Provider {
    @Inject internal lateinit var library: LibraryRepository
    @Inject @ApplicationScope internal lateinit var scope: CoroutineScope
    @Inject @SyncWorkerFactory internal lateinit var workerFactory: Lazy<WorkerFactory>

    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder().setWorkerFactory(workerFactory.get()).build()

    override fun onCreate() {
        super.onCreate()
        // The repository recovers local journals before this read. Authentication is an explicit entry intent.
        scope.launch { library.refresh() }
    }
}
