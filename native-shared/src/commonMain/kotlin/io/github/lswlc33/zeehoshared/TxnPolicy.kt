package io.github.lswlc33.zeehoshared

import io.ktor.http.Url
import kotlin.io.encoding.Base64
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal data class TxnRequest(val id: String, val url: String, val method: String, val headers: Map<String, String>, val body: ByteArray?, val timeoutMs: Int)
internal data class TxnResult(val id: String, val http: Int, val bodyB64: String?, val at: Long, val truncated: Boolean = false, val err: String = "", val message: String = "") {
    fun json(): String = buildJsonObject {
        put("id", id); put("http", if (err.isEmpty()) http else 0)
        put("bodyB64", if (err.isEmpty()) bodyB64?.let { JsonPrimitive(it) } ?: JsonNull else JsonNull)
        put("at", at); put("truncated", truncated)
        if (err.isNotEmpty()) { put("err", err); put("message", message) }
    }.toString()
}

/** 与 TXN_BRIDGE_CONTRACT 字段一致；这里只验证原请求，不生成签名、重排参数或改写 multipart。 */
internal object TxnPolicy {
    const val MAX_BODY_BYTES = 8 * 1024 * 1024
    const val MAX_RESPONSE_BYTES = 4 * 1024 * 1024
    const val MAX_HEADER_ENTRIES = 32
    const val MAX_URL_CHARS = 4096
    const val MAX_RESULTS = 64
    const val MAX_TOTAL = 128
    const val RESULT_TTL_MS = 120_000L
    const val MAX_JSON_CHARS = (MAX_BODY_BYTES + 2) / 3 * 4 + 64 * 1024
    private val allowedHeaders = setOf("cfmoto-x-param", "cfmoto-x-sign", "cfmoto-x-sign-type", "cfmoto-sign", "cfmoto-sign-type", "authorization", "content-type", "accept")
    private val allowedHosts = setOf("tapi.zeehoev.com", "h5.zeehoev.com")

    fun parse(json: JsonObject): TxnRequest {
        val id = json.text("id")
        require(id.isNotEmpty()) { "missing_id" }
        require(id.length <= 256 && id.none { it.code < 32 || it.code == 127 }) { "bad_id" }
        val url = json.text("url")
        validateUrl(url)
        val method = json.text("method", "GET").trim().uppercase()
        require(method in setOf("GET", "POST", "PUT", "DELETE")) { "method_not_allowed" }
        val source = json["headers"] as? JsonObject
        require(source == null || source.size <= MAX_HEADER_ENTRIES) { "too_many_headers" }
        val headers = linkedMapOf<String, String>()
        source?.forEach { (name, value) ->
            val text = (value as? JsonPrimitive)?.takeIf { it != JsonNull }?.content.orEmpty()
            // 与旧桥一样静默丢非白名单或注入头，避免向不可信页面回显探测内容。
            if (name.lowercase() in allowedHeaders && text.isNotEmpty() && name.all { it.code in 33..126 }
                && text.none { it.code < 32 || it.code == 127 } && text.length <= 8192) headers[name.lowercase()] = text
        }
        val bodyText = json.text("bodyB64")
        val body = if (bodyText.isEmpty() || bodyText == "null") null else decodeBody(bodyText)
        // OkHttp 不允许 GET body；不能像 HttpURLConnection 那样偷偷把 GET 改成 POST。
        require(method != "GET" || body == null || body.isEmpty()) { "body_not_allowed" }
        val requestedTimeout = json.long("timeoutMs", 12_000)
        val timeout = if (requestedTimeout <= 0) 12_000 else minOf(requestedTimeout, 60_000).toInt()
        return TxnRequest(id, url, method, headers, body, timeout)
    }
    private fun validateUrl(text: String) {
        require(text.isNotEmpty() && text.length <= MAX_URL_CHARS && text.none { it.isWhitespace() || it.code < 32 || it.code == 127 || it == '\\' }) { "bad_url" }
        val separator = text.indexOf("://")
        require(separator > 0) { "bad_url" }
        val scheme = text.substring(0, separator).lowercase()
        require(scheme == "https" || scheme == "http") { "scheme_not_allowed" }
        val authority = text.substring(separator + 3).substringBefore('/').substringBefore('?').substringBefore('#')
        require(authority.isNotEmpty() && '@' !in authority && '%' !in authority) { "host_not_allowed" }
        val host = authority.substringBefore(':').lowercase()
        require(host in allowedHosts) { "host_not_allowed" }
        // 固定服务的默认端口，不能让白名单 host 被用来探测其他端口；也不受理 userinfo/fragment。
        if (':' in authority) require(authority.substringAfter(':') == if (scheme == "https") "443" else "80") { "port_not_allowed" }
        require('#' !in text) { "bad_url" }
        val parsed = try { Url(text) } catch (_: IllegalArgumentException) { throw IllegalArgumentException("bad_url") }
        require(parsed.host.lowercase() == host && parsed.protocol.name.lowercase() == scheme && parsed.user == null && parsed.password == null) { "host_not_allowed" }
    }
    fun decodeBody(text: String): ByteArray {
        val maxEncoded = (MAX_BODY_BYTES + 2) / 3 * 4
        require(text.length <= maxEncoded) { "body_too_large" }
        require(text.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '+' || it == '/' || it == '=' }) { "bad_body_base64" }
        val paddingAt = text.indexOf('=')
        val unpaddedLength = if (paddingAt < 0) text.length else paddingAt
        if (paddingAt >= 0) require(text.length % 4 == 0 && text.length - paddingAt in 1..2 && text.substring(paddingAt).all { it == '=' }) { "bad_body_base64" }
        require(unpaddedLength % 4 != 1) { "bad_body_base64" }
        require(unpaddedLength.toLong() * 6 / 8 <= MAX_BODY_BYTES) { "body_too_large" }
        return try { Base64.Default.decode(text) } catch (_: IllegalArgumentException) { throw IllegalArgumentException("bad_body_base64") }
            .also { require(it.size <= MAX_BODY_BYTES) { "body_too_large" } }
    }
    fun encodeBody(bytes: ByteArray): String = Base64.Default.encode(bytes)
}
