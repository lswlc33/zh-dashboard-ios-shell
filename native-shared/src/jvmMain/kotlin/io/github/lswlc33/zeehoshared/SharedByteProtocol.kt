package io.github.lswlc33.zeehoshared

import java.security.GeneralSecurityException

/** Java 专用热路径：没有 JSON、Ktor、协程或 Android 类；不会进入 Swift framework header。 */
object SharedByteProtocol {
    const val MAX_PAYLOAD = 240
    @JvmStatic fun encodeFrame(command: Int, payload: ByteArray?): ByteArray = InductiveKeyCodec.frame(command, requireNotNull(payload) { "frame_size" })
    @JvmStatic fun checksumBytes(command: Int, payload: ByteArray?): Int = InductiveKeyCodec.checksum(command, requireNotNull(payload) { "frame_size" })
    @JvmStatic fun hex(value: String?, maxBytes: Int): ByteArray = InductiveKeyCodec.hex(requireNotNull(value) { "hex_size" }, maxBytes)
    @JvmStatic fun hex(value: ByteArray): String = InductiveKeyCodec.hex(value)
    @JvmStatic fun bytesField(field: Int, value: ByteArray?): ByteArray = InductiveKeyCodec.bytesField(field, requireNotNull(value) { "protobuf_size" })
    @JvmStatic fun intField(field: Int, value: Int): ByteArray = InductiveKeyCodec.intField(field, value)
    @JvmStatic fun join(a: ByteArray?, b: ByteArray?): ByteArray = InductiveKeyCodec.join(requireNotNull(a) { "protobuf_size" }, requireNotNull(b) { "protobuf_size" })
    @JvmStatic fun utf8(value: ByteArray?): String = InductiveKeyCodec.utf8(requireNotNull(value) { "text_size" })
    @JvmStatic fun protobuf(payload: ByteArray?): Map<Int, SharedProtoValueJvm> = InductiveKeyCodec.protobuf(requireNotNull(payload) { "protobuf_size" })
        .mapValuesTo(linkedMapOf()) { (_, value) -> SharedProtoValueJvm(value.wire, if (value.wire == 2) value.bytes.copyOf() else value.numeric, value.raw.copyOf()) }
    @JvmStatic fun number(values: Map<Int, SharedProtoValueJvm>, field: Int, missing: Long): Long =
        values[field]?.takeIf { it.wire == 0 }?.value as? Long ?: missing
    @JvmStatic fun bytes(values: Map<Int, SharedProtoValueJvm>, field: Int): ByteArray? =
        (values[field]?.takeIf { it.wire == 2 }?.value as? ByteArray)?.copyOf()
    @JvmStatic fun float32(values: Map<Int, SharedProtoValueJvm>, field: Int): Double =
        (values[field]?.takeIf { it.wire == 5 }?.value as? Long)?.let { Float.fromBits(it.toInt()).toDouble() } ?: Double.NaN
    @JvmStatic @Throws(GeneralSecurityException::class)
    fun challengeResponse(cipher: ByteArray?, keyText: String?): ByteArray = try {
        validateKey(keyText)
        InductiveKeyCodec.challenge(requireNotNull(cipher) { "challenge_size" }, keyText.orEmpty())
    } catch (bad: IllegalArgumentException) { throw GeneralSecurityException(bad.message, bad) }
    @JvmStatic @Throws(GeneralSecurityException::class)
    fun challenge(cipherHex: String?, keyText: String?): ByteArray {
        validateKey(keyText)
        val encrypted = try { InductiveKeyCodec.hex(requireNotNull(cipherHex) { "hex_size" }, 128) }
        catch (bad: IllegalArgumentException) { throw GeneralSecurityException("challenge_encoding", bad) }
        return try { challengeResponse(encrypted, keyText) } finally { encrypted.fill(0) }
    }
    private fun validateKey(keyText: String?) {
        val key = keyText?.toByteArray(Charsets.UTF_8) ?: byteArrayOf()
        try {
            if (key.size != 16 && key.size != 24 && key.size != 32) throw GeneralSecurityException("material_encoding")
        } finally { key.fill(0) }
    }
}
class SharedProtoValueJvm(@JvmField val wire: Int, @JvmField val value: Any, @JvmField val raw: ByteArray)
class SharedFrameJvm(@JvmField val command: Int, @JvmField val payload: ByteArray, @JvmField val checksum: Int, @JvmField val raw: ByteArray)
class SharedFrameStreamJvm {
    private val stream = InductiveKeyCodec.Stream()
    fun feed(bytes: ByteArray?): List<SharedFrameJvm> = stream.feed(bytes ?: byteArrayOf()).map {
        SharedFrameJvm(it.command, it.payload.copyOf(), it.checksum, it.raw.copyOf())
    }
    fun clear() = stream.clear()
    fun buffered(): Int = stream.buffered()
    fun getRejected(): Long = stream.rejected
    fun getSkipped(): Long = stream.skipped
}

object SharedBatteryReadingJvm {
    const val MAX_GAP_MS = BatteryReading.MAX_GAP_MS
    @JvmStatic fun number(value: Any?): Double {
        if (value == null || value is Boolean) return Double.NaN
        val number = if (value is Number) value.toDouble() else value.toString().trim { it <= ' ' }.toDoubleOrNull()
        return number?.takeIf { it.isFinite() } ?: Double.NaN
    }
    @JvmStatic fun voltage(value: Any?): Double = BatteryReading.voltage(number(value))
    @JvmStatic fun powerWatt(voltage: Double, current: Double, declaredPower: Double): Double = BatteryReading.powerWatt(voltage, current, declaredPower)
    @JvmStatic fun currentAmp(voltage: Double, current: Double, declaredPower: Double): Double = BatteryReading.currentAmp(voltage, current, declaredPower)
    @JvmStatic fun complete(soc: Int, voltage: Double, current: Double): Boolean = BatteryReading.complete(soc, voltage, current)
    @JvmStatic fun intervalMillis(from: Long, to: Long): Long = BatteryReading.intervalMillis(from, to)
    @JvmStatic fun chargeState(homeCode: Any?, batteryCode: Any?, batteryText: String?): Int =
        BatteryReading.chargeStateNormalized((homeCode?.toString() ?: batteryCode?.toString()).orEmpty().trim { it <= ' ' }, batteryText.orEmpty())
    @JvmStatic fun chargeState(raw: String?): Int = BatteryReading.chargeState(raw, null)
}
