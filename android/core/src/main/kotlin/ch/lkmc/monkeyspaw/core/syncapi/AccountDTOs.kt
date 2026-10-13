package ch.lkmc.monkeyspaw.core.syncapi

data class HealthResponse(val status: String, val version: String) {
    companion object {
        val codec = objectCodec("HealthResponse", { o ->
            o.members(setOf("status", "version"))
            val status = o.string("status")
            wireRequire(status == "ok")
            HealthResponse(status, o.string("version", WireValidation::nonempty))
        }, { wireObject("status" to wireString(it.status), "version" to wireString(it.version)) })
    }
}

data object EmptyResponse {
    val codec = objectCodec("EmptyResponse", { o -> o.members(emptySet()); EmptyResponse }, { wireObject() })
}

data class IDPath(val id: String) {
    companion object {
        val codec = objectCodec("IDPath", { o ->
            o.members(setOf("id"))
            IDPath(o.string("id", WireValidation::ulid))
        }, { wireObject("id" to wireString(it.id)) })
    }
}

data class MemberPath(val id: String, val userID: String) {
    companion object {
        val codec = objectCodec("MemberPath", { o ->
            o.members(setOf("id", "user_id"))
            MemberPath(o.string("id", WireValidation::ulid), o.string("user_id", WireValidation::ulid))
        }, { wireObject("id" to wireString(it.id), "user_id" to wireString(it.userID)) })
    }
}

data class RevisionPath(val id: String, val rev: Long) {
    companion object {
        val codec = objectCodec("RevisionPath", { o ->
            o.members(setOf("id", "rev"))
            RevisionPath(o.string("id", WireValidation::ulid), o.long("rev", minimum = 1))
        }, { wireObject("id" to wireString(it.id), "rev" to wireLong(it.rev)) })
    }
}

data class LoginRequest(val username: String, val password: String, val deviceName: String) {
    companion object {
        val codec = objectCodec("LoginRequest", { o ->
            o.members(setOf("username", "password", "device_name"))
            LoginRequest(o.string("username", WireValidation::username),
                o.string("password", WireValidation::suppliedPassword), o.string("device_name", WireValidation::name))
        }, { wireObject("username" to wireString(it.username), "password" to wireString(it.password),
            "device_name" to wireString(it.deviceName)) })
    }
}

data class RegisterRequest(val inviteToken: String, val username: String, val password: String, val deviceName: String) {
    companion object {
        val codec = objectCodec("RegisterRequest", { o ->
            o.members(setOf("invite_token", "username", "password", "device_name"))
            RegisterRequest(o.string("invite_token", WireValidation::token), o.string("username", WireValidation::username),
                o.string("password", WireValidation::password), o.string("device_name", WireValidation::name))
        }, { wireObject("invite_token" to wireString(it.inviteToken), "username" to wireString(it.username),
            "password" to wireString(it.password), "device_name" to wireString(it.deviceName)) })
    }
}

data class PasswordChangeRequest(val currentPassword: String, val newPassword: String) {
    companion object {
        val codec = objectCodec("PasswordChangeRequest", { o ->
            o.members(setOf("current_password", "new_password"))
            PasswordChangeRequest(o.string("current_password", WireValidation::suppliedPassword),
                o.string("new_password", WireValidation::password))
        }, { wireObject("current_password" to wireString(it.currentPassword), "new_password" to wireString(it.newPassword)) })
    }
}

data class User(
    val id: String,
    val username: String,
    val displayName: String?,
    val accountKind: AccountKind,
    val createdAt: String,
    val disabledAt: String?,
) {
    companion object {
        val codec = objectCodec("User", { o ->
            o.members(setOf("id", "username", "display_name", "account_kind", "created_at", "disabled_at"))
            User(o.string("id", WireValidation::ulid), o.string("username", WireValidation::username),
                o.nullableString("display_name", WireValidation::displayName), o.dto("account_kind", AccountKind.codec),
                o.string("created_at", WireValidation::timestamp), o.nullableString("disabled_at", WireValidation::timestamp))
        }, { wireObject("id" to wireString(it.id), "username" to wireString(it.username),
            "display_name" to wireNullable(it.displayName), "account_kind" to AccountKind.codec.encodeValue(it.accountKind),
            "created_at" to wireString(it.createdAt), "disabled_at" to wireNullable(it.disabledAt)) })
    }
}

