package ch.lkmc.monkeyspaw.core.domain.llm

/** Opaque identity: an edit or a switch away and back cannot revive a previous request. */
class ConnectionTestRequestID internal constructor() {
    override fun toString(): String = "<connection test request>"
}

/** Session-only state, owned by the settings model's UI thread. Suggestions never restrict manual IDs. */
class AssistantModelPickerState(private var draft: ProviderDraft) {
    private var pending: ConnectionTestRequestID? = null
    var availableModels: List<ModelDescriptor> = emptyList()
        private set
    var lastResult: ConnectionTestResult? = null
        private set
    val manualModelID: String get() = draft.modelID
    val isTesting: Boolean get() = pending != null

    fun update(draft: ProviderDraft) {
        // Kotlin String/SecretValue equality preserves exact spelling, without Unicode normalization.
        if (this.draft == draft) return
        this.draft = draft
        pending = null
        availableModels = emptyList()
        lastResult = null
    }

    fun beginTest(): ConnectionTestRequestID = ConnectionTestRequestID().also { pending = it }

    /** Apply all draft edits before receiving a reply. A request can be consumed only once. */
    fun receive(result: ConnectionTestResult, request: ConnectionTestRequestID): Boolean {
        if (pending != request) return false
        pending = null
        lastResult = result
        if (result is ConnectionTestResult.Ok) availableModels = result.models
        return true
    }

    fun cancelTest() {
        if (pending == null) return
        pending = null
        lastResult = ConnectionTestResult.Cancelled
    }

    override fun toString(): String = "<assistant model picker redacted>"
}
