package io.github.lswlc33.zeehoshared

import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.HttpTimeout
import java.security.GeneralSecurityException
import java.security.MessageDigest
import java.util.concurrent.locks.ReentrantLock
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec
import kotlin.concurrent.withLock

internal actual fun platformNowMillis(): Long = System.currentTimeMillis()
internal actual fun platformSha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
internal actual fun platformDecryptChallenge(encrypted: ByteArray, key: ByteArray): ByteArray = try {
    Cipher.getInstance("AES/ECB/PKCS5Padding").run {
        init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"))
        doFinal(encrypted)
    }
} catch (failure: GeneralSecurityException) {
    throw IllegalArgumentException("challenge_decryption", failure)
}
internal actual class StateLock {
    private val lock = ReentrantLock()
    actual fun <T> withLock(block: () -> T): T = lock.withLock(block)
}
internal actual fun platformHttpClient(): HttpClient = HttpClient(OkHttp) {
    expectSuccess = false
    followRedirects = false
    install(HttpTimeout)
    engine {
        // OkHttp 自带的网络重试/重定向也必须关；Ktor 不安装 Retry、ContentNegotiation 或 ContentEncoding。
        config {
            retryOnConnectionFailure(false)
            followRedirects(false)
            followSslRedirects(false)
        }
        // BridgeInterceptor 默认会加 Accept-Encoding:gzip 并解压，不能让响应的原始字节被偷偷改写。
        addInterceptor { chain -> chain.proceed(chain.request().newBuilder().header("Accept-Encoding", "identity").build()) }
    }
}
