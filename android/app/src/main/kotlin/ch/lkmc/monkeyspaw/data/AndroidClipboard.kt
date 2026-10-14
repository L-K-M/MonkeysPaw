package ch.lkmc.monkeyspaw.data

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Looper
import android.os.PersistableBundle
import ch.lkmc.monkeyspaw.core.AppIdentity
import ch.lkmc.monkeyspaw.core.ports.Clipboard
import ch.lkmc.monkeyspaw.core.ports.StoreError
import java.util.concurrent.CancellationException

/** Small system-service boundary so JVM tests need no Android runtime. */
internal interface AndroidClipboardAccess {
    fun readText(): String?
    fun writeText(text: String, extras: Map<String, Boolean>)
}

internal class AndroidClipboard(private val access: AndroidClipboardAccess) : Clipboard {
    constructor(context: Context) : this(SystemClipboardAccess(context))

    override fun readText(completion: (String?) -> Unit) {
        val text = try { access.readText() } catch (_: Exception) { null }
        // Invoke outside the read catch: a caller failure must not trigger a second completion.
        completion(text)
    }

    override fun writeText(text: String) {
        try { access.writeText(text, mapOf(sensitiveExtra to true)) }
        catch (error: Exception) {
            when (error) {
                is CancellationException -> throw error
                is InterruptedException -> { Thread.currentThread().interrupt(); throw error }
                else -> throw StoreError.IOFailure
            }
        }
    }

    companion object {
        // The documented string key works on API 26 too; the named constant was added in API 33.
        const val sensitiveExtra = "android.content.extra.IS_SENSITIVE"
    }
}

private class SystemClipboardAccess(private val context: Context) : AndroidClipboardAccess {
    private fun manager(): ClipboardManager {
        check(Looper.myLooper() == Looper.getMainLooper())
        return context.getSystemService(ClipboardManager::class.java) ?: throw StoreError.IOFailure
    }

    override fun readText(): String? {
        val clip = manager().primaryClip ?: return null
        // Text only: coercing a URI could read a provider or load a file while opening the form.
        return if (clip.itemCount > 0) clip.getItemAt(0).text?.toString() else null
    }

    override fun writeText(text: String, extras: Map<String, Boolean>) {
        val clip = ClipData.newPlainText(AppIdentity.displayName, text)
        clip.description.extras = PersistableBundle().apply {
            for ((key, value) in extras) putBoolean(key, value)
        }
        manager().setPrimaryClip(clip)
    }
}
