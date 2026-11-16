package io.github.lswlc33.zeehoshared

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class SharedCoreTest {
    @Test fun capturedFramesStreamUnknownFieldsAndAscii() {
        val protocol = SharedProtocol()
        assertEquals("abcd5d0200080067cf", protocol.encodeFrameHex(93, "0800"))
        assertEquals("abcdf70000f7cf", protocol.encodeFrameHex(247, ""))
        assertEquals("cbf43926", protocol.crc32Hex("313233343536373839"))
        assertEquals("error:hex_format", protocol.encodeFrameHex(93, "\uff10\uff18"))
        assertEquals(0, (jsonObject(protocol.feedFramesJSON("ffabcd5d02", 1))["frames"] as JsonArray).size)
        val result = jsonObject(protocol.feedFramesJSON("00080067cfabcdf70000f7cf", 2))
        assertEquals(2, (result["frames"] as JsonArray).size)
        val extended = InductiveKeyCodec.hex("a00101a00102ad0178563412", 240)
        val fields = InductiveKeyCodec.fields(extended)
        assertEquals(3, fields.size)
        assertContentEquals(extended, fields.fold(byteArrayOf()) { bytes, field -> bytes + field.value.raw })
        assertFailsWith<IllegalArgumentException> { InductiveKeyCodec.protobuf(extended) }
        val telem = jsonObject(protocol.decodeTelemetryJSON(protocol.encodeFrameHex(253, "08"), 10))
        assertTrue((telem["fields"] as JsonObject).containsKey("error"))
    }
    @Test fun readingSamplingV4AndNoInventedEnergy() {
        assertEquals(-1, BatteryReading.chargeState(null, null))
        assertEquals(0, BatteryReading.chargeState("2", "\u672a\u5145\u7535"))
        assertEquals(2, BatteryReading.chargeState("2", "\u5df2\u5145\u6ee1"))
        assertEquals(0.0, BatteryReading.currentAmp(72.0, 0.0, 0.0))
        assertEquals(-1.0, BatteryReading.currentAmp(72.0, -1.0, Double.NaN))
        assertEquals(0L, BatteryReading.intervalMillis(1000, 301001))
        val record = BatteryRecord(1000, 72.1, -1.2, -87.0, 50, state = -1, powered = -1, chargedMin = -1)
        val encoded = BatteryV4Codec.encodeRecord(record)
        assertEquals(24, encoded.size)
        val decoded = BatteryV4Codec.decodeRecord(encoded)
        assertEquals(record, decoded)
        assertContentEquals(encoded, BatteryV4Codec.encodeRecord(decoded))
        val sparse = listOf(record.copy(state = 1, w = 1000.0), record.copy(t = 601001, state = 1, w = 1000.0))
        val report = BatteryHistory.buildReport(sparse, "24h", 700000)
        assertEquals(0.0, (report["summary"] as JsonObject).number("chargeKwh"))
        assertEquals(0L, (report["summary"] as JsonObject).long("chargeMin"))
    }
    @Test fun ocvReportRetainsVoltageAndStateInCompactRows() {
        val samples = (1..4).map { index ->
            BatteryRecord(index * 300_000L, 79.0 + index, -0.1, -8.0, 20 + index * 10,
                state = 0, powered = 0)
        }
        val report = BatteryHistory.buildOcvReport(samples, 2_000_000L)
        val rows = report["samples"] as JsonArray
        assertEquals(4, rows.size)
        assertEquals(80.0, (rows[0] as JsonArray)[2].toString().toDouble())
        assertEquals(0, (rows[0] as JsonArray)[4].toString().toInt())
        assertEquals(0, (rows[0] as JsonArray)[5].toString().toInt())
        assertEquals(false, report["truncated"].toString().toBoolean())
        val metadata = report["metadata"] as JsonObject
        assertFalse(metadata["truncated"].toString().toBoolean())
        assertTrue(metadata["staticInferenceAllowed"].toString().toBoolean())
        assertEquals("raw", metadata.text("samplingStrategy"))
        assertEquals(4, metadata.int("returnedCount"))
    }

    @Test fun ocvReportCapsUniformSamplingAndRetainsRangeEndpoints() {
        val samples = (0 until 12_000).map { index ->
            val static = index % 2 == 0
            BatteryRecord(index * 60_000L + 1_000L, 70.0, if (static) 0.0 else 4.0,
                if (static) 0.0 else 300.0, 20 + index % 70, state = if (static) 0 else 1,
                powered = if (static) 0 else 1)
        }
        val report = BatteryHistory.buildOcvReport(samples, 12_100 * 60_000L)
        val rows = report["samples"] as JsonArray
        val metadata = report["metadata"] as JsonObject
        assertEquals(12_000, report.int("count"))
        assertEquals(6_000, rows.size)
        assertTrue(report["truncated"].toString().toBoolean())
        assertTrue(metadata["truncated"].toString().toBoolean())
        assertFalse(metadata["staticInferenceAllowed"].toString().toBoolean(), "sampling gaps cannot prove static dwell")
        assertEquals("uniform", metadata.text("samplingStrategy"))
        assertEquals(6_000, metadata.int("returnedCount"))
        assertEquals(samples.first().t, (rows.first() as JsonArray)[0].toString().toLong())
        assertEquals(samples.last().t, (rows.last() as JsonArray)[0].toString().toLong())
        assertEquals(samples.first().t, metadata.long("from"))
        assertEquals(samples.last().t, metadata.long("to"))
        assertTrue(rows.any { (it as JsonArray)[4].toString().toInt() == 0 }, "static samples remain represented")
        assertTrue(rows.any { (it as JsonArray)[4].toString().toInt() == 1 }, "dynamic endpoint cannot be removed by static priority")
    }

    @Test fun snapshotRestoreKeepsRevisionAndNoDuplicate() {
        fun sample(at: Long): String = buildJsonObject {
            put("vin", "OFFLINE-VIN"); put("batteryAt", at); put("vehicleAt", at); put("lock", 1)
            put("sample", buildJsonObject {
                put("batteryAt", at); put("vehicleAt", at); put("soc", 50); put("voltage", 72); put("current", 5); put("power", 360)
                put("charging", 1); put("chargeSource", "vehicle"); put("chargeCode", "1")
            })
        }.toString()
        val first = SharedBattery()
        assertTrue(jsonObject(first.acceptSampleJSON(sample(1000), 1000)).text("accepted") == "true")
        first.acceptSampleJSON(sample(151000), 151000)
        val saved = jsonObject(first.snapshotJSON())
        val copy = SharedBattery()
        copy.reportJSON("24h", 151000)
        val restored = jsonObject(copy.restoreJSON(saved.toString(), 151000))
        assertEquals(2, jsonObject(copy.reportJSON("24h", 151000)).int("count"))
        assertEquals(saved.long("revision"), restored.long("revision"))
        assertEquals("out_of_order", jsonObject(copy.acceptSampleJSON(sample(151000), 151000)).text("status"))
        val next = jsonObject(copy.acceptSampleJSON(sample(301000), 301000))
        assertTrue(next.long("revision") > saved.long("revision"))
        assertEquals(3, (jsonObject(copy.snapshotJSON())["records"] as JsonArray).size)
        val invalid = jsonObject(sample(500000)).toMutableMap().apply { remove("sample") }
        assertFalse(jsonObject(copy.acceptSampleJSON(JsonObject(invalid).toString(), 500000)).text("ok") == "true")
    }
    @Test fun ledgerUnknownContinuityAndClearWatermark() {
        val facade = SharedChargeLog()
        var ledger = facade.createJSON("{\"ownerId\":\"OFFLINE\",\"ownerUid\":\"U\",\"vin\":\"V\"}")
        ledger = facade.reduceJSON(ledger, "{\"type\":\"state\",\"state\":1,\"at\":1000}", 1000)
        val unchanged = facade.reduceJSON(ledger, "{\"type\":\"state\",\"state\":-1,\"at\":2000}", 2000)
        assertEquals(ledger, unchanged)
        val samples = listOf(BatteryRecord(1000, 72.0, 5.0, 360.0, 50, state = 1),
            BatteryRecord(2000, 72.0, 5.0, 360.0, 50, state = -1), BatteryRecord(3000, 72.0, 5.0, 360.0, 51, state = 1))
        val hydrated = jsonObject(facade.hydrateJSON(ledger, JsonArray(samples.map { it.point() }).toString(), 3000))
        val points = (hydrated["current"] as JsonObject)["pts"] as JsonArray
        assertEquals(2, points.size)
        assertEquals("unknown-state", (points[1] as JsonObject).text("gapReason"))
        val tombstone = jsonObject(facade.reduceJSON(ledger, "{\"type\":\"clear\"}", 4000))
        assertEquals(4000, tombstone.long("clearAt"))
        assertTrue(tombstone.long("revision") > jsonObject(ledger).long("revision"))
        assertEquals(tombstone.toString(), facade.reduceJSON(tombstone.toString(), "{\"type\":\"state\",\"state\":1,\"at\":3000}", 5000))
    }
}
