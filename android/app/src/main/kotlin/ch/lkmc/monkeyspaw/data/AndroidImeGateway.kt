package ch.lkmc.monkeyspaw.data

import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.IBinder
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import ch.lkmc.monkeyspaw.ime.ImeEditor

/** Framework access stays on the service thread, with no target-text APIs or cached connection. */
internal class AndroidImeGateway(
    private val service: InputMethodService,
    private val inFillActivity: () -> Boolean,
) : ImeDeliveryGateway, ImeSwitchGateway {
    override val api: Int get() = Build.VERSION.SDK_INT

    override fun editor(): ImeEditor = editor(service.currentInputEditorInfo)
    fun editor(info: EditorInfo?): ImeEditor = ImeEditor(
        info?.inputType, info?.imeOptions ?: 0, service.currentInputConnection, inFillActivity(),
    )

    override fun commitText(editor: ImeEditor, text: String, newCursorPosition: Int): Boolean? {
        val connection = service.currentInputConnection ?: return null
        if (!editor.matches(editor()) || !editor.matchesConnection(connection)) return null
        return connection.commitText(text, newCursorPosition)
    }

    override fun previous(): Boolean = if (Build.VERSION.SDK_INT >= 28) service.switchToPreviousInputMethod() else false
    override fun windowToken(): Any? = service.window?.window?.attributes?.token

    @Suppress("DEPRECATION")
    override fun last(token: Any): Boolean = manager()?.switchToLastInputMethod(token as IBinder) == true

    override fun picker(): Boolean {
        val manager = manager() ?: return false
        manager.showInputMethodPicker()
        return true
    }

    private fun manager(): InputMethodManager? = service.getSystemService(InputMethodManager::class.java)
}
