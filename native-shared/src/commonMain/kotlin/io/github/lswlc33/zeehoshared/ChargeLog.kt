package io.github.lswlc33.zeehoshared

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** 可重放的纯账本 reducer。段与墓碑由平台持久化，原始样本不在这里复制。 */
internal object ChargeLog {
    const val VERSION = 3
    const val MAX_SESSIONS = 12
    const val MAX_POINTS = 600
    private const val MAX_LEDGER_CHARS = 2 * 1024 * 1024

    fun create(owner: JsonObject): JsonObject {
        require(owner.text("ownerId").isNotBlank() && owner.text("vin").isNotBlank()) { "missing_owner" }
        require(listOf("ownerId", "ownerUid", "vin").all { owner.text(it).length <= 128 }) { "owner_size" }
        val clearAt = owner.long("clearAt")
        val revision = owner.long("revision")
        require(clearAt >= 0 && revision >= 0) { "invalid_watermark" }
        return buildJsonObject {
            put("ok", true); put("version", VERSION); put("ownerId", owner.text("ownerId")); put("ownerUid", owner.text("ownerUid")); put("vin", owner.text("vin"))
            put("revision", revision); put("clearAt", clearAt); put("at", clearAt); put("state", -1)
            put("current", JsonNull); put("segments", JsonArray(emptyList())); put("legacy", JsonArray(emptyList()))
        }
    }
    private fun validate(ledger: JsonObject) {
        require(ledger.toString().length <= MAX_LEDGER_CHARS && ledger.int("version") == VERSION) { "invalid_ledger" }
        require(ledger.text("ownerId").isNotBlank() && ledger.text("vin").isNotBlank()) { "missing_owner" }
        require(ledger.long("revision", -1) >= 0 && ledger.long("clearAt", -1) >= 0
            && ledger.long("at", -1) >= ledger.long("clearAt") && ledger.int("state") in -1..2) { "invalid_watermark" }
        val segments = ledger["segments"] as? JsonArray ?: throw IllegalArgumentException("invalid_ledger")
        val legacy = ledger["legacy"] as? JsonArray ?: throw IllegalArgumentException("invalid_ledger")
        require(segments.size + legacy.size <= MAX_SESSIONS) { "too_many_sessions" }
        val clearAt = ledger.long("clearAt")
        val current = ledger["current"]
        require(current == JsonNull || current is JsonObject) { "invalid_current" }
        if (current is JsonObject) require(current.text("id").isNotBlank() && current.long("from") > clearAt
            && current.long("from") <= ledger.long("at") && ledger.int("state") == 1) { "invalid_current" }
        if (ledger.int("state") == 1) require(current is JsonObject) { "invalid_current" }
        segments.forEach {
            val s = it as? JsonObject ?: throw IllegalArgumentException("invalid_segment")
            require(s.text("id").isNotBlank() && s.long("from") > 0 && s.long("to") >= s.long("from")) { "invalid_segment" }
        }
        legacy.forEach {
            val s = it as? JsonObject ?: throw IllegalArgumentException("invalid_legacy")
            val pts = s["pts"] as? JsonArray ?: throw IllegalArgumentException("invalid_legacy")
            require(s.text("id").isNotBlank() && pts.size <= MAX_POINTS) { "invalid_legacy" }
            var previous = 0L
            pts.forEach { p ->
                val record = BatteryRecord.fromPoint(p as? JsonObject ?: throw IllegalArgumentException("invalid_legacy"))
                require(record.t > previous && BatteryReading.complete(record.soc, record.v, record.a) && record.w.isFinite()) { "invalid_legacy" }
                previous = record.t
            }
        }
    }
    private fun nextRevision(ledger: JsonObject, now: Long): Long {
        require(ledger.long("revision") < Long.MAX_VALUE) { "revision_overflow" }
        return maxOf(now, ledger.long("revision") + 1)
    }
    fun reduce(ledger: JsonObject, event: JsonObject, now: Long): JsonObject {
        require(now >= 0) { "invalid_time" }
        validate(ledger)
        listOf("ownerId", "ownerUid", "vin").forEach {
            if (event.containsKey(it)) require(event.text(it) == ledger.text(it)) { "owner_mismatch" }
        }
        val next = ledger.toMutableMap()
        when (event.text("type")) {
            "state" -> {
                val state = event.int("state")
                val at = event.long("at")
                require(state in -1..2 && at in 1..now) { "invalid_state" }
                // 未知状态不能封掉持续充电段，也不能冒充0；采样里的未知点另给 hydrate 留缺口证据。
                if (state < 0 || at <= ledger.long("clearAt") || at <= ledger.long("at")) return ledger
                val before = ledger.int("state")
                if (state == 1 && before != 1) {
                    val id = event.text("id").ifEmpty { segmentId(ledger, at) }
                    require(id.length <= 200 && id.isNotBlank()) { "invalid_segment_id" }
                    next["current"] = buildJsonObject { put("id", id); put("from", at) }
                } else if (state != 1 && before == 1) {
                    val current = ledger["current"] as JsonObject
                    val segments = (ledger["segments"] as JsonArray).toMutableList()
                    segments.add(0, buildJsonObject { put("id", current.text("id")); put("from", current.long("from")); put("to", at) })
                    next["segments"] = JsonArray(segments); next["current"] = JsonNull
                    retainNewest(next)
                }
                next["at"] = JsonPrimitive(at); next["state"] = JsonPrimitive(state); next["revision"] = JsonPrimitive(nextRevision(ledger, now))
            }
            "clear" -> {
                val at = maxOf(now, ledger.long("clearAt"), ledger.long("at"))
                next["clearAt"] = JsonPrimitive(at); next["at"] = JsonPrimitive(at); next["state"] = JsonPrimitive(-1)
                next["revision"] = JsonPrimitive(nextRevision(ledger, now)); next["current"] = JsonNull
                next["segments"] = JsonArray(emptyList()); next["legacy"] = JsonArray(emptyList())
            }
            "floor" -> {
                val floor = event.long("clearAt", -1); val revision = event.long("revision", -1)
                require(floor >= 0 && revision >= 0 && floor <= now) { "invalid_watermark" }
                if (floor > ledger.long("clearAt")) {
                    next["clearAt"] = JsonPrimitive(floor); next["at"] = JsonPrimitive(maxOf(floor, ledger.long("at")))
                    next["state"] = JsonPrimitive(-1); next["current"] = JsonNull
                    next["segments"] = JsonArray(emptyList()); next["legacy"] = JsonArray(emptyList())
                }
                next["revision"] = JsonPrimitive(maxOf(revision, ledger.long("revision")))
            }
            else -> throw IllegalArgumentException("invalid_event")
        }
        return JsonObject(next).also { validate(it) }
    }
    private fun segmentId(ledger: JsonObject, at: Long): String {
        // 由冻结身份+真实起点产生稳定ID，重放不生新段，也无需平台随机源或真实凭据。
        val identity = JsonArray(listOf(JsonPrimitive(ledger.text("ownerId")), JsonPrimitive(ledger.text("ownerUid")), JsonPrimitive(ledger.text("vin")), JsonPrimitive(at)))
        return "charge-" + InductiveKeyCodec.hex(platformSha256(identity.toString().encodeToByteArray())).take(32)
    }
    private fun retainNewest(ledger: MutableMap<String, JsonElement>) {
        val all = mutableListOf<Pair<Boolean, JsonObject>>()
        (ledger["segments"] as JsonArray).forEach { all += false to (it as JsonObject) }
        (ledger["legacy"] as JsonArray).forEach { all += true to (it as JsonObject) }
        val kept = all.sortedByDescending { (_, s) -> (s["pts"] as? JsonArray)?.lastOrNull()?.let { (it as JsonObject).long("t") } ?: s.long("to", s.long("from")) }.take(MAX_SESSIONS)
        ledger["segments"] = JsonArray(kept.filter { !it.first }.map { it.second })
        ledger["legacy"] = JsonArray(kept.filter { it.first }.map { it.second })
    }
    fun hydrate(ledger: JsonObject, samples: List<BatteryRecord>, now: Long): JsonObject {
        validate(ledger)
        require(now >= 0 && samples.size <= BatteryHistory.MAX_RECORDS) { "history_too_many_points" }
        val clearAt = ledger.long("clearAt")
        var previous = 0L
        samples.forEach { require(it.valid(now) && it.t > previous) { "invalid_history" }; previous = it.t }
        val pool = samples.filter { it.t > clearAt && it.t >= now - BatteryHistory.RETENTION_MS }
        val current = ledger["current"] as? JsonObject
        val currentCurve = current?.let {
            val from = maxOf(clearAt + 1, it.long("from"))
            JsonObject(slice(pool, from, now) + mapOf("id" to JsonPrimitive(it.text("id")), "ended" to JsonPrimitive(false),
                "at" to JsonPrimitive((sliceLastTime(pool, from, now) ?: from))))
        }
        val sessions = mutableListOf<JsonObject>()
        (ledger["segments"] as JsonArray).forEach {
            val s = it as JsonObject
            val from = maxOf(clearAt + 1, s.long("from")); val to = minOf(now, s.long("to"))
            if (to >= from) sessions += JsonObject(slice(pool, from, to) + mapOf("id" to JsonPrimitive(s.text("id")), "ended" to JsonPrimitive(true), "at" to JsonPrimitive(to)))
        }
        (ledger["legacy"] as JsonArray).forEach {
            val s = it as JsonObject
            val pts = (s["pts"] as JsonArray).filter { p -> (p as JsonObject).long("t") > clearAt && p.long("t") in now - BatteryHistory.RETENTION_MS..now }
            if (pts.isNotEmpty()) sessions += JsonObject(s + mapOf("pts" to JsonArray(pts), "at" to JsonPrimitive((pts.last() as JsonObject).long("t")), "ended" to JsonPrimitive(true)))
        }
        return buildJsonObject {
            put("ok", true); put("version", 2)
            listOf("vin", "ownerId", "ownerUid", "revision", "clearAt", "at", "state").forEach { put(it, ledger[it] ?: JsonNull) }
            put("current", currentCurve ?: JsonNull); put("sessions", JsonArray(sessions.sortedByDescending { it.long("at") }.take(MAX_SESSIONS)))
        }
    }
    private fun sliceLastTime(pool: List<BatteryRecord>, from: Long, to: Long): Long? = pool.lastOrNull { it.t in from..to && it.state == 1 }?.t
    fun slice(pool: List<BatteryRecord>, from: Long, to: Long): JsonObject {
        val points = ArrayDeque<JsonObject>()
        var rawCount = 0; var unknownGap = false; var previousChargingAt = 0L
        pool.forEach { record ->
            if (record.t !in from..to) return@forEach
            if (record.state != 1) { unknownGap = record.state < 0; return@forEach }
            var point = record.point()
            val longGap = previousChargingAt > 0 && BatteryReading.intervalMillis(previousChargingAt, record.t) == 0L
            if (unknownGap || longGap) point = JsonObject(point + mapOf("gap" to JsonPrimitive(true), "healthGap" to JsonPrimitive(true),
                "gapReason" to JsonPrimitive(if (unknownGap) "unknown-state" else "sample-gap")))
            unknownGap = false; previousChargingAt = record.t; rawCount++
            points.addLast(point); if (points.size > MAX_POINTS) points.removeFirst()
        }
        return buildJsonObject {
            put("pts", JsonArray(points.toList())); put("rawCount", rawCount); put("truncated", rawCount > MAX_POINTS); put("from", from); put("to", to)
        }
    }
}

class SharedChargeLog {
    fun createJSON(ownerJSON: String): String = safeJson { ChargeLog.create(jsonObject(ownerJSON)).toString() }
    fun reduceJSON(ledgerJSON: String, eventJSON: String, now: Long): String = safeJson {
        ChargeLog.reduce(jsonObject(ledgerJSON), jsonObject(eventJSON), now).toString()
    }
    fun hydrateJSON(ledgerJSON: String, samplesJSON: String, now: Long): String = safeJson {
        require(samplesJSON.length <= 32 * 1024 * 1024) { "history_too_large" }
        val input = sharedJson.parseToJsonElement(samplesJSON)
        val samples = (input as? JsonArray) ?: (input as? JsonObject)?.get("records") as? JsonArray ?: throw IllegalArgumentException("invalid_history")
        require(samples.size <= BatteryHistory.MAX_RECORDS) { "history_too_many_points" }
        ChargeLog.hydrate(jsonObject(ledgerJSON), samples.map { BatteryRecord.fromPoint(it as? JsonObject ?: throw IllegalArgumentException("invalid_history")) }, now).toString()
    }
}
