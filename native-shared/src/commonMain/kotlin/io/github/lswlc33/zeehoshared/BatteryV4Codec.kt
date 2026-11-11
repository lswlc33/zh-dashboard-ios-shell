package io.github.lswlc33.zeehoshared

/** Android v4 的纯 24B big-endian 样本布局；不包含 Deflate/磁盘/旧 Keystore 迁移。 */
internal object BatteryV4Codec {
    const val RECORD_SIZE = 24
    const val MAGIC = 0x5a424154
    const val VERSION = 4
    private fun fixed(value: Double, scale: Int): Int {
        if (!value.isFinite()) return -32768
        val scaled = BatteryReading.rounded(value * scale)
        return if (scaled in -32767.0..32767.0) scaled.toInt() else -32768
    }
    fun encodeRecord(record: BatteryRecord): ByteArray {
        require(record.t > 0 && record.soc in 0..100) { "invalid_record" }
        val out = ByteArray(RECORD_SIZE)
        var at = 0
        fun write(value: Long, count: Int) {
            for (i in count - 1 downTo 0) out[at++] = (value ushr (i * 8)).toByte()
        }
        write(record.t, 8); write(record.soc.toLong(), 1)
        write(fixed(record.v, 10).toLong(), 2); write(fixed(record.a, 10).toLong(), 2); write(fixed(record.w, 1).toLong(), 2)
        write(record.temp.takeIf { it in -128..127 }?.toLong() ?: -128L, 1)
        write(record.state.takeIf { it in 0..2 }?.toLong() ?: -1L, 1)
        write(record.powered.takeIf { it in 0..1 }?.toLong() ?: -1L, 1)
        write(record.odo.takeIf { it >= 0 }?.toLong() ?: -1L, 4)
        write(record.chargedMin.takeIf { it in 0..65534 }?.toLong() ?: -1L, 2)
        return out
    }
    fun decodeRecord(bytes: ByteArray): BatteryRecord {
        require(bytes.size == RECORD_SIZE) { "record_size" }
        var at = 0
        fun read(count: Int): Long {
            var value = 0L
            repeat(count) { value = (value shl 8) or (bytes[at++].toLong() and 255) }
            return value
        }
        fun signedShort(): Int = read(2).toShort().toInt()
        fun fixed(raw: Int, scale: Int): Double = if (raw == -32768) Double.NaN else raw.toDouble() / scale
        val t = read(8); val soc = read(1).toInt()
        val v = fixed(signedShort(), 10); val a = fixed(signedShort(), 10); val w = fixed(signedShort(), 1)
        val temp = read(1).toByte().toInt()
        val state = read(1).toByte().toInt().takeIf { it in 0..2 } ?: -1
        val powered = read(1).toByte().toInt().takeIf { it in 0..1 } ?: -1
        val odo = read(4).toInt().takeIf { it >= 0 } ?: -1
        val chargedMin = read(2).toInt().takeIf { it != 65535 } ?: -1
        return BatteryRecord(t, v, a, w, soc, temp, state, powered, odo, chargedMin)
    }
    fun encodeSamples(records: List<BatteryRecord>): ByteArray {
        require(records.size <= 4096) { "history_too_many_points" }
        return ByteArray(records.size * RECORD_SIZE).also { output ->
            records.forEachIndexed { i, record -> encodeRecord(record).copyInto(output, i * RECORD_SIZE) }
        }
    }
    /** 不丢未知或不完整记录：codec 保留原结构，由 admission/report 决定哪些是有效采样。 */
    fun decodeSamples(bytes: ByteArray): List<BatteryRecord> {
        require(bytes.size <= 4096 * RECORD_SIZE && bytes.size % RECORD_SIZE == 0) { "record_size" }
        return (bytes.indices step RECORD_SIZE).map { decodeRecord(bytes.copyOfRange(it, it + RECORD_SIZE)) }
    }
    fun header(): ByteArray = byteArrayOf(0x5a, 0x42, 0x41, 0x54, 0, 0, 0, 4)
    fun chunkHeader(plainLength: Int, compressedLength: Int): ByteArray {
        require(plainLength in RECORD_SIZE..RECORD_SIZE * 4096 && plainLength % RECORD_SIZE == 0
            && compressedLength in 1..plainLength + 4096) { "chunk_header" }
        return ByteArray(12).also { out ->
            listOf(plainLength, compressedLength, 0).forEachIndexed { at, value ->
                repeat(4) { out[at * 4 + it] = (value ushr (24 - it * 8)).toByte() }
            }
        }
    }
}
