package ch.lkmc.monkeyspaw.core.syncapi

// §26 S1/S5: `document` is opaque base64url ciphertext the server never
// decodes; `rev` is an ordering cursor, not a write precondition.
data class ProviderSettingsDocument(val rev: Long, val document: String?, val updatedAt: String?) {
    companion object {
        val codec = objectCodec("ProviderSettingsDocument", { o ->
            o.members(setOf("rev", "document", "updated_at"))
            ProviderSettingsDocument(o.long("rev", minimum = 0),
                o.nullableString("document", WireValidation::providerSyncDocument),
                o.nullableString("updated_at", WireValidation::timestamp))
        }, {
            wireObject("rev" to wireLong(it.rev),
                "document" to (it.document?.let(::wireString) ?: WireValue.Null),
                "updated_at" to (it.updatedAt?.let(::wireString) ?: WireValue.Null))
        })
    }
}

// Last writer wins: the request carries no precondition.
data class PutProviderSettingsRequest(val document: String) {
    companion object {
        val codec = objectCodec("PutProviderSettingsRequest", { o ->
            o.members(setOf("document"))
            PutProviderSettingsRequest(o.string("document", WireValidation::providerSyncDocument))
        }, { wireObject("document" to wireString(it.document)) })
    }
}

data class ProviderSettingsResponse(val rev: Long) {
    companion object {
        val codec = objectCodec("ProviderSettingsResponse", { o ->
            o.members(setOf("rev"))
            ProviderSettingsResponse(o.long("rev", minimum = 1))
        }, { wireObject("rev" to wireLong(it.rev)) })
    }
}
