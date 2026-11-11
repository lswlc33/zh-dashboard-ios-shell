package io.github.lswlc33.zeehoshared

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal object InductiveTelemetry {
    fun decode(frame: InductiveKeyCodec.Frame, at: Long): JsonObject {
        require(at >= 0) { "invalid_time" }
        val dash = frame.command == InductiveKeyCodec.DASH_RESULT
        val period = frame.command == InductiveKeyCodec.PERIOD_RESULT
        val telemetry = linkedMapOf<String, kotlinx.serialization.json.JsonElement>()
        val metadata = linkedMapOf<String, kotlinx.serialization.json.JsonElement>(
            "command" to JsonPrimitive(frame.command), "payloadLength" to JsonPrimitive(frame.payload.size),
            "status" to JsonPrimitive(if (dash) "static_schema_unverified" else if (period) "captured_small_frame" else "unsupported_command"),
            "unitsVerified" to JsonPrimitive(!dash),
            "unsupported" to buildJsonObject {
                if (dash) put("socPercent", "unit_unverified")
                put("currentA", "field_unverified"); put("powerW", if (dash) "unit_unverified" else "field_unverified")
                put("sohPercent", "field_unverified"); put("remainingKm", "unit_unverified")
                if (!dash) put("speedKph", "field_unverified")
            }
        )
        val rawFields = mutableListOf<JsonObject>()
        try {
            val fields = InductiveKeyCodec.fields(frame.payload)
            val duplicates = fields.groupingBy { it.number }.eachCount().filterValues { it > 1 }.keys
            val values = fields.associate { it.number to it.value }
            for (field in fields) {
                val v = field.value
                val meta = linkedMapOf<String, kotlinx.serialization.json.JsonElement>("wire" to JsonPrimitive(v.wire))
                if (v.wire == 2) {
                    meta["length"] = JsonPrimitive(v.bytes.size)
                    meta["digest"] = JsonPrimitive("sha256:" + InductiveKeyCodec.hex(platformSha256(v.bytes)))
                } else {
                    meta["numeric"] = JsonPrimitive(v.numeric)
                }
                // 字节由受信协议 facade 返回，不在日志/摘要中泄露认证材料；保留未知字段供调用者原样归档。
                rawFields += buildJsonObject {
                    put("field", field.number); put("wire", v.wire)
                    put("rawHex", InductiveKeyCodec.hex(v.raw))
                    if (v.wire == 2) put("bytesHex", InductiveKeyCodec.hex(v.bytes)) else put("numericBits", v.numeric)
                }
                fun reason(text: String) { meta["reason"] = JsonPrimitive(text) }
                fun unsigned(key: String, max: Long): Long? {
                    if (v.wire != 0) { reason("wrong_wire"); return null }
                    if (v.numeric < 0 || v.numeric > max) { reason("out_of_range"); return null }
                    telemetry[key] = JsonPrimitive(v.numeric); return v.numeric
                }
                fun floating(key: String, min: Double, max: Double) {
                    if (v.wire != 5) { reason("wrong_wire"); return }
                    val value = Float.fromBits(v.numeric.toInt()).toDouble()
                    if (!value.isFinite()) reason("non_finite")
                    else if (value < min || value > max) reason("out_of_range")
                    else telemetry[key] = JsonPrimitive(value)
                }
                if (field.number in duplicates) reason("duplicate_field")
                else if (period) when (field.number) {
                    1 -> unsigned("headLockState", 2)
                    2 -> unsigned("socRaw", 200)?.let {
                        telemetry["socPercent"] = JsonPrimitive(it / 2.0)
                        if (it and 1L != 0L) reason("half_step_unverified")
                    }
                    4 -> if (v.wire != 0) reason("wrong_wire") else reason(if (v.numeric in 0..10000) "unit_unverified" else "out_of_range")
                    5 -> floating("voltageV", 0.0, 200.0)
                    6 -> floating("tempC", -50.0, 150.0)
                    else -> reason("field_unverified")
                } else if (dash) {
                    val key = when (field.number) {
                        1 -> "speedKph"; 2 -> "powerRaw"; 3 -> "odometerRaw"; 4 -> "socRaw"; 5 -> "modeRaw"; 6 -> "lightRaw"; else -> ""
                    }
                    if (key.isEmpty()) reason("field_unverified") else {
                        val max = when (field.number) { 1 -> 300L; 2 -> 100000L; else -> 0xffffffffL }
                        if (unsigned(key, max) != null) {
                            reason(if (field.number == 1) "static_schema_unverified" else "unit_unverified")
                            if (field.number == 2) telemetry["powerDeltaRaw"] = JsonPrimitive(v.numeric - 1500)
                        }
                    }
                }
                metadata["field${field.number}"] = JsonObject(meta)
            }
            // 完整且无扩展/重复的 F3 才应用已证实的 proto3 零速度省略语义。
            if (dash && 1 !in values && duplicates.isEmpty() && (2..5).all { it in values }
                && values.all { (n, v) -> n in 1..6 && v.wire == 0 && v.numeric >= 0 && v.numeric <= if (n == 2) 100000 else 0xffffffffL }) {
                telemetry["speedKph"] = JsonPrimitive(0)
                metadata["field1"] = buildJsonObject { put("present", false); put("reason", "proto3_default") }
            }
            if (duplicates.isNotEmpty()) metadata["ambiguous"] = JsonPrimitive(true)
        } catch (_: IllegalArgumentException) {
            telemetry.clear(); metadata["error"] = JsonPrimitive("invalid_protobuf")
        }
        return buildJsonObject {
            put("ok", true); put("at", at); put("command", frame.command)
            put("checksum", frame.checksum); put("checksumKind", "sum8")
            put("frameHex", InductiveKeyCodec.hex(frame.raw)); put("payloadHex", InductiveKeyCodec.hex(frame.payload))
            put("rawFields", JsonArray(rawFields)); put("telemetry", JsonObject(telemetry)); put("fields", JsonObject(metadata))
            put("protocolVerified", false)
        }
    }
}

