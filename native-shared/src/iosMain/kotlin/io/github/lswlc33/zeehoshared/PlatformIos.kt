@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.github.lswlc33.zeehoshared

import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.reinterpret
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
    // CCCrypt 的最后一个参数 dataOutMoved 可为 null（调用方不需要实际写出长度）：
    // 这里直接传 null，避免依赖 cinterop 的 Var 类型读写 API（ULongVarOf/LongVarOf 在本版
    // Kotlin/Native 都不暴露 .value），随后用 PKCS7 去填充算出真实长度。
    val status = key.usePinned { keyPtr -> encrypted.usePinned { source -> output.usePinned { target ->
        CCCrypt(
            kCCDecrypt, kCCAlgorithmAES128, kCCOptionECBMode or kCCOptionPKCS7Padding,
            keyPtr.addressOf(0), key.size.convert(), null,
            source.addressOf(0), encrypted.size.convert(), target.addressOf(0), output.size.convert(),
            null
        )
    } } }
    try {
        require(status == kCCSuccess) { "challenge_decryption" }
        // PKCS7 去填充：末字节即填充长度（1..16）；不合法就说明密文/密钥不对。
        val pad = output.last().toInt() and 0xff
        require(pad in 1..16 && pad <= output.size) { "challenge_decryption" }
        val plain = output.copyOf(output.size - pad)
        require(pad == 1 || (output.size - pad until output.size).all { (output[it].toInt() and 0xff) == pad }) {
            "challenge_decryption"
        }
        plain
    } finally { output.fill(0) }
}
internal actual fun platformHttpClient(): HttpClient = HttpClient(Darwin) {
    expectSuccess = false
    followRedirects = false
    install(HttpTimeout)
    engine {
        // Ktor 3.6.1 的 KtorNSURLSessionDelegate 明确 completionHandler(null) 禁止 NSURLSession 自带 redirect；
        // 上面的 followRedirects = false 同时关闭 Ktor 层。没有 Retry / ContentNegotiation 插件。
        //
        // 这里只做 session 级配置；不再用 configureRequest 设置 Accept-Encoding / cachePolicy：
        // 该 lambda 的 receiver 是平台类型 NSMutableURLRequest，但 setValue:forHTTPHeaderField: 与
        // Kotlin 的 KMutableProperty.setValue 扩展重载同名，cachePolicy 又是只读属性，写不出可编译的调用。
        // 请求级 Cache-Control 由调用方在 headers 里显式给出（TxnPolicy 白名单允许 content-type/accept）。
        configureSession {
            HTTPShouldSetCookies = false
            HTTPCookieStorage = null
            URLCache = null
            requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData
        }
    }
}
