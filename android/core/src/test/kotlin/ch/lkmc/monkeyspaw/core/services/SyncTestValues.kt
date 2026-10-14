package ch.lkmc.monkeyspaw.core.services

import ch.lkmc.monkeyspaw.core.domain.sync.*
import ch.lkmc.monkeyspaw.core.domain.format.PromptIssueCode
import ch.lkmc.monkeyspaw.core.ports.StoreError
import ch.lkmc.monkeyspaw.core.ports.SyncFileFlushing
import ch.lkmc.monkeyspaw.core.syncapi.Role
import ch.lkmc.monkeyspaw.core.syncapi.WireJson
import ch.lkmc.monkeyspaw.core.syncapi.WireValue
import ch.lkmc.monkeyspaw.core.syncapi.wireString

internal object SyncTestValues {
    val user = SyncIdentifiers.ulid("01ARZ3NDEKTSV4RRFFQ69G5FAV")
    val otherUser = SyncIdentifiers.ulid("01ARZ3NDEKTSV4RRFFQ69G5FAW")
    val group = SyncIdentifiers.ulid("01ARZ3NDEKTSV4RRFFQ69G5FAX")
    val personal = SyncIdentifiers.ulid("01ARZ3NDEKTSV4RRFFQ69G5FAY")
    val groupPrompt = SyncIdentifiers.ulid("01ARZ3NDEKTSV4RRFFQ69G5FAZ")
    val device = SyncIdentifiers.ulid("01ARZ3NDEKTSV4RRFFQ69G5FB0")
    val uuid = SyncIdentifiers.uuid("12345678-1234-abcd-9876-123456789abc")
    val hash = SyncHash.of("canonical bytes".encodeToByteArray())
    val personalID = PromptIdentity.Assigned(personal)
    val groupID = PromptIdentity.Assigned(groupPrompt)
    val userScope = SyncScopeKey.User(user)
    val groupScope = SyncScopeKey.Group(group)

    fun accountIdentity(server: String = "https://example.test/paw", userID: ch.lkmc.monkeyspaw.core.domain.ULID = user) =
        SyncAccountIdentity(server, userID)

    fun binding(root: String = "/library", account: SyncAccountIdentity = accountIdentity()) =
        SyncLibraryIdentity(account, SyncLibraryRoot(root))

    fun account() = SyncAccount(accountIdentity(), "user_1", device, "Android", uuid)

    fun state(): SyncState = SyncState(binding(), uuid, mapOf(userScope to "opaque:any / \u0000 e\u0301\r\n☃"),
        mapOf(group to SyncGroupState("Team", "Team", Role.VIEWER)),
        mapOf(personalID to SyncPromptState(userScope, "Private.md", 1, hash, SyncPromptOrigin.ConflictOf(groupPrompt),
            SyncPromptError(SyncIssueCode.Content(PromptIssueCode.INVALID_UTF8),
                SyncInputFingerprint(byteArrayOf(-1, 0), "Private.md", userScope, 17, SyncOperation.PUT))),
            groupID to SyncPromptState(groupScope, "Folder/Group.md", Long.MAX_VALUE, hash)), mapOf(groupID to true))

    fun ownership(root: String = "/library"): SyncLibraryBinding = SyncLibraryBinding(SyncLibraryRoot(root), accountIdentity(),
        mapOf(group to SyncManagedFolder(accountIdentity(), "Team")),
        listOf(SyncHeldPrompt(personalID, "Private.md", accountIdentity(), hash),
            SyncHeldPrompt(PromptIdentity.at("Idless.md"), "Idless.md", accountIdentity(), SyncHash.of(byteArrayOf(-1, 0)))))

    fun raw(files: MemoryStore, path: String): SyncObject = WireJson.parse(files.read(path)).objectValue()
    fun put(files: MemoryStore, path: String, value: WireValue) = files.put(WireJson.canonical(value), path)
}

internal class SyncFlushes : SyncFileFlushing {
    val calls = mutableListOf<String>()
    var failAt: Int? = null
    override fun flushFile(path: String) = record("file:$path")
    override fun flushDirectory(path: String?) = record("directory:${path ?: "<root>"}")
    private fun record(call: String) {
        calls.add(call)
        if (calls.size == failAt) throw StoreError.IOFailure
    }
}

internal fun SyncObject.setting(key: String, value: WireValue): SyncObject = SyncObject(fields + (key to value))
internal fun SyncObject.edit(key: String, change: (SyncObject) -> SyncObject): SyncObject =
    setting(key, change(required(key).objectValue()))
internal fun SyncObject.text(key: String): String = (required(key) as WireValue.Text).value
internal fun SyncObject.withText(key: String, text: String): SyncObject = setting(key, wireString(text))
