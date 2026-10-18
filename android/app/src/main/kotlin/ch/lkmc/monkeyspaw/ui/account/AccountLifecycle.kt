package ch.lkmc.monkeyspaw.ui.account

internal enum class AccountStopMode { RELEASE_FOREGROUND, CLEAR_PRESENTATION }

/** Invite routing can create Account before onboarding admits a foreground lease. */
internal fun stopAccountPresentation(account: Lazy<AccountViewModel>, mode: AccountStopMode) {
    when (mode) {
        AccountStopMode.RELEASE_FOREGROUND -> account.value.setForeground(null)
        AccountStopMode.CLEAR_PRESENTATION -> if (account.isInitialized()) account.value.hide()
    }
}
