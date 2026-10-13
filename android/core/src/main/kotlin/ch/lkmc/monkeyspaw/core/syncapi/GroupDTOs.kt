package ch.lkmc.monkeyspaw.core.syncapi

data class Group(val id: String, val name: String, val createdBy: String, val createdAt: String) {
    companion object {
        val codec = objectCodec("Group", { o ->
            o.members(setOf("id", "name", "created_by", "created_at"))
            Group(o.string("id", WireValidation::ulid), o.string("name", WireValidation::name),
                o.string("created_by", WireValidation::ulid), o.string("created_at", WireValidation::timestamp))
        }, { wireObject("id" to wireString(it.id), "name" to wireString(it.name),
            "created_by" to wireString(it.createdBy), "created_at" to wireString(it.createdAt)) })
    }
}

data class GroupMembership(val groupID: String, val name: String, val role: Role) {
    companion object {
        val codec = objectCodec("GroupMembership", { o ->
            o.members(setOf("group_id", "name", "role"))
            GroupMembership(o.string("group_id", WireValidation::ulid), o.string("name", WireValidation::name), o.dto("role", Role.codec))
        }, { wireObject("group_id" to wireString(it.groupID), "name" to wireString(it.name), "role" to Role.codec.encodeValue(it.role)) })
    }
}

data class CreateGroupRequest(val name: String) {
    companion object {
        val codec = objectCodec("CreateGroupRequest", { o ->
            o.members(setOf("name"))
            CreateGroupRequest(o.string("name", WireValidation::name))
        }, { wireObject("name" to wireString(it.name)) })
    }
}

data class RenameGroupRequest(val name: String) {
    companion object {
        val codec = objectCodec("RenameGroupRequest", { o ->
            o.members(setOf("name"))
            RenameGroupRequest(o.string("name", WireValidation::name))
        }, { wireObject("name" to wireString(it.name)) })
    }
}

data class Member(val userID: String, val username: String, val displayName: String?, val role: Role, val joinedAt: String) {
    companion object {
        val codec = objectCodec("Member", { o ->
            o.members(setOf("user_id", "username", "display_name", "role", "joined_at"))
            Member(o.string("user_id", WireValidation::ulid), o.string("username", WireValidation::username),
                o.nullableString("display_name", WireValidation::displayName), o.dto("role", Role.codec),
                o.string("joined_at", WireValidation::timestamp))
        }, { wireObject("user_id" to wireString(it.userID), "username" to wireString(it.username),
            "display_name" to wireNullable(it.displayName), "role" to Role.codec.encodeValue(it.role),
            "joined_at" to wireString(it.joinedAt)) })
    }
}

data class MembersResponse(val members: List<Member>) {
    companion object {
        val codec = objectCodec("MembersResponse", { o ->
            o.members(setOf("members"))
            MembersResponse(o.dtos("members", Member.codec))
        }, { wireObject("members" to wireDtos(it.members, Member.codec)) })
    }
}

data class MembershipRequest(val role: Role) {
    companion object {
        val codec = objectCodec("MembershipRequest", { o ->
            o.members(setOf("role"))
            MembershipRequest(o.dto("role", Role.codec))
        }, { wireObject("role" to Role.codec.encodeValue(it.role)) })
    }
}

data class GroupInviteRequest(val role: InviteRole, val expiresIn: Long? = null) {
    companion object {
        val codec = objectCodec("GroupInviteRequest", { o ->
            o.members(setOf("role"), setOf("expires_in"))
            GroupInviteRequest(o.dto("role", InviteRole.codec), o.optionalLong("expires_in", 1, WireValidation.MAX_INVITE_TTL))
        }, { dto ->
            val fields = mutableMapOf("role" to InviteRole.codec.encodeValue(dto.role))
            dto.expiresIn?.let { fields["expires_in"] = wireLong(it) }
            WireValue.ObjectValue(fields)
        })
    }
}

data class JoinGroupRequest(val inviteToken: String) {
    companion object {
        val codec = objectCodec("JoinGroupRequest", { o ->
            o.members(setOf("invite_token"))
            JoinGroupRequest(o.string("invite_token", WireValidation::token))
        }, { wireObject("invite_token" to wireString(it.inviteToken)) })
    }
}
