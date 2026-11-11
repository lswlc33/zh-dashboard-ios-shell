@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.github.lswlc33.zeehoshared

import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout
import io.ktor.http.HttpHeaders
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
    // size_tVar 在 64 位 Apple 平台是 ULongVarOf<ULong>：用 .value 读写，
    // 且必须显式给 ULong 字面量，不能依赖 convert() 推断。
    val written = alloc<size_tVar>()
    written.value = 0uL
    try {
        val status = key.usePinned { keyPtr -> encrypted.usePinned { source -> output.usePinned { target ->
            CCCrypt(
                kCCDecrypt, kCCAlgorithmAES128, kCCOptionECBMode or kCCOptionPKCS7Padding,
                keyPtr.addressOf(0), key.size.convert(), null,
                source.addressOf(0), encrypted.size.convert(), target.addressOf(0), output.size.convert(), written.ptr
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
            // Darwin 引擎的 configureRequest 拿到的是 NSMutableURLRequest（平台类型），
            // 直接调它的 setValue:forHTTPHeaderField: 与 setCachePolicy:，不走 Ktor 的 header DSL。
            this.setValue("identity", forHTTPHeaderField = "Accept-Encoding")
            this.setCachePolicy(NSURLRequestReloadIgnoringLocalCacheData)
        }
    }
}
