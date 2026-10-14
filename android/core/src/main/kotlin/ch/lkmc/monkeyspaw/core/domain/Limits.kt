package ch.lkmc.monkeyspaw.core.domain

/** Shared bounds used by the portable content layer and its consumers. */
object Limits {
    const val maxPromptBytes = 256 * 1024
    const val importFileCapBytes = 256 * 1024
    const val promptFormatVersion = 1
    const val ulidEntropyBytes = 10
    const val historyCapPerPrompt = 50
    const val historySequenceMax = 999_999
    const val historyMaxUnixSeconds = 253_402_300_800L
    const val usageEventCap = 1024
    const val valuesFileCapBytes = 1_048_576
    const val maxPathBytes = 1024
    // Wire path plus Groups/<255-byte folder>/, without shortening the server path.
    const val maxRootedPathBytes = maxPathBytes + 7 + 255 + 1
    const val libraryRecentCap = 100
    const val frecencyHalfLifeDays = 14.0
    const val frecencyCap = 32.0
    const val favoriteBoost = 1.5
    const val syncPageItemCap = 200
    const val revisionListCap = 200
    const val maxRetryAfterSeconds = 15 * 60L
    const val syncStateVersion = 1
    const val syncAccountVersion = 1
    const val syncBindingVersion = 1
    const val syncRecordMaxBytes = 16 * 1024 * 1024

    const val llmBudgetNanos = 300_000_000_000L
    const val modelListTimeoutNanos = 15_000_000_000L
    const val anthropicMaxTokens = 16_000
    const val modelListPageCap = 100
    const val modelListEntryCap = 10_000
    const val modelListByteCap = 2 * 1024 * 1024
    const val httpRequestCap = 2 * 1024 * 1024
    const val responseCap = 2 * 1024 * 1024
    const val syncResponseCap = 16 * 1024 * 1024
    const val llmJSONNestingCap = 32
    // Foundation's provider-state reader accepts at most 512 open containers.
    internal const val providerStateJSONNestingCap = 512
}
