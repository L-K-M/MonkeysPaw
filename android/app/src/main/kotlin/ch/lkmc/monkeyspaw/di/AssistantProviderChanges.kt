package ch.lkmc.monkeyspaw.di

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Observe from assistant composition and retire sessions even for credential-only edits. */
internal class AssistantProviderChanges {
    private val mutableGeneration = MutableStateFlow(0L)
    val generation = mutableGeneration.asStateFlow()
    private val observers = linkedMapOf<Long, () -> Unit>()
    private var nextObserver = 0L

    /** Settings completion and assistant composition call this on UI, preserving every transition. */
    fun changed() {
        mutableGeneration.update { it + 1 }
        observers.values.toList().forEach { it() }
    }

    fun addObserver(observer: () -> Unit): Long = (++nextObserver).also { observers[it] = observer }
    fun removeObserver(token: Long) { observers.remove(token) }
}
