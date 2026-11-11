package io.github.lswlc33.zeehoshared

/** 实捕 BLE1 小帧：AB CD / command / uint16le length / payload / sum8 / CF。不是 CRC 帧。 */
internal object InductiveKeyCodec {
    const val MAX_PAYLOAD = 240
    const val MAX_BUFFER = 2048
    const val PERIOD_RESULT = 0xfd
    const val DASH_RESULT = 0xf3

    class Frame(command: Int, payload: ByteArray, val checksum: Int, raw: ByteArray) {
        val command = command
        val payload = payload.copyOf()
        val raw = raw.copyOf()
    }
    class Value(val wire: Int, val numeric: Long, bytes: ByteArray, raw: ByteArray) {
        val bytes = bytes.copyOf()
        val raw = raw.copyOf()
    }
    class Field(val number: Int, val value: Value)

    fun checksum(command: Int, payload: ByteArray): Int {
        require(command in 0..255 && payload.size <= MAX_PAYLOAD) { "frame_size" }
        return (command + payload.size + payload.sumOf { it.toInt() and 255 }) and 255
    }
    fun frame(command: Int, payload: ByteArray): ByteArray {
        val check = checksum(command, payload)
        return ByteArray(payload.size + 7).also {
            it[0] = 0xab.toByte(); it[1] = 0xcd.toByte(); it[2] = command.toByte()
            it[3] = payload.size.toByte(); it[4] = 0
            payload.copyInto(it, 5)
            it[it.lastIndex - 1] = check.toByte(); it[it.lastIndex] = 0xcf.toByte()
        }
    }
    fun decode(raw: ByteArray): Frame {
        require(raw.size in 7..MAX_PAYLOAD + 7 && raw[0].u() == 0xab && raw[1].u() == 0xcd) { "frame_header" }
        val length = raw[3].u() or (raw[4].u() shl 8)
        require(length <= MAX_PAYLOAD && raw.size == length + 7) { "frame_size" }
        val payload = raw.copyOfRange(5, 5 + length)
        val check = raw[raw.lastIndex - 1].u()
        require(raw.last().u() == 0xcf && checksum(raw[2].u(), payload) == check) { "frame_checksum" }
        return Frame(raw[2].u(), payload, check, raw)
    }

    /** 分片、粘包、垃圾前缀与损坏重同步；仅由一个 BLE 回调序列或外层锁持有。 */
    class Stream {
        private var pending = byteArrayOf()
        var rejected: Long = 0; private set
        var skipped: Long = 0; private set
        fun feed(bytes: ByteArray): List<Frame> {
            if (bytes.isEmpty()) return emptyList()
            if (bytes.size > MAX_BUFFER || pending.size + bytes.size > MAX_BUFFER) {
                clear(); rejected++; return emptyList()
            }
            val joined = pending + bytes
            val frames = mutableListOf<Frame>()
            var at = 0
            while (joined.size - at >= 2) {
                if (joined[at].u() != 0xab || joined[at + 1].u() != 0xcd) { at++; skipped++; continue }
                if (joined.size - at < 5) break
                val length = joined[at + 3].u() or (joined[at + 4].u() shl 8)
                if (length > MAX_PAYLOAD) { at++; rejected++; continue }
                val total = length + 7
                if (joined.size - at < total) break
                try {
                    frames += decode(joined.copyOfRange(at, at + total))
                    at += total
                } catch (_: IllegalArgumentException) { at++; rejected++ }
            }
            pending.fill(0)
            pending = joined.copyOfRange(at, joined.size)
            return frames
        }
        fun clear() { pending.fill(0); pending = byteArrayOf() }
        fun buffered(): Int = pending.size
    }

    fun hex(text: String, maxBytes: Int, allowEmpty: Boolean = false): ByteArray {
        require(maxBytes >= 0 && text.length.toLong() <= maxBytes.toLong() * 2 && text.length % 2 == 0
            && (allowEmpty || text.isNotEmpty())) { "hex_size" }
        return ByteArray(text.length / 2) { i ->
            val a = asciiDigit(text[i * 2])
            val b = asciiDigit(text[i * 2 + 1])
            require(a >= 0 && b >= 0) { "hex_format" }
            ((a shl 4) or b).toByte()
        }
    }
    fun hex(bytes: ByteArray): String = buildString(bytes.size * 2) {
        bytes.forEach { append("0123456789abcdef"[it.u() ushr 4]); append("0123456789abcdef"[it.u() and 15]) }
    }
    fun bytesField(field: Int, value: ByteArray): ByteArray {
        require(field in 1..32 && value.size <= MAX_PAYLOAD - 4) { "protobuf_size" }
        return varint(((field shl 3) or 2).toLong()) + varint(value.size.toLong()) + value
    }
    fun intField(field: Int, value: Int): ByteArray {
        require(field in 1..32 && value >= 0) { "protobuf_number" }
        return varint((field shl 3).toLong()) + varint(value.toLong())
    }
    fun join(a: ByteArray, b: ByteArray): ByteArray {
        require(a.size + b.size <= MAX_PAYLOAD) { "protobuf_size" }
        return a + b
    }
    private fun varint(number: Long): ByteArray {
        var remaining = number
        val result = mutableListOf<Byte>()
        do {
            result += ((remaining and 127) or if (remaining ushr 7 != 0L) 128 else 0).toByte()
            remaining = remaining ushr 7
        } while (remaining != 0L)
        return result.toByteArray()
    }

