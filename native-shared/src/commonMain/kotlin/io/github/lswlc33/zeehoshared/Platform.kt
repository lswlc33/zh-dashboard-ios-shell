package io.github.lswlc33.zeehoshared

import io.ktor.client.HttpClient
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

internal val sharedJson = Json { ignoreUnknownKeys = true; explicitNulls = true }
internal expect fun platformNowMillis(): Long
internal expect fun platformDecryptChallenge(encrypted: ByteArray, key: ByteArray): ByteArray
internal expect fun platformSha256(bytes: ByteArray): ByteArray
internal expect fun platformHttpClient(): HttpClient
internal expect class StateLock() {
    fun <T> withLock(block: () -> T): T
}

internal fun JsonObject.text(name: String, default: String = ""): String =
    (this[name] as? JsonPrimitive)?.contentOrNull ?: default
internal fun JsonObject.long(name: String, default: Long = 0): Long =
    (this[name] as? JsonPrimitive)?.longOrNull ?: default
internal fun JsonObject.int(name: String, default: Int = -1): Int {
    val value = (this[name] as? JsonPrimitive)?.longOrNull ?: return default
    return if (value in Int.MIN_VALUE..Int.MAX_VALUE) value.toInt() else default
}
internal fun JsonObject.number(name: String): Double = BatteryReading.number(this[name])
internal fun jsonObject(text: String, maxChars: Int = 2 * 1024 * 1024): JsonObject {
    require(text.length <= maxChars) { "json_too_large" }
    return sharedJson.parseToJsonElement(text) as? JsonObject ?: throw IllegalArgumentException("bad_json")
}
internal fun finiteJson(value: Double): JsonElement = if (value.isFinite()) JsonPrimitive(value) else JsonNull
internal fun failureJson(reason: String): String = buildJsonObject {
    put("ok", false); put("error", reason)
}.toString()
internal inline fun safeJson(block: () -> String): String = try {
    block()
} catch (bad: IllegalArgumentException) {
    failureJson(bad.message?.takeIf { it.matches(Regex("[a-z0-9_]+")) } ?: "invalid_input")
}
