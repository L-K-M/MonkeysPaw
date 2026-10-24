package ch.lkmc.monkeyspaw.core.domain

/** Shared bounds used by the portable content layer and its consumers. */
object Limits {
    const val maxPromptBytes = 256 * 1024
    const val maxRenderedPromptBytes = 2 * 1024 * 1024
    const val importFileCapBytes = 256 * 1024
    const val capturedTextCapBytes = 256 * 1024
    const val promptFormatVersion = 1
    const val ulidEntropyBytes = 10
    const val historyCapPerPrompt = 50
    const val historySequenceMax = 999_999
    const val libraryCopyCandidateCap = 1_000
    const val libraryCreateAttemptCap = 64
    const val promptFilenameMaxBytes = 255
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
    internal const val syncDeviceSecretVersion = 1
    internal const val syncLogoutTimeoutMillis = 5_000L
    internal const val syncSecretCleanupTimeoutMillis = 5_000L
    const val syncApplyJournalVersion = 1
    const val syncPushJournalVersion = 1
    const val syncRecordMaxBytes = 16 * 1024 * 1024
    const val syncRequestTimeoutNanos = 60_000_000_000L
    const val syncCollectionBudgetNanos = 300_000_000_000L
    const val syncCollectionRestartLimit = 1

    internal const val syncStampMaxBytes = 4096
    internal const val syncPathClashMax = 20
    internal const val syncPathSegmentMaxBytes = 255
    internal const val syncConflictDeviceMaxBytes = 64
    internal const val syncRescuePathHashLength = 12
    const val syncIntervalMillis = 60_000L
    const val syncDebounceMillis = 3_000L
    const val syncBackoffMinMillis = 5_000L
    const val syncBackoffMaxMillis = 600_000L
    internal const val syncPreparationLimit = 1_024
    internal const val syncImmediateRerunLimit = 1

    const val llmBudgetNanos = 300_000_000_000L
    const val assistantElapsedTickNanos = 1_000_000_000L
    const val modelListTimeoutNanos = 15_000_000_000L
    const val anthropicMaxTokens = 16_000
    const val modelListPageCap = 100
    const val modelListEntryCap = 10_000
    const val modelListByteCap = 2 * 1024 * 1024
    const val httpRequestCap = 2 * 1024 * 1024
    const val responseCap = 2 * 1024 * 1024
    const val syncResponseCap = 16 * 1024 * 1024
    const val llmJSONNestingCap = 32
    const val assistantEnvelopeNestingCap = 512
    // Foundation's provider-state reader accepts at most 512 open containers.
    internal const val providerStateJSONNestingCap = 512
    internal const val providerSettingsJSONNestingCap = 512

    const val providerSyncRecordVersion = 1
    const val providerSyncKeyBytes = 32
    const val providerSyncNonceBytes = 12
    const val providerSyncTagBytes = 16
    const val providerSyncPayloadMaxBytes = 256 * 1024
    const val providerSyncSecretEntries = 256
    const val providerSyncSecretBytes = 64 * 1024
}
