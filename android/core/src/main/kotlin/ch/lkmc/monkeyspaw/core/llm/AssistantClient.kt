package ch.lkmc.monkeyspaw.core.llm

import ch.lkmc.monkeyspaw.core.domain.llm.AssistantModelPage
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantRequest
import ch.lkmc.monkeyspaw.core.domain.llm.AssistantResponse
import ch.lkmc.monkeyspaw.core.domain.llm.ProviderConnection

/** A service supplies the original absolute deadline when credentials or pages share a budget. */
interface AssistantClient {
    suspend fun perform(request: AssistantRequest, connection: ProviderConnection): AssistantResponse
    suspend fun perform(request: AssistantRequest, connection: ProviderConnection, deadlineNanos: Long): AssistantResponse
    suspend fun listModels(connection: ProviderConnection): AssistantModelPage
    suspend fun listModels(connection: ProviderConnection, afterID: String?, deadlineNanos: Long): AssistantModelPage
}
