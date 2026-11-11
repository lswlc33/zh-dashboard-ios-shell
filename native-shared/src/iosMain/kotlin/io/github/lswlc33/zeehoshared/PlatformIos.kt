@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.github.lswlc33.zeehoshared

import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout
import io.ktor.http.HttpHeaders
import kotlinx.cinterop.ULongVar
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
    // 用 ULongVar 的 ptr 传给 CCCrypt，读回时通过 ptr[0] 取值；
    // 不用 size_tVar 的 .value（Kotlin/Native 对 ULongVarOf 不暴露该属性）。
    val written = alloc<ULongVar>()
    written.value = 0uL
    try {
        val status = key.usePinned { keyPtr -> encrypted.usePinned { source -> output.usePinned { target ->
            CCCrypt(
                kCCDecrypt, kCCAlgorithmAES128, kCCOptionECBMode or kCCOptionPKCS7Padding,
                keyPtr.addressOf(0), key.size.convert(), null,
                source.addressOf(0), encrypted.size.convert(), target.addressOf(0), output.size.convert(),
                written.ptr.reinterpret()
            )
        } } }
        val writtenBytes = written.value.toLong()
        require(status == kCCSuccess && writtenBytes <= output.size) { "challenge_decryption" }
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
            // Ktor 官方示例就是在 configureRequest 里直接调 NSMutableURLRequest 的方法
            // （如 setAllowsCellularAccess(true)），receiver 是平台类型，不加 this 也不走 Ktor header DSL。
            setValue("identity", forHTTPHeaderField = "Accept-Encoding")
            setCachePolicy(NSURLRequestReloadIgnoringLocalCacheData)
        }
    }
}
