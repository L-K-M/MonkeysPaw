package ch.lkmc.monkeyspaw.data

import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardOpenOption.READ
import java.nio.file.attribute.UserDefinedFileAttributeView
import java.util.UUID

/** Real host paths/permissions/xattrs, injected in place of Android Os. Not Android fsync proof. */
internal open class JvmCheckedSyncIO : CheckedSyncIO() {
    val flushedFiles = mutableListOf<Path>()
    val flushedDirectories = mutableListOf<Path>()
    var before: (Mutation, String) -> Unit = { _, _ -> }
    var onFlush: (Path) -> Unit = { }

    override fun beforeMutation(mutation: Mutation, path: String) = before(mutation, path)

    override fun flushFile(path: Path) {
        onFlush(path)
        FileChannel.open(path, READ, NOFOLLOW_LINKS).use { it.force(true) }
        flushedFiles.add(path)
    }

    override fun flushDirectory(path: Path) {
        onFlush(path)
        FileChannel.open(path, READ, NOFOLLOW_LINKS).use { it.force(true) }
        flushedDirectories.add(path)
    }

    override fun directoryToken(path: Path): DirectoryToken = synchronized(markerLock) {
        val view = Files.getFileAttributeView(path, UserDefinedFileAttributeView::class.java, NOFOLLOW_LINKS)
        val created = attribute !in view.list()
        if (created) view.write(attribute, ByteBuffer.wrap(UUID.randomUUID().toString().encodeToByteArray()))
        val buffer = ByteBuffer.allocate(view.size(attribute))
        view.read(attribute, buffer)
        DirectoryToken(buffer.array().decodeToString(), created)
    }

    private companion object {
        val markerLock = Any()
        const val attribute = "monkeyspaw.sync-incarnation"
    }
}
