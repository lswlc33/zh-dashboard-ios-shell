package io.github.lswlc33.zeehoshared

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.math.abs
import kotlin.math.max

/** 只包含采样 admission / 报告 / 节流；没有平台磁盘、Keystore、后台任务或伪造点。 */
internal class BatteryHistory {
    companion object {
        const val RETENTION_MS = 31L * 24 * 60 * 60 * 1000
        const val MAX_RECORDS = 100_000
        fun recordGapMs(state: Int, powered: Int): Long = when {
            state == 1 || state == 2 -> 150_000L
            powered == 1 -> 60_000L
            else -> 300_000L
        }
        fun wanted(previous: BatteryRecord?, next: BatteryRecord): Boolean {
            if (previous == null) return true
            if (next.t <= previous.t) return false
            val edge = (next.state != previous.state && (next.state >= 0 || previous.state >= 0)) ||
                (next.powered != previous.powered && next.powered >= 0 && previous.powered >= 0)
            return edge || next.t - previous.t >= recordGapMs(next.state, next.powered) - 10_000L
        }
        fun normalizeRange(range: String): String = if (range in listOf("3d", "7d", "30d")) range else "24h"
        private fun rangeMs(range: String): Long = when (range) {
            "3d" -> 3L * 86_400_000; "7d" -> 7L * 86_400_000; "30d" -> RETENTION_MS; else -> 86_400_000
        }
        private fun bucketMs(range: String): Long = when (range) {
            "3d" -> 900_000; "7d" -> 1_800_000; "30d" -> 7_200_000; else -> 300_000
        }
        private fun round2(value: Double): Double = BatteryReading.rounded(value * 100) / 100
        fun buildReport(all: List<BatteryRecord>, inputRange: String, now: Long): JsonObject {
            require(now >= 0) { "invalid_time" }
            val range = normalizeRange(inputRange)
            val from = max(now - rangeMs(range), now - RETENTION_MS)
            val retained = all.filter { it.valid(now) && it.t >= now - RETENTION_MS }.sortedBy { it.t }.distinctBy { it.t }
            val inRange = retained.filter { it.t >= from }
            val bucket = bucketMs(range)
            val buckets = linkedMapOf<Long, BatteryRecord>()
            inRange.forEach { buckets[max(0, (it.t - from) / bucket)] = it }
            var chargeKwh = 0.0; var chargeMs = 0L
            for (i in 0 until inRange.lastIndex) {
                val a = inRange[i]; val b = inRange[i + 1]
                val dt = BatteryReading.intervalMillis(a.t, b.t)
                if (dt == 0L || a.state != 1 || b.state != 1) continue
                // 仅真实相邻两端积分；时间窗外/缺测区间不补点、不插值、不延伸到墙钟 now。
                chargeKwh += (abs(a.w) + abs(b.w)) / 2 * dt / 3_600_000_000.0
                chargeMs += dt
            }
            val totalBuckets = max(1, (now - from) / bucket + 1)
            val coverage = round2((buckets.size.toDouble() / totalBuckets).coerceAtMost(1.0))
            return buildJsonObject {
                put("ok", true); put("range", range); put("from", from); put("to", now); put("count", inRange.size)
                put("points", JsonArray(buckets.map { (b, r) -> JsonObject(r.point() + ("b" to JsonPrimitive(b))) }))
                put("summary", buildJsonObject {
                    put("socMax", inRange.maxOfOrNull { it.soc }?.let { JsonPrimitive(it) } ?: JsonNull)
                    put("socMin", inRange.minOfOrNull { it.soc }?.let { JsonPrimitive(it) } ?: JsonNull)
                    put("chargeKwh", round2(chargeKwh)); put("chargeMin", BatteryReading.rounded(chargeMs / 60_000.0).toLong())
                    put("sampleCount", inRange.size); put("coverage", coverage)
                })
                put("lastCharge", lastCharge(retained, now) ?: JsonNull)
            }
        }
        private fun lastCharge(records: List<BatteryRecord>, now: Long): JsonObject? {
            var segment = mutableListOf<BatteryRecord>()
            var last = listOf<BatteryRecord>()
            for (r in records) {
                if (r.state != 1) {
                    if (segment.isNotEmpty()) last = segment.toList()
                    segment = mutableListOf(); continue
                }
                if (segment.isNotEmpty() && BatteryReading.intervalMillis(segment.last().t, r.t) == 0L) {
                    last = segment.toList(); segment = mutableListOf()
                }
                segment += r
            }
            if (segment.isNotEmpty()) last = segment
            if (last.isEmpty()) return null
            var kwh = 0.0; var ms = 0L
            for (i in 0 until last.lastIndex) {
                val dt = BatteryReading.intervalMillis(last[i].t, last[i + 1].t)
                kwh += (abs(last[i].w) + abs(last[i + 1].w)) / 2 * dt / 3_600_000_000.0; ms += dt
            }
            val start = last.first(); val end = last.last()
            return buildJsonObject {
                put("start", start.t); put("end", end.t); put("startSoc", start.soc); put("endSoc", end.soc)
                put("minutes", BatteryReading.rounded(ms / 60_000.0).toLong()); put("kwh", round2(kwh))
                put("peakW", BatteryReading.rounded(last.maxOf { abs(it.w) }).toLong())
                put("ongoing", records.lastOrNull()?.t == end.t && now - end.t <= BatteryReading.MAX_GAP_MS)
                put("charging", true)
            }
        }
    }
    private val records = mutableListOf<BatteryRecord>()
    var revision: Long = 0; private set
    fun accept(record: BatteryRecord, now: Long): String {
        require(record.valid(now)) { "invalid_sample" }
        val previous = records.lastOrNull()
        if (previous != null && record.t <= previous.t) return "out_of_order"
        if (!wanted(previous, record)) return "throttled"
        val cutoff = now - RETENTION_MS
        while (records.isNotEmpty() && records.first().t < cutoff) records.removeAt(0)
        if (records.size >= MAX_RECORDS) return "overloaded"
        records += record; revision++
        return "accepted"
    }
    fun all(): List<BatteryRecord> = records.toList()
    fun restore(values: List<BatteryRecord>, now: Long, savedRevision: Long = 0) {
        require(values.size <= MAX_RECORDS) { "history_too_many_points" }
        require(savedRevision >= 0) { "invalid_revision" }
        var previous = 0L
        values.forEach { require(it.valid(now) && it.t > previous) { "invalid_history" }; previous = it.t }
        records.clear(); records += values.filter { it.t >= now - RETENTION_MS }
        // 冷启动重放不是新的采样；恢复已保存水位，不让下一次accept的revision退回1/2。
        revision = maxOf(revision, savedRevision)
    }
    fun clear() { records.clear(); revision++ }
}

