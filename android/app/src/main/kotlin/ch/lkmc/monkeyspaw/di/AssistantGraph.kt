package ch.lkmc.monkeyspaw.di

import ch.lkmc.monkeyspaw.core.ports.MonotonicClock
import ch.lkmc.monkeyspaw.core.services.AssistantAccess
import ch.lkmc.monkeyspaw.core.services.AssistantService
import java.util.UUID

/** Resolve through Lazy on IO. One identity belongs to the process-wide library/service graph. */
internal class AssistantGraph(val service: AssistantService, val access: AssistantAccess, val clock: MonotonicClock) {
    val id: UUID = UUID.randomUUID()
}
