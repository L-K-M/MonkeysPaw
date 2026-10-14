package ch.lkmc.monkeyspaw.entry

import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.ChecksSdkIntAtLeast
import ch.lkmc.monkeyspaw.R

class PromptTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        qsTile?.apply {
            state = Tile.STATE_INACTIVE
            label = getString(R.string.entry_insert_prompt)
            updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        TileLaunchPolicy.click(isLocked, { unlockAndRun(it) }, ::openFill)
    }

    private fun openFill() {
        val route = FillRoute(EntrySource.TILE)
        if (TileLaunchPolicy.usesPendingIntent()) {
            startActivityAndCollapse(route.pendingIntent(this))
        } else {
            // Lint checks targetSdk, but API 26-33 only has this overload; the runtime guard excludes 34+.
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(route.intent(this))
        }
    }
}

/** Pure policy seam: JVM tests exercise the version boundary and the unlock callback ordering. */
internal object TileLaunchPolicy {
    @ChecksSdkIntAtLeast(api = 34)
    fun usesPendingIntent(apiLevel: Int = Build.VERSION.SDK_INT): Boolean = apiLevel >= 34

    fun click(locked: Boolean, unlock: (() -> Unit) -> Unit, launch: () -> Unit) {
        if (locked) unlock(launch) else launch()
    }
}
