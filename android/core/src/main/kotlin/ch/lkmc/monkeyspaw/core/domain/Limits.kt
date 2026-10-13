package ch.lkmc.monkeyspaw.core.domain

/** Shared bounds used by the portable content layer and its consumers. */
object Limits {
    const val maxPromptBytes = 256 * 1024
    const val importFileCapBytes = 256 * 1024
    const val promptFormatVersion = 1
    const val ulidEntropyBytes = 10
    const val historyCapPerPrompt = 50
    const val usageEventCap = 1024
    const val libraryRecentCap = 100
    const val frecencyHalfLifeDays = 14.0
    const val frecencyCap = 32.0
    const val favoriteBoost = 1.5
}
