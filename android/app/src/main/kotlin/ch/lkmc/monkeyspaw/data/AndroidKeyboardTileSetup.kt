package ch.lkmc.monkeyspaw.data

import android.app.Activity
import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import androidx.annotation.ChecksSdkIntAtLeast
import ch.lkmc.monkeyspaw.R
import ch.lkmc.monkeyspaw.entry.PromptTileService
import ch.lkmc.monkeyspaw.ime.MonkeysPawImeService

internal data class KeyboardSetupStatus(val enabled: Boolean? = null, val selected: Boolean? = null)
internal enum class TileAddResult { ADDED, ALREADY_ADDED, DENIED, ERROR }

/** Activity-bound port, held by the model only while the launcher is resumed. */
internal interface KeyboardTileSetup {
    val supportsTileRequest: Boolean
    fun keyboardStatus(): KeyboardSetupStatus
    fun openKeyboardSettings(): Boolean
    fun showKeyboardPicker(): Boolean
    fun requestTile(result: (TileAddResult) -> Unit)
}

internal class AndroidKeyboardTileSetup(private val activity: Activity) : KeyboardTileSetup {
    private val keyboard = ComponentName(activity, MonkeysPawImeService::class.java)
    override val supportsTileRequest: Boolean get() = KeyboardTileSetupApi.canRequestTile()

    override fun keyboardStatus(): KeyboardSetupStatus {
        val manager = activity.getSystemService(InputMethodManager::class.java)
        val enabled = try {
            manager?.enabledInputMethodList?.any { it.component == keyboard }
        } catch (_: Exception) { null }
        val selected = try {
            val current = if (KeyboardTileSetupApi.hasCurrentInputMethodInfo()) {
                manager?.currentInputMethodInfo?.component
            } else {
                Settings.Secure.getString(activity.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
                    ?.let(ComponentName::unflattenFromString)
            }
            current?.let { it == keyboard }
        } catch (_: Exception) { null }
        return KeyboardSetupStatus(enabled, selected)
    }

    override fun openKeyboardSettings(): Boolean = try {
        activity.startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        true
    } catch (_: Exception) { false }

    override fun showKeyboardPicker(): Boolean = try {
        val manager = activity.getSystemService(InputMethodManager::class.java)
        if (manager == null) false else {
            manager.showInputMethodPicker()
            true
        }
    } catch (_: Exception) { false }

    override fun requestTile(result: (TileAddResult) -> Unit) {
        if (!KeyboardTileSetupApi.canRequestTile()) {
            result(TileAddResult.ERROR)
            return
        }
        try {
            val manager = activity.getSystemService(StatusBarManager::class.java)
            if (manager == null) {
                result(TileAddResult.ERROR)
                return
            }
            manager.requestAddTileService(ComponentName(activity, PromptTileService::class.java),
                activity.getString(R.string.entry_insert_prompt), Icon.createWithResource(activity, R.drawable.ic_paw),
                activity.mainExecutor) { result(KeyboardTileSetupApi.tileResult(it)) }
        } catch (_: Exception) { result(TileAddResult.ERROR) }
    }
}

internal object KeyboardTileSetupApi {
    @ChecksSdkIntAtLeast(api = 34)
    fun hasCurrentInputMethodInfo(api: Int = Build.VERSION.SDK_INT): Boolean = api >= 34

    @ChecksSdkIntAtLeast(api = 33)
    fun canRequestTile(api: Int = Build.VERSION.SDK_INT): Boolean = api >= 33

    fun tileResult(result: Int): TileAddResult = when (result) {
        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> TileAddResult.ADDED
        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> TileAddResult.ALREADY_ADDED
        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> TileAddResult.DENIED
        else -> TileAddResult.ERROR
    }
}