/** 每个实例只绑定一台车；持久化由 Swift/Android 平台负责，本 facade 不宣称已落盘。 */
class SharedBattery {
    private val lock = StateLock()
    private val history = BatteryHistory()
    private var vin = ""
    private var reportKey = ""
    private var reportAt = 0L
    private var reportRevision = -1L
    private var cachedReport = ""

    fun readingJSON(json: String): String = safeJson { BatteryReading.reading(jsonObject(json)).toString() }
    fun acceptSampleJSON(json: String, now: Long): String = safeJson {
        val input = jsonObject(json)
        val incomingVin = input.text("vin")
        require(incomingVin.isNotBlank() && incomingVin.length <= 128) { "missing_vin" }
        val record = BatterySample.parse(input, now)
        lock.withLock {
            require(vin.isEmpty() || vin == incomingVin) { "scope_mismatch" }
            val result = history.accept(record, now)
            if (result == "accepted") vin = incomingVin
            buildJsonObject {
                put("ok", true); put("accepted", result == "accepted"); put("status", result)
                put("persisted", false); put("vin", incomingVin); put("revision", history.revision)
                if (result == "accepted") put("sample", record.point())
            }.toString()
        }
    }
    fun reportJSON(range: String, now: Long): String = safeJson {
        lock.withLock {
            require(now >= 0) { "invalid_time" }
            val key = BatteryHistory.normalizeRange(range)
            if (key == reportKey && reportRevision == history.revision && now >= reportAt && now - reportAt < 60_000L) cachedReport
            else {
                val report = BatteryHistory.buildReport(history.all(), key, now)
                cachedReport = JsonObject(report + ("vin" to JsonPrimitive(vin))).toString()
                reportKey = key; reportAt = now; reportRevision = history.revision
                cachedReport
            }
        }
    }
    fun snapshotJSON(): String = lock.withLock {
        buildJsonObject {
            put("ok", true); put("version", 4); put("vin", vin); put("revision", history.revision)
            put("records", JsonArray(history.all().map { it.point() }))
        }.toString()
    }
    fun restoreJSON(json: String, now: Long): String = safeJson {
        val input = jsonObject(json, 32 * 1024 * 1024)
        require(input.int("version") == 4) { "history_version_unsupported" }
        val incomingVin = input.text("vin")
        require(incomingVin.isNotBlank() && incomingVin.length <= 128) { "missing_vin" }
        val values = input["records"] as? JsonArray ?: throw IllegalArgumentException("invalid_history")
        require(values.size <= BatteryHistory.MAX_RECORDS) { "history_too_many_points" }
        val records = values.map { BatteryRecord.fromPoint(it as? JsonObject ?: throw IllegalArgumentException("invalid_history")) }
        lock.withLock {
            require(vin.isEmpty() || vin == incomingVin) { "scope_mismatch" }
            history.restore(records, now, input.long("revision")); vin = incomingVin
            // restore 可能是同revision的存储回放/回滚；必须使内存报告缓存失效，不能继续显示替换前的数据。
            reportRevision = -1; cachedReport = ""
            buildJsonObject { put("ok", true); put("count", history.all().size); put("revision", history.revision); put("persisted", false) }.toString()
        }
    }
    fun clear() { lock.withLock { history.clear(); vin = ""; cachedReport = ""; reportRevision = -1 } }
    fun encodeV4RecordHex(recordJSON: String): String = try {
        InductiveKeyCodec.hex(BatteryV4Codec.encodeRecord(BatteryRecord.fromPoint(jsonObject(recordJSON))))
    } catch (bad: IllegalArgumentException) { "error:" + (bad.message ?: "invalid_input") }
    fun decodeV4RecordJSON(recordHex: String): String = safeJson {
        BatteryV4Codec.decodeRecord(InductiveKeyCodec.hex(recordHex, BatteryV4Codec.RECORD_SIZE)).point().toString()
    }
    fun encodeV4SamplesHex(samplesJSON: String): String = try {
        val values = sharedJson.parseToJsonElement(samplesJSON) as? JsonArray ?: throw IllegalArgumentException("invalid_history")
        require(values.size <= 4096) { "history_too_many_points" }
        InductiveKeyCodec.hex(BatteryV4Codec.encodeSamples(values.map { BatteryRecord.fromPoint(it as? JsonObject ?: throw IllegalArgumentException("invalid_history")) }))
    } catch (bad: IllegalArgumentException) { "error:" + (bad.message ?: "invalid_input") }
    fun decodeV4SamplesJSON(samplesHex: String): String = safeJson {
        JsonArray(BatteryV4Codec.decodeSamples(InductiveKeyCodec.hex(samplesHex, 4096 * BatteryV4Codec.RECORD_SIZE, true)).map { it.point() }).toString()
    }
}
