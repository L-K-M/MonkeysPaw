package ch.lkmc.monkeyspaw.di

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Observe from assistant composition and retire sessions even for credential-only edits. */
internal class AssistantProviderChanges {
    private val mutableGeneration = MutableStateFlow(0L)
    val generation = mutableGeneration.asStateFlow()

    fun changed() { mutableGeneration.update { it + 1 } }
}
