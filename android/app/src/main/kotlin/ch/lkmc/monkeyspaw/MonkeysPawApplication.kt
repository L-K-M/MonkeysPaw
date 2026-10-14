package ch.lkmc.monkeyspaw

import android.app.Application
import ch.lkmc.monkeyspaw.data.LibraryRepository
import ch.lkmc.monkeyspaw.di.ApplicationScope
import dagger.hilt.android.HiltAndroidApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltAndroidApp
class MonkeysPawApplication : Application() {
    @Inject internal lateinit var library: LibraryRepository
    @Inject @ApplicationScope internal lateinit var scope: CoroutineScope

    override fun onCreate() {
        super.onCreate()
        // The repository recovers local journals before this read. Authentication is an explicit entry intent.
        scope.launch { library.refresh() }
    }
}
