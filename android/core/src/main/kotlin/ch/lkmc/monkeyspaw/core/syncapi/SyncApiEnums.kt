package ch.lkmc.monkeyspaw.core.syncapi

internal fun <T> enumCodec(name: String, values: Collection<T>, spelling: (T) -> String): WireCodec<T> =
    WireCodec(name, { value ->
        val text = value.stringValue()
        values.singleOrNull { spelling(it) == text } ?: throw WireContractException()
    }, { wireString(spelling(it)) })

enum class AccountKind(val wireValue: String) {
    MEMBER("member"), ADMIN("admin");
    companion object { val codec = enumCodec("AccountKind", entries) { it.wireValue } }
}

enum class Role(val wireValue: String) {
    OWNER("owner"), EDITOR("editor"), VIEWER("viewer");
    companion object { val codec = enumCodec("Role", entries) { it.wireValue } }
}

/** HTTP invites cannot grant owner; the CLI exception is separate. */
enum class InviteRole(val wireValue: String) {
    EDITOR("editor"), VIEWER("viewer");
    companion object { val codec = enumCodec("InviteRole", entries) { it.wireValue } }
}

enum class WriteOrigin(val wireValue: String) {
    EDIT("edit"), LLM("llm"), RESTORE("restore");
    companion object { val codec = enumCodec("WriteOrigin", entries) { it.wireValue } }
}

enum class RevisionOrigin(val wireValue: String) {
    EDIT("edit"), LLM("llm"), RESTORE("restore"), MOVE("move"), DELETE("delete");
    companion object { val codec = enumCodec("RevisionOrigin", entries) { it.wireValue } }
}

enum class Mode(val wireValue: String) {
    DELTA("delta"), SNAPSHOT("snapshot");
    companion object { val codec = enumCodec("Mode", entries) { it.wireValue } }
}

enum class Severity(val wireValue: String) {
    ERROR("error"), WARNING("warning");
    companion object { val codec = enumCodec("Severity", entries) { it.wireValue } }
}

sealed interface PromptScope {
    data object User : PromptScope
    data class Group(val groupID: String) : PromptScope

    companion object {
        val codec: WireCodec<PromptScope> = objectCodec("PromptScope", { objectValue ->
            when (objectValue.string("scope")) {
                "user" -> {
                    objectValue.members(setOf("scope"))
                    User
                }
                "group" -> {
                    objectValue.members(setOf("scope", "group_id"))
                    Group(objectValue.string("group_id", WireValidation::ulid))
                }
                else -> throw WireContractException()
            }
        }, { scope ->
            when (scope) {
                User -> wireObject("scope" to wireString("user"))
                is Group -> wireObject("scope" to wireString("group"), "group_id" to wireString(scope.groupID))
            }
        })
    }
}
