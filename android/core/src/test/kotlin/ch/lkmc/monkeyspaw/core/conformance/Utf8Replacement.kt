package ch.lkmc.monkeyspaw.core.conformance

/** Swift String(decoding:as:) repairs each Unicode maximal subpart; JDK UTF-8 differs for surrogates. */
internal fun swiftReplacementUtf8(bytes: ByteArray): String = buildString {
    var position = 0
    while (position < bytes.size) {
        val lead = bytes[position].toInt() and 255
        if (lead < 128) {
            append(lead.toChar())
            position++
            continue
        }
        val width = when (lead) {
            in 0xC2..0xDF -> 2
            in 0xE0..0xEF -> 3
            in 0xF0..0xF4 -> 4
            else -> { append('\uFFFD'); position++; continue }
        }
        var scalar = lead and (0x7F shr width)
        var consumed = 1
        while (consumed < width && position + consumed < bytes.size) {
            val next = bytes[position + consumed].toInt() and 255
            val lower = if (consumed == 1) when (lead) {
                0xE0 -> 0xA0
                0xF0 -> 0x90
                else -> 0x80
            } else 0x80
            val upper = if (consumed == 1) when (lead) {
                0xED -> 0x9F
                0xF4 -> 0x8F
                else -> 0xBF
            } else 0xBF
            if (next !in lower..upper) break
            scalar = (scalar shl 6) or (next and 0x3F)
            consumed++
        }
        if (consumed == width) appendCodePoint(scalar) else append('\uFFFD')
        position += consumed
    }
}
