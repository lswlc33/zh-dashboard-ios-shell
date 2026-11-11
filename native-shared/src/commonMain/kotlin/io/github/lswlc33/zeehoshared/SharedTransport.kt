package io.github.lswlc33.zeehoshared

import io.ktor.client.HttpClient
import io.ktor.client.network.sockets.ConnectTimeoutException
import io.ktor.client.network.sockets.SocketTimeoutException
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.client.plugins.timeout
import io.ktor.client.request.prepareRequest
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.HttpMethod
import io.ktor.http.content.OutgoingContent
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.cancel
import io.ktor.utils.io.readAvailable
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlin.coroutines.coroutineContext

/** 一个原始 ByteArray 请求，只用客户端的默认平台引擎；不序列化String、不重签、不重编码multipart。 */
internal class RawTxnContent(private val bytes: ByteArray) : OutgoingContent.ByteArrayContent() {
    override val contentLength: Long = bytes.size.toLong()
    override fun bytes(): ByteArray = bytes
}

internal class TxnExecutor(
    private val client: HttpClient,
    private val clock: () -> Long,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
) {
    private class Entry(val request: TxnRequest, val completion: ((String) -> Unit)?) { lateinit var job: Job }
    private data class Completed(val result: TxnResult, val json: String)
    private data class Delivery(val entry: Entry?, val callback: ((String) -> Unit)?, val json: String)
    private val lock = StateLock()
    private val active = linkedMapOf<String, Entry>()
    private val done = ArrayDeque<Completed>()
    private val permits = Semaphore(4)
    private var closed = false

    fun begin(json: String, completion: ((String) -> Unit)?): String {
        var id = ""
        val request = try {
            val input = jsonObject(json, TxnPolicy.MAX_JSON_CHARS)
            id = input.text("id")
            TxnPolicy.parse(input)
        } catch (bad: IllegalArgumentException) {
            reject(id, bad.message?.takeIf { it.matches(Regex("[a-z0-9_]+")) } ?: "bad_json", completion)
            return "false"
        }
        val entry = Entry(request, completion)
        var rejection = ""
        lock.withLock {
            pruneLocked()
            rejection = when {
                closed -> "closed"
                request.id in active -> "duplicate_id"
                active.size + done.size >= TxnPolicy.MAX_TOTAL -> "overloaded"
                else -> ""
            }
            if (rejection.isEmpty()) {
                // LAZY job 先登记再start，立即cancel/close也能恰好落定一条回执。
                entry.job = scope.launch(start = CoroutineStart.LAZY) {
                    val result = try {
                        withTimeout(request.timeoutMs.toLong()) { permits.withPermit { perform(request) } }
                    } catch (_: TimeoutCancellationException) {
                        failed(request.id, "timeout", "request_timeout")
                    } catch (_: HttpRequestTimeoutException) {
                        failed(request.id, "timeout", "request_timeout")
                    } catch (_: ConnectTimeoutException) {
                        failed(request.id, "timeout", "connect_timeout")
                    } catch (_: SocketTimeoutException) {
                        failed(request.id, "timeout", "socket_timeout")
                    } catch (_: CancellationException) {
                        failed(request.id, "cancelled", "cancelled")
                    } catch (_: Exception) {
                        // 不回显异常原文/URL/token；传输故障不伪装成HTTP业务失败。
                        failed(request.id, "io", "network_io")
                    }
                    finish(entry, result)
                }
                active[request.id] = entry
            }
        }
        if (rejection.isNotEmpty()) {
            request.body?.fill(0)
            reject(request.id, rejection, completion)
            return "false"
        }
        entry.job.start()
        return "true"
    }
    private fun failed(id: String, err: String, message: String): TxnResult = TxnResult(id, 0, null, clock(), false, err, message)
    private fun reject(id: String, message: String, callback: ((String) -> Unit)?) {
        val result = failed(id, "rejected", message)
        val json = result.json()
        lock.withLock { if (callback == null) pushLocked(result, json) }
        deliver(callback, json)
    }
    private fun finish(entry: Entry, result: TxnResult) {
        val json = result.json()
        val accepted = lock.withLock {
            if (active[entry.request.id] !== entry) false else {
                active.remove(entry.request.id)
                if (entry.completion == null) pushLocked(result, json)
                true
            }
        }
        // 直到网络任务完成才擦除request体；cancel/close不得修改仍被引擎发送的ByteArray。
        entry.request.body?.fill(0)
        if (accepted) deliver(entry.completion, json)
    }
    private fun deliver(callback: ((String) -> Unit)?, json: String) {
        if (callback != null) try { callback(json) } catch (_: Exception) { /* 消费方异常不能泄漏队列或杀其他请求。 */ }
    }
    fun poll(): String = lock.withLock {
        pruneLocked()
        val values = done.map { it.json }
        done.clear()
        values.joinToString(",", "[", "]")
    }
    fun cancel(id: String) {
        val delivery = lock.withLock {
            val entry = active.remove(id) ?: return@withLock null
            val result = failed(id, "cancelled", "cancelled")
            val json = result.json()
            if (entry.completion == null) pushLocked(result, json)
            Delivery(entry, entry.completion, json)
        } ?: return
        delivery.entry?.job?.cancel(CancellationException("cancelled"))
        deliver(delivery.callback, delivery.json)
    }
    fun close() {
        val deliveries = lock.withLock {
            if (closed) return@withLock emptyList<Delivery>()
            closed = true
            val values = active.values.map { entry ->
                val result = failed(entry.request.id, "closed", "closed")
                val json = result.json()
                if (entry.completion == null) pushLocked(result, json)
                Delivery(entry, entry.completion, json)
            }
            active.clear()
            values
        }
        deliveries.forEach { delivery ->
            delivery.entry?.job?.cancel(CancellationException("closed"))
            deliver(delivery.callback, delivery.json)
        }
        scope.cancel(CancellationException("closed")); client.close()
    }
    private fun pushLocked(result: TxnResult, json: String) {
        pruneLocked()
        while (done.size >= TxnPolicy.MAX_RESULTS) done.removeFirst()
        done.addLast(Completed(result, json))
    }
    private fun pruneLocked() {
        val cutoff = clock() - TxnPolicy.RESULT_TTL_MS
        while (done.isNotEmpty() && done.first().result.at < cutoff) done.removeFirst()
    }
    private suspend fun perform(request: TxnRequest): TxnResult {
        return client.prepareRequest(request.url) {
            method = HttpMethod.parse(request.method)
            request.headers.forEach { (name, value) -> headers.append(name, value) }
            timeout {
                requestTimeoutMillis = request.timeoutMs.toLong()
                connectTimeoutMillis = minOf(request.timeoutMs, 15_000).toLong()
                socketTimeoutMillis = request.timeoutMs.toLong()
            }
            if (request.body != null) setBody(RawTxnContent(request.body))
            else if (request.method == "POST" || request.method == "PUT") setBody(RawTxnContent(byteArrayOf()))
        }.execute { response ->
            val (bytes, truncated) = readCapped(response.bodyAsChannel())
            try { TxnResult(request.id, response.status.value, TxnPolicy.encodeBody(bytes), clock(), truncated) }
            finally { bytes.fill(0) }
        }
    }
    internal suspend fun readCapped(channel: ByteReadChannel): Pair<ByteArray, Boolean> {
        val chunks = mutableListOf<ByteArray>()
        val buffer = ByteArray(8192)
        var total = 0; var truncated = false
        try {
            while (true) {
                coroutineContext.ensureActive()
                // 多读一个字节区分正好4MiB与真的截断；一旦超限马上取消，不先缓存整个response。
                val remaining = TxnPolicy.MAX_RESPONSE_BYTES - total
                val count = channel.readAvailable(buffer, 0, minOf(buffer.size, remaining + 1))
                if (count < 0) break
                if (count == 0) continue
                val kept = minOf(count, remaining)
                if (kept > 0) { chunks += buffer.copyOfRange(0, kept); total += kept }
                if (count > remaining) { truncated = true; channel.cancel(); break }
            }
            return ByteArray(total).also { output ->
                var at = 0
                chunks.forEach { it.copyInto(output, at); at += it.size }
            } to truncated
        } finally { buffer.fill(0); chunks.forEach { it.fill(0) } }
    }
}

/** Swift execute(json:completion:) 与 Android beginRequest/pollRequests 共用 admission/生命周期语义。 */
class SharedTransport {
    private val executor: TxnExecutor
    constructor() { executor = TxnExecutor(platformHttpClient(), ::platformNowMillis) }
    internal constructor(client: HttpClient, clock: () -> Long, scope: CoroutineScope) { executor = TxnExecutor(client, clock, scope) }
    // callback模式完成后立即释放结果；不在poll队列再复制一份，Swift/JS崩溃也不会积累完成body。
    fun execute(json: String, completion: (String) -> Unit) { executor.begin(json, completion) }
    fun beginRequest(json: String): String = executor.begin(json, null)
    fun pollRequests(): String = executor.poll()
    fun cancel(id: String) { executor.cancel(id) }
    fun close() { executor.close() }
}
