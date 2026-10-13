package ch.lkmc.monkeyspaw.core.syncapi

sealed interface InviteTarget {
    data object Account : InviteTarget
    data class Group(val groupID: String, val role: InviteRole) : InviteTarget
}

private fun WireObject.inviteTarget(): InviteTarget {
    wireRequire(contains("group_id") == contains("role"))
    if (!contains("group_id")) return InviteTarget.Account
    return InviteTarget.Group(string("group_id", WireValidation::ulid), dto("role", InviteRole.codec))
}

private fun InviteTarget.fields(): MutableMap<String, WireValue> = when (this) {
    InviteTarget.Account -> mutableMapOf()
    is InviteTarget.Group -> mutableMapOf("group_id" to wireString(groupID), "role" to InviteRole.codec.encodeValue(role))
}

data class AdminInviteRequest(val target: InviteTarget, val expiresIn: Long? = null) {
    companion object {
        val codec = objectCodec("AdminInviteRequest", { o ->
            o.members(emptySet(), setOf("group_id", "role", "expires_in"))
            AdminInviteRequest(o.inviteTarget(), o.optionalLong("expires_in", 1, WireValidation.MAX_INVITE_TTL))
        }, { dto ->
            val fields = dto.target.fields()
            dto.expiresIn?.let { fields["expires_in"] = wireLong(it) }
            WireValue.ObjectValue(fields)
        })
    }
}

data class InviteResponse(val inviteToken: String, val expiresAt: String, val target: InviteTarget) {
    companion object {
        val codec = objectCodec("InviteResponse", { o ->
            o.members(setOf("invite_token", "expires_at"), setOf("group_id", "role"))
            InviteResponse(o.string("invite_token", WireValidation::token), o.string("expires_at", WireValidation::timestamp),
                o.inviteTarget())
        }, { dto ->
            val fields = dto.target.fields()
            fields["invite_token"] = wireString(dto.inviteToken)
            fields["expires_at"] = wireString(dto.expiresAt)
            WireValue.ObjectValue(fields)
        })
    }
}
