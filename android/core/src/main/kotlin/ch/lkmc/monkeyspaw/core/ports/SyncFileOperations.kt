package ch.lkmc.monkeyspaw.core.ports

/** Android normal files are private (0600); viewer files are 0444. Replay reapplies the mode. */
enum class SyncFileMode(val rawValue: String) { READ_ONLY("readOnly"), NORMAL("normal") }

/** Matching includes incarnation and exact bytes. Drivers copy inputs before retaining them. */
sealed class SyncFileExpectation {
    data object Absent : SyncFileExpectation()
    class Matching(val stamp: FileStamp, bytes: ByteArray) : SyncFileExpectation() {
        private val saved = SyncBytes(bytes)
        val bytes: ByteArray get() = saved.copyBytes()
    }
    final override fun toString(): String = "<sync file expectation>"
}

class SyncFilePublication(displacedBytes: ByteArray?) {
    private val saved = displacedBytes?.let(::SyncBytes)
    val displacedBytes: ByteArray? get() = saved?.copyBytes()
    override fun toString(): String = "<sync publication>"
}

enum class SyncFileFailureCode {
    CHANGED, INVALID_PATH, NOT_FOUND, OCCUPIED, IO_FAILURE, DURABILITY_FAILED, INVALID_STATE
}

enum class SyncFileMutationEffect { UNCHANGED, APPLIED }

/** Fixed diagnostics. A post-publication failure retains its effect and every displaced byte. */
class SyncFileOperationError(
    val code: SyncFileFailureCode,
    val effect: SyncFileMutationEffect = SyncFileMutationEffect.UNCHANGED,
    displacedBytes: ByteArray? = null,
) : Exception("Sync file operation failed: " + code.name, null, false, true) {
    private val saved = displacedBytes?.let(::SyncBytes)
    val displacedBytes: ByteArray? get() = saved?.copyBytes()
    override fun toString(): String = message.orEmpty()
}

/**
 * Checked capability beside PromptStore/StateStore, over the SAME rooted tree.
 * Paths stay lexical and byte exact. Revalidate containment and refuse links/nonregular files.
 * The library lock serializes cooperating writers; this is not filesystem-wide CAS.
 * Success proves checked file and affected-directory durability, including new ancestors.
 * Failure after mutation reports APPLIED, preserving displaced bytes without driver error text.
 */
interface SyncFileOperations : SyncFileFlushing {
    fun publish(bytes: ByteArray, path: String, expecting: SyncFileExpectation, mode: SyncFileMode): SyncFilePublication
    fun setMode(mode: SyncFileMode, path: String)
    /** Android: caller durably journals/retains raw bytes BEFORE checked unlink; flush parents. */
    fun trash(path: String, expecting: SyncFileExpectation)
    /** Complete regular-file inventory, including hidden and nonprompt files. Never partial. */
    fun listFiles(): List<StoredFile>
    /** Exclusive creation; empty directories are occupied. Flush new ancestors and parents. */
    fun createDirectory(path: String)
    /** Exclusive rename, never merge/replace; destination parent must exist. Flush both parents. */
    fun renameDirectory(source: String, destination: String)
    /** Direct child directory paths, including hidden/empty entries; null is the root. */
    fun directories(path: String?): List<String>
    /** Stable incarnation, retained by rename/child edits, changed by delete/recreate. */
    fun directoryIdentity(path: String): FileStamp?
    /** Only this empty incarnation; never recursively remove contents. Flush its parent. */
    fun removeEmptyDirectory(path: String, expecting: FileStamp)
}

/** Owned value bytes for intents and port results; array identity never defines equality. */
internal class SyncBytes(bytes: ByteArray) {
    private val saved = bytes.copyOf()
    fun copyBytes(): ByteArray = saved.copyOf()
    override fun equals(other: Any?): Boolean = other is SyncBytes && saved.contentEquals(other.saved)
    override fun hashCode(): Int = saved.contentHashCode()
    override fun toString(): String = "<sync bytes>"
}
