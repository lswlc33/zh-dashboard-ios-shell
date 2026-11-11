package io.github.lswlc33.zeehoshared

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockEngineConfig
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.respondRedirect
import io.ktor.client.engine.mock.toByteArray
import io.ktor.client.plugins.HttpTimeout
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonArray
import java.security.GeneralSecurityException
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class SharedJvmTest {
    @Test fun negativeChargeSentinelUsesSharedUnknownRule() {
        assertEquals(-1, SharedBatteryReadingJvm.chargeState("-1", null, ""))
    }
    @Test fun realAesChallengeAndJavaNullReasons() {
        val key = "0123456789abcdef"
        val plain = "offline-random-123".toByteArray()
        val cipher = Cipher.getInstance("AES/ECB/PKCS5Padding").run {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key.toByteArray(), "AES")); doFinal(plain)
        }
        assertContentEquals(SharedByteProtocol.bytesField(1, plain), SharedByteProtocol.challengeResponse(cipher, key))
        assertContentEquals(SharedByteProtocol.bytesField(1, plain), SharedByteProtocol.challenge(SharedByteProtocol.hex(cipher), key))
        assertEquals("material_encoding", assertFailsWith<GeneralSecurityException> { SharedByteProtocol.challenge("zz", "bad") }.message)
        assertEquals("challenge_encoding", assertFailsWith<GeneralSecurityException> { SharedByteProtocol.challenge(null, key) }.message)
        assertEquals("frame_size", assertFailsWith<IllegalArgumentException> { SharedByteProtocol.encodeFrame(1, null) }.message)
        assertEquals("hex_format", assertFailsWith<IllegalArgumentException> { SharedByteProtocol.hex("\u0661\u0662", 2) }.message)
        assertEquals(-1, SharedBatteryReadingJvm.chargeState(null))
        assertEquals(300000L, SharedBatteryReadingJvm.MAX_GAP_MS)
    }
    @Test fun rawMultipartFilteredHeadersAndNoRedirectRetry() = runTest {
        val raw = byteArrayOf(0, 1, 2, 13, 10, 0xff.toByte(), 0x80.toByte())
        var calls = 0
        val engine = MockEngine(MockEngineConfig().apply {
            dispatcher = StandardTestDispatcher(testScheduler)
            addHandler { req ->
                calls++
                assertContentEquals(raw, req.body.toByteArray())
                assertEquals("multipart/form-data; boundary=exact-123", req.headers["content-type"])
                assertEquals("offline-signature", req.headers["cfmoto-x-sign"])
                assertNull(req.headers["host"])
                assertNull(req.headers["cookie"])
                assertEquals("https://tapi.zeehoev.com/offline?x=%2F&x=two+words", req.url.toString())
                respond(byteArrayOf(), HttpStatusCode.Found, headersOf("Location", "https://example.invalid/never-follow"))
            }
        })
        val client = HttpClient(engine) { expectSuccess = false; followRedirects = false; install(HttpTimeout) }
        val transport = SharedTransport(client, { 1000 }, CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)))
        val request = "{\"id\":\"raw\",\"url\":\"https://tapi.zeehoev.com/offline?x=%2F&x=two+words\",\"method\":\"POST\",\"headers\":{\"content-type\":\"multipart/form-data; boundary=exact-123\",\"cfmoto-x-sign\":\"offline-signature\",\"Host\":\"evil\",\"cookie\":\"no\"},\"bodyB64\":\"${TxnPolicy.encodeBody(raw)}\"}"
        assertEquals("true", transport.beginRequest(request))
        advanceUntilIdle()
        val result = (sharedJson.parseToJsonElement(transport.pollRequests()) as JsonArray).single() as kotlinx.serialization.json.JsonObject
        assertEquals(302, result.int("http")); assertEquals(1, calls)
        assertEquals("[]", transport.pollRequests())
        transport.close()
    }
    @Test fun cappedResponseAndRejectedNoNetwork() = runTest {
        var calls = 0
        val client = HttpClient(MockEngine(MockEngineConfig().apply {
            dispatcher = StandardTestDispatcher(testScheduler)
            addHandler { calls++; respond(ByteArray(TxnPolicy.MAX_RESPONSE_BYTES + 1) { 0x41 }, HttpStatusCode.OK) }
        })) {
            followRedirects = false; expectSuccess = false; install(HttpTimeout)
        }
        val transport = SharedTransport(client, { 1000 }, CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)))
        assertEquals("false", transport.beginRequest("{\"id\":\"bad\",\"url\":\"https://tapi.zeehoev.com@evil.invalid/a\"}"))
        assertEquals(0, calls)
        val rejection = (sharedJson.parseToJsonElement(transport.pollRequests()) as JsonArray).single() as kotlinx.serialization.json.JsonObject
        assertEquals("rejected", rejection.text("err")); assertEquals("host_not_allowed", rejection.text("message"))
        assertEquals("true", transport.beginRequest("{\"id\":\"large\",\"url\":\"https://h5.zeehoev.com/offline\"}"))
        advanceUntilIdle()
        val result = (sharedJson.parseToJsonElement(transport.pollRequests()) as JsonArray).single() as kotlinx.serialization.json.JsonObject
        assertEquals("true", result.text("truncated")); assertEquals(TxnPolicy.MAX_RESPONSE_BYTES, TxnPolicy.decodeBody(result.text("bodyB64")).size)
        transport.close()
    }
    @Test fun cancellationCloseTimeoutAndOverloadExactlyOnce() = runTest {
        val client = HttpClient(MockEngine(MockEngineConfig().apply {
            dispatcher = StandardTestDispatcher(testScheduler)
            addHandler { awaitCancellation() }
        })) { followRedirects = false; install(HttpTimeout) }
        val transport = SharedTransport(client, { testScheduler.currentTime + 1000 }, CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler)))
        val callbacks = mutableListOf<String>()
        fun req(id: String, timeout: Int = 60000) = "{\"id\":\"$id\",\"url\":\"https://tapi.zeehoev.com/offline\",\"timeoutMs\":$timeout}"
        transport.execute(req("cancel")) { callbacks += it }
        transport.cancel("cancel"); runCurrent()
        assertEquals(1, callbacks.size); assertEquals("cancelled", jsonObject(callbacks.single()).text("err"))
        assertEquals("[]", transport.pollRequests())
        transport.execute(req("timeout", 1)) { callbacks += it }
        runCurrent(); advanceTimeBy(2); runCurrent()
        assertEquals("timeout", jsonObject(callbacks.last()).text("err"))
        repeat(128) { assertEquals("true", transport.beginRequest(req("queued-$it"))) }
        assertEquals("false", transport.beginRequest(req("overflow")))
        val rejected = sharedJson.parseToJsonElement(transport.pollRequests()) as JsonArray
        assertEquals("overloaded", (rejected.last() as kotlinx.serialization.json.JsonObject).text("message"))
        transport.execute(req("closed-callback")) { callbacks += it }
        assertEquals("overloaded", jsonObject(callbacks.last()).text("message"))
        transport.close(); runCurrent()
        val done = sharedJson.parseToJsonElement(transport.pollRequests()) as JsonArray
        assertEquals(64, done.size)
        assertTrue(done.all { (it as kotlinx.serialization.json.JsonObject).text("err") == "closed" })
        assertEquals("[]", transport.pollRequests())
    }
}
