package ch.lkmc.monkeyspaw.ui.settings

import android.content.Context
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView

/** Disable Android view hierarchy saving and autofill; never put raw text into Compose state. */
@Composable
internal fun AssistantSettingsKeyField(reset: Long, editable: Boolean, placeholder: String,
    onInput: (String) -> Unit, modifier: Modifier = Modifier) {
    AndroidView(factory = { SecureKeyField(it) }, modifier = modifier,
        onRelease = { it.retire() }, update = { it.update(reset, editable, placeholder, onInput) })
}

private class SecureKeyField(context: Context) : EditText(context) {
    private var reset: Long? = null
    private var updating = false
    private var onInput: ((String) -> Unit)? = null

    init {
        // Set single-line first; older Android otherwise replaces the password mask.
        isSingleLine = true
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        imeOptions = EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        isSaveEnabled = false
        isSaveFromParentEnabled = false
        importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) { if (!updating && isEnabled) onInput?.invoke(s?.toString().orEmpty()) }
        })
    }

    fun update(token: Long, editable: Boolean, placeholder: String, onInput: (String) -> Unit) {
        this.onInput = onInput
        isEnabled = editable
        hint = placeholder
        contentDescription = placeholder
        if (reset == token) return
        reset = token
        clear()
    }

    fun retire() { onInput = null; clear() }

    private fun clear() {
        updating = true
        text?.clear()
        updating = false
    }

    override fun toString(): String = "<assistant key field redacted>"
}