    /** 不重新序列化：字段顺序、重复未知字段、非最短 varint 及 fixed 位模式全部保留在 raw。 */
    fun fields(payload: ByteArray): List<Field> {
        require(payload.size <= MAX_PAYLOAD) { "protobuf_size" }
        val result = mutableListOf<Field>()
        var at = 0
        fun need(count: Int) { require(count >= 0 && at <= payload.size - count) { "protobuf_truncated" } }
        fun readVarint(): Long {
            var value = 0L
            for (n in 0..9) {
                need(1)
                val b = payload[at++].u()
                require(n != 9 || (b and 254) == 0) { "protobuf_varint" }
                value = value or ((b and 127).toLong() shl (n * 7))
                if (b and 128 == 0) return value
            }
            throw IllegalArgumentException("protobuf_varint")
        }
        while (at < payload.size) {
            val start = at
            val tag = readVarint()
            val field = (tag ushr 3).toInt(); val wire = (tag and 7).toInt()
            require(tag in 1..Int.MAX_VALUE.toLong() && field > 0 && result.size < 64) { "protobuf_tag" }
            var numeric = 0L
            var bytes = byteArrayOf()
            when (wire) {
                0 -> numeric = readVarint()
                1, 5 -> {
                    val size = if (wire == 1) 8 else 4
                    need(size)
                    repeat(size) { numeric = numeric or (payload[at++].u().toLong() shl (it * 8)) }
                }
                2 -> {
                    val size = readVarint()
                    require(size in 0..MAX_PAYLOAD.toLong()) { "protobuf_size" }
                    need(size.toInt())
                    bytes = payload.copyOfRange(at, at + size.toInt()); at += size.toInt()
                }
                else -> throw IllegalArgumentException("protobuf_wire")
            }
            result += Field(field, Value(wire, numeric, bytes, payload.copyOfRange(start, at)))
        }
        return result
    }
    /** 控制/认证响应 singular 重复是歧义，不能靠最后一个值授权车辆写入。 */
    fun protobuf(payload: ByteArray): Map<Int, Value> = linkedMapOf<Int, Value>().also { out ->
        fields(payload).forEach { require(out.put(it.number, it.value) == null) { "protobuf_duplicate" } }
    }
    fun number(values: Map<Int, Value>, field: Int, missing: Long): Long =
        values[field]?.takeIf { it.wire == 0 }?.numeric ?: missing
    fun bytes(values: Map<Int, Value>, field: Int): ByteArray? =
        values[field]?.takeIf { it.wire == 2 }?.bytes?.copyOf()
    fun float32(values: Map<Int, Value>, field: Int): Double =
        values[field]?.takeIf { it.wire == 5 }?.let { Float.fromBits(it.numeric.toInt()).toDouble() } ?: Double.NaN
    fun utf8(bytes: ByteArray): String {
        require(bytes.size <= MAX_PAYLOAD) { "text_size" }
        return try { bytes.decodeToString(throwOnInvalidSequence = true) }
        catch (_: CharacterCodingException) { throw IllegalArgumentException("text_encoding") }
    }
    fun challenge(encrypted: ByteArray, keyText: String): ByteArray {
        val key = keyText.encodeToByteArray()
        var plain: ByteArray? = null
        try {
            require(key.size == 16 || key.size == 24 || key.size == 32) { "material_encoding" }
            require(encrypted.isNotEmpty() && encrypted.size <= 128 && encrypted.size % 16 == 0) { "challenge_size" }
            plain = platformDecryptChallenge(encrypted, key)
            val text = try { utf8(plain) } catch (_: IllegalArgumentException) { throw IllegalArgumentException("challenge_plaintext") }
            require(plain.isNotEmpty() && plain.size <= 128 && text.none { it.code in 0..31 || it.code in 127..159 }) { "challenge_plaintext" }
            // 这是挑战应答 payload，不是已认证状态。不得因此开放写车或配对。
            return bytesField(1, plain)
        } finally { key.fill(0); plain?.fill(0) }
    }
    /** IEEE CRC32 仅供离线诊断与存储完整性使用；实捕 BLE1 帧的校验是上面的 sum8。 */
    fun crc32(bytes: ByteArray): Long {
        var crc = -1
        bytes.forEach { byte ->
            crc = crc xor byte.u()
            repeat(8) { crc = (crc ushr 1) xor if (crc and 1 != 0) 0xedb88320.toInt() else 0 }
        }
        return (crc.inv().toLong() and 0xffffffffL)
    }
    private fun asciiDigit(value: Char): Int = when (value) {
        in '0'..'9' -> value - '0'
        in 'a'..'f' -> value - 'a' + 10
        in 'A'..'F' -> value - 'A' + 10
        else -> -1
    }
    private fun Byte.u(): Int = toInt() and 255
}
