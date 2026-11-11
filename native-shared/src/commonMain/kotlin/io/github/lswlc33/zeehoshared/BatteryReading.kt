package io.github.lswlc33.zeehoshared

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import kotlin.math.abs
import kotlin.math.floor

/** 未知电流用 NaN；-1A 是有效放电值。charge_demo 从不进入业务判断。 */
internal object BatteryReading {
    const val MAX_GAP_MS = 300_000L
    fun number(value: JsonElement?): Double {
        val primitive = value as? JsonPrimitive ?: return Double.NaN
        if (primitive == JsonNull || (!primitive.isString && (primitive.content == "true" || primitive.content == "false"))) return Double.NaN
        return primitive.contentOrNull?.trim()?.toDoubleOrNull()?.takeIf { it.isFinite() } ?: Double.NaN
    }
    fun voltage(value: Double): Double = if (value.isFinite() && value >= 0) value else Double.NaN
    fun rounded(value: Double): Double = if (value.isFinite()) floor(value + 0.5) else Double.NaN
    fun powerWatt(voltage: Double, current: Double, declaredPower: Double): Double {
        if (declaredPower.isFinite() && declaredPower != 0.0) return rounded(declaredPower)
        if (!voltage.isFinite() || voltage < 0 || !current.isFinite()) return Double.NaN
        return rounded(voltage * current)
    }
    fun currentAmp(voltage: Double, current: Double, declaredPower: Double): Double {
        if (!declaredPower.isFinite() || declaredPower == 0.0 || !voltage.isFinite() || voltage <= 0) return current
        return if (!current.isFinite() || abs(voltage * current - declaredPower) > abs(declaredPower) * 0.2)
            rounded(declaredPower / voltage * 10) / 10 else current
    }
    fun complete(soc: Int, voltage: Double, current: Double): Boolean =
        soc in 0..100 && voltage.isFinite() && voltage >= 0 && current.isFinite()
    fun intervalMillis(from: Long, to: Long): Long {
        if (from <= 0 || to <= from) return 0
        val dt = to - from
        return if (dt in 1..MAX_GAP_MS) dt else 0
    }
    fun chargeState(raw: String?, text: String?): Int {
        val code = raw?.trim().orEmpty()
        val description = text.orEmpty()
        return chargeStateNormalized(code, description)
    }
    fun chargeStateNormalized(code: String, description: String): Int {
        if ((code.isEmpty() || code == "-1") && description.isEmpty()) return -1
        if (code == "1") return 1
        return if (description.contains("\u5145\u6ee1")) 2 else 0
    }
    fun reading(json: JsonObject): JsonObject {
        val voltage = voltage(number(json["voltage"]))
        val current = number(json["current"])
        val declared = number(json["power"])
        val homeCode = (json["chargeState"] as? JsonPrimitive)?.contentOrNull
        val batteryCode = (json["chargeCode"] as? JsonPrimitive)?.contentOrNull
        return buildJsonObject {
            put("ok", true); put("voltage", finiteJson(voltage))
            put("current", finiteJson(currentAmp(voltage, current, declared)))
            put("power", finiteJson(powerWatt(voltage, current, declared)))
            put("charging", chargeState(homeCode ?: batteryCode, json.text("chargeText")))
        }
    }
}

internal data class BatteryRecord(
    val t: Long, val v: Double, val a: Double, val w: Double, val soc: Int,
    val temp: Int = -128, val state: Int = -1, val powered: Int = -1,
    val odo: Int = -1, val chargedMin: Int = -1
) {
    fun valid(now: Long): Boolean = t in 1..now && BatteryReading.complete(soc, v, a) && w.isFinite()
    fun point(): JsonObject = buildJsonObject {
        put("t", t); put("soc", soc); put("v", finiteJson(v)); put("a", finiteJson(a)); put("w", finiteJson(w)); put("state", state)
        if (temp != -128) put("temp", temp)
        if (powered >= 0) put("pwr", powered)
        if (odo >= 0) put("odo", odo)
        if (chargedMin >= 0) put("cf", chargedMin)
    }
    companion object {
        fun fromPoint(json: JsonObject): BatteryRecord = BatteryRecord(
            json.long("t"), json.number("v"), json.number("a"), json.number("w"), json.int("soc"),
            json.int("temp", -128), json.int("state").takeIf { it in 0..2 } ?: -1,
            json.int("pwr").takeIf { it == 0 || it == 1 } ?: -1, json.int("odo").takeIf { it >= 0 } ?: -1,
            json.int("cf").takeIf { it in 0..65534 } ?: -1
        )
    }
}

internal object BatterySample {
    /** 输入是本轮 StatusFeed 形状，不从任何缓存补齐；source 对应的时钟/原始码必须自洽。 */
    fun parse(json: JsonObject, now: Long): BatteryRecord {
        val sample = json["sample"] as? JsonObject ?: throw IllegalArgumentException("missing_sample")
        val at = json.long("batteryAt")
        require(at in 1..now && sample.long("batteryAt") == at) { "invalid_sample_time" }
        val rawSoc = sample.number("soc")
        require(rawSoc.isFinite() && rawSoc in 0.0..100.0) { "invalid_soc" }
        val soc = BatteryReading.rounded(rawSoc).toInt()
        val v = BatteryReading.voltage(sample.number("voltage"))
        val a = sample.number("current"); val w = sample.number("power")
        require(BatteryReading.complete(soc, v, a) && w.isFinite()) { "incomplete_sample" }
        val vehicleAt = json.long("vehicleAt")
        val vehicleOwned = vehicleAt in 1..now && sample.long("vehicleAt") == vehicleAt && abs(vehicleAt - at) <= 90_000L
        val source = sample.text("chargeSource")
        val codeValue = sample["chargeCode"] as? JsonPrimitive
        val code = codeValue?.takeIf { it.isString }?.content?.trim().orEmpty()
        val batteryOwned = source == "battery" && code.isNotEmpty() && code != "-1"
        val chargeOwned = batteryOwned || ((source.isEmpty() || source == "vehicle") && vehicleOwned)
        var state = if (chargeOwned) sample.int("charging").takeIf { it in 0..2 } ?: -1 else -1
        if (source.isNotEmpty() && (code.isEmpty() || code == "-1" || (code == "1") != (state == 1))) state = -1
        // 本轮车况字段才可信；与 Android 同口径，明确充电/充满时整车通电。
        val lock = if (vehicleOwned) json.int("lock") else -1
        val powered = if (state == 1 || state == 2) 1 else when (lock) { 0 -> 1; 1 -> 0; else -> -1 }
        val odo = if (vehicleOwned) json.int("totalMile").takeIf { it >= 0 } ?: -1 else -1
        val charged = if (vehicleOwned) json.int("chargedMin").takeIf { it in 0..65534 } ?: -1 else -1
        return BatteryRecord(at, v, a, w, soc, -128, state, powered, odo, charged)
    }
}