/** Swift 只看到 String/数值/同步函数；BLE 生命周期和车辆操作仍由平台负责。 */
class SharedProtocol {
    private val stream = InductiveKeyCodec.Stream()
    private val lock = StateLock()

    fun encodeFrameHex(command: Int, payloadHex: String): String = safeHex {
        InductiveKeyCodec.frame(command, InductiveKeyCodec.hex(payloadHex, InductiveKeyCodec.MAX_PAYLOAD, true))
    }
    fun decodeTelemetryJSON(frameHex: String, at: Long): String = safeJson {
        InductiveTelemetry.decode(InductiveKeyCodec.decode(InductiveKeyCodec.hex(frameHex, InductiveKeyCodec.MAX_PAYLOAD + 7)), at).toString()
    }
    fun feedFramesJSON(fragmentHex: String, at: Long): String = safeJson {
        require(at >= 0) { "invalid_time" }
        val bytes = InductiveKeyCodec.hex(fragmentHex, InductiveKeyCodec.MAX_BUFFER, true)
        lock.withLock {
            val frames = stream.feed(bytes)
            buildJsonObject {
                put("ok", true); put("frames", JsonArray(frames.map { InductiveTelemetry.decode(it, at) }))
                put("buffered", stream.buffered()); put("rejected", stream.rejected); put("skipped", stream.skipped)
            }.toString()
        }
    }
    fun clearStream() { lock.withLock { stream.clear() } }
    fun checksum(command: Int, payloadHex: String): Int = try {
        InductiveKeyCodec.checksum(command, InductiveKeyCodec.hex(payloadHex, InductiveKeyCodec.MAX_PAYLOAD, true))
    } catch (_: IllegalArgumentException) { -1 }
    fun crc32Hex(bytesHex: String): String = try {
        InductiveKeyCodec.crc32(InductiveKeyCodec.hex(bytesHex, InductiveKeyCodec.MAX_BUFFER, true)).toString(16).padStart(8, '0')
    } catch (bad: IllegalArgumentException) { "error:" + (bad.message ?: "invalid_input") }
    fun challengeResponseHex(cipherHex: String, keyText: String): String = safeHex {
        val encrypted = InductiveKeyCodec.hex(cipherHex, 128)
        try { InductiveKeyCodec.challenge(encrypted, keyText) } finally { encrypted.fill(0) }
    }
    private fun safeHex(block: () -> ByteArray): String = try { InductiveKeyCodec.hex(block()) }
    catch (bad: IllegalArgumentException) { "error:" + (bad.message?.takeIf { it.matches(Regex("[a-z0-9_]+")) } ?: "invalid_input") }
}