data class AuthResponse(val deviceToken: String, val user: User) {
    companion object {
        val codec = objectCodec("AuthResponse", { o ->
            o.members(setOf("device_token", "user"))
            AuthResponse(o.string("device_token", WireValidation::token), o.dto("user", User.codec))
        }, { wireObject("device_token" to wireString(it.deviceToken), "user" to User.codec.encodeValue(it.user)) })
    }
}

data class Device(
    val id: String,
    val name: String,
    val createdAt: String,
    val lastSeenAt: String?,
    val revokedAt: String?,
    val isCurrent: Boolean,
) {
    companion object {
        val codec = objectCodec("Device", { o ->
            o.members(setOf("id", "name", "created_at", "last_seen_at", "revoked_at", "is_current"))
            Device(o.string("id", WireValidation::ulid), o.string("name", WireValidation::name),
                o.string("created_at", WireValidation::timestamp), o.nullableString("last_seen_at", WireValidation::timestamp),
                o.nullableString("revoked_at", WireValidation::timestamp), o.boolean("is_current"))
        }, { wireObject("id" to wireString(it.id), "name" to wireString(it.name), "created_at" to wireString(it.createdAt),
            "last_seen_at" to wireNullable(it.lastSeenAt), "revoked_at" to wireNullable(it.revokedAt),
            "is_current" to wireBoolean(it.isCurrent)) })
    }
}

data class MeResponse(val user: User, val groups: List<GroupMembership>, val devices: List<Device>) {
    companion object {
        val codec = objectCodec("MeResponse", { o ->
            o.members(setOf("user", "groups", "devices"))
            MeResponse(o.dto("user", User.codec), o.dtos("groups", GroupMembership.codec), o.dtos("devices", Device.codec))
        }, { wireObject("user" to User.codec.encodeValue(it.user), "groups" to wireDtos(it.groups, GroupMembership.codec),
            "devices" to wireDtos(it.devices, Device.codec)) })
    }
}

data class CreateUserRequest(
    val username: String,
    val password: String,
    val displayName: OptionalValue<String> = OptionalValue.Omitted,
    val accountKind: AccountKind? = null,
) {
    companion object {
        val codec = objectCodec("CreateUserRequest", { o ->
            o.members(setOf("username", "password"), setOf("display_name", "account_kind"))
            CreateUserRequest(o.string("username", WireValidation::username), o.string("password", WireValidation::password),
                o.patchString("display_name", WireValidation::displayName), o.optionalDto("account_kind", AccountKind.codec))
        }, { dto ->
            val fields = mutableMapOf("username" to wireString(dto.username), "password" to wireString(dto.password))
            fields.setPatch("display_name", dto.displayName)
            dto.accountKind?.let { fields["account_kind"] = AccountKind.codec.encodeValue(it) }
            WireValue.ObjectValue(fields)
        })
    }
}

data class UpdateUserRequest(
    val displayName: OptionalValue<String> = OptionalValue.Omitted,
    val password: String? = null,
    val disabled: Boolean? = null,
    val accountKind: AccountKind? = null,
) {
    companion object {
        val codec = objectCodec("UpdateUserRequest", { o ->
            o.members(emptySet(), setOf("display_name", "password", "disabled", "account_kind"), minimum = 1)
            UpdateUserRequest(o.patchString("display_name", WireValidation::displayName),
                o.optionalString("password", WireValidation::password), o.optionalBoolean("disabled"),
                o.optionalDto("account_kind", AccountKind.codec))
        }, { dto ->
            val fields = mutableMapOf<String, WireValue>()
            fields.setPatch("display_name", dto.displayName)
            dto.password?.let { fields["password"] = wireString(it) }
            dto.disabled?.let { fields["disabled"] = wireBoolean(it) }
            dto.accountKind?.let { fields["account_kind"] = AccountKind.codec.encodeValue(it) }
            WireValue.ObjectValue(fields)
        })
    }
}
