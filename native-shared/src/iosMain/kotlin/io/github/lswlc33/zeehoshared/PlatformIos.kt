@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.github.lswlc33.zeehoshared

import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout
import io.ktor.http.HttpHeaders
import kotlinx.cinterop.LongVar
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.convert
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.set
import kotlinx.cinterop.usePinned
import platform.CoreCrypto.CCCrypt
import platform.CoreCrypto.CC_SHA256
import platform.CoreCrypto.kCCAlgorithmAES128
import platform.CoreCrypto.kCCDecrypt
import platform.CoreCrypto.kCCOptionECBMode
import platform.CoreCrypto.kCCOptionPKCS7Padding
import platform.CoreCrypto.kCCSuccess
import platform.Foundation.NSDate
import platform.Foundation.NSRecursiveLock
import platform.Foundation.NSURLRequestReloadIgnoringLocalCacheData
import platform.Foundation.timeIntervalSince1970
import platform.posix.size_tVar

internal actual fun platformNowMillis(): Long =
    (NSDate().timeIntervalSince1970 * 1000).toLong()
internal actual class StateLock {
    private val lock = NSRecursiveLock()
    actual fun <T> withLock(block: () -> T): T {
        lock.lock()
        return try { block() } finally { lock.unlock() }
    }
}
internal actual fun platformSha256(bytes: ByteArray): ByteArray {
    val digest = ByteArray(32)
    val input = if (bytes.isEmpty()) byteArrayOf(0) else bytes
    input.usePinned { source ->
        digest.usePinned { target -> CC_SHA256(source.addressOf(0), bytes.size.convert(), target.addressOf(0).reinterpret()) }
    }
    return digest
}
internal actual fun platformDecryptChallenge(encrypted: ByteArray, key: ByteArray): ByteArray = memScoped {
    val output = ByteArray(encrypted.size + 16)
    // CCCrypt 的 dataOutMoved 在 64 位平台是 size_t = 无符号 64 位；用 LongVar 承接
    // （LongVarOf<Long> 在 Kotlin/Native 一定暴露 .value），再按位数 reinterpret 成 size_t 指针。
    val written = alloc<LongVar>()
    written.value = 0L
    try {
        val status = key.usePinned { keyPtr -> encrypted.usePinned { source -> output.usePinned { target ->
            CCCrypt(
                kCCDecrypt, kCCAlgorithmAES128, kCCOptionECBMode or kCCOptionPKCS7Padding,
                keyPtr.addressOf(0), key.size.convert(), null,
                source.addressOf(0), encrypted.size.convert(), target.addressOf(0), output.size.convert(),
                written.ptr.reinterpret()
            )
        } } }
        val writtenBytes = written.value
        require(status == kCCSuccess && writtenBytes in 0..output.size.toLong()) { "challenge_decryption" }
        output.copyOf(writtenBytes.toInt())
    } finally { output.fill(0) }
}
internal actual fun platformHttpClient(): HttpClient = HttpClient(Darwin) {
    expectSuccess = false
    followRedirects = false
    install(HttpTimeout)
    engine {
        // Ktor 3.6.1 的 KtorNSURLSessionDelegate 明确 completionHandler(null) 禁止 NSURLSession 自带redirect；
        // 上面的 followRedirects=false 同时关闭 Ktor 层。没有 Retry/ContentNegotiation 插件。
        configureSession {
            HTTPShouldSetCookies = false
            HTTPCookieStorage = null
            URLCache = null
            requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData
        }
        configureRequest {
            // 注意：这里不能写 setValue(...)——Kotlin 的 KMutableProperty.setValue 重载会遮蔽
            // NSMutableURLRequest.setValue:forHTTPHeaderField:。改用 addValue 避免同名冲突，
            // 缓存策略走属性赋值（cachePolicy 是可变属性）。
            addValue("identity", forHTTPHeaderField = "Accept-Encoding")
            cachePolicy = NSURLRequestReloadIgnoringLocalCacheData
        }
    }
}
