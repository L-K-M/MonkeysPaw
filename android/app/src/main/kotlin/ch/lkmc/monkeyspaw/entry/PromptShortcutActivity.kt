package ch.lkmc.monkeyspaw.entry

import android.app.Activity
import android.os.Bundle

/** Isolates the static shortcut's mandatory CLEAR_TASK flag from the library and held fill form. */
class PromptShortcutActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Never forward incoming extras, data, flags or target.
        startActivity(FillRoute(EntrySource.SHORTCUT).intent(this))
        finish()
    }
}
