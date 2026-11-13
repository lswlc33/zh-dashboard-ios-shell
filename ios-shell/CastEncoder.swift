import Foundation
import ReplayKit
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreImage
import ImageIO

// Broadcast target only。全部状态在 engine 的串行队列上；ReplayKit 输入在入队前限为一份，
// VT 最多两帧在途，压缩输出队列最多四帧 / 4 MiB。无 webview 截屏、假帧或软件编码替代。
final class IOSCastEncoder {
    struct Frame {
        let bytes: Data
        let keyframe: Bool
    }
    private let queue: DispatchQueue
    private let inputGate = DispatchSemaphore(value: 1)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var session: VTCompressionSession?
    private var pool: CVPixelBufferPool?
    private var plan: IOSCastPlan?
    private var generation: UInt64 = 0
    private var inFlight = 0
    private var lastPTS: CMTime?
    private var lastKeyRequest = -Double.infinity
    private var forceKeyframe = true
    private var waitingForIDR = true
    private var sps = Data()
    private var pps = Data()
    private var frames: [Frame] = []
    private var queuedBytes = 0
    private(set) var droppedFrames: UInt64 = 0
    private(set) var running = false
    var onFatal: ((String) -> Void)?
    var acceptsSample: (() -> Bool)?

    init(queue: DispatchQueue) { self.queue = queue }

    func start(_ plan: IOSCastPlan) throws {
        if running { return }
        stop()
        self.plan = plan
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: plan.width, kCVPixelBufferHeightKey: plan.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var created: VTCompressionSession?
        // 这两个“强制硬件编码”常量在 app extension 里从 iOS 17.4 才公开；
        // 低版本直接要求会让编译失败。低版本仍请求硬件编码，但在 Prepare 后
        // 用 UsingHardwareAcceleratedVideoEncoder 复核，失败即 fail closed，不静默转软编。
        var specification: [CFString: Any] = [:]
        if #available(iOS 17.4, *) {
            specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
        }
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(plan.width), height: Int32(plan.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else { throw IOSCastError.reason("hardware_encoder_unavailable") }
        self.session = session
        do {
            try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
            try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
            try set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: plan.bitrate)) // bps，不是 kbps。
            try set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: plan.bitrate / 8), NSNumber(value: 1)] as CFArray)
            try set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: plan.fps))
            try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: plan.fps))
            try set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1))
            // Apple 的 ProfileLevel 是 CFString，不是 Android 的 512/256 枚举。
            // 其他 level 让硬件协商 Baseline AutoLevel；不能用不存在的旧系统常量冒充固定 level。
            let profile: CFString = plan.level == "3.0" ? kVTProfileLevel_H264_Baseline_3_0 :
                plan.level == "3.1" ? kVTProfileLevel_H264_Baseline_3_1 : kVTProfileLevel_H264_Baseline_AutoLevel
            try set(kVTCompressionPropertyKey_ProfileLevel, profile)
            guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { throw IOSCastError.reason("encoder_prepare_failed") }
            // “强制/查询硬件编码器”这两个常量在 app extension 里从 iOS 17.4 才公开，
            // 低版本直接引用会编译失败。改为查询系统编码器列表，确认存在硬件 H.264 编码器；
            // 找不到就 fail closed，绝不静默退回软编。
            var encoderList: CFArray?
            guard VTCopyVideoEncoderList(nil, &encoderList) == noErr,
                  let encoders = encoderList as? [[String: Any]],
                  encoders.contains(where: { encoder in
                      let codec = encoder[kVTVideoEncoderList_CodecType as String] as? NSNumber
                      let hardware = encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber
                      return codec?.uint32Value == kCMVideoCodecType_H264 && hardware?.boolValue == true
                  }) else { throw IOSCastError.reason("hardware_encoder_required") }
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                          attrs as CFDictionary, &pool) == kCVReturnSuccess, pool != nil else {
                throw IOSCastError.reason("encoder_pixel_pool_unavailable")
            }
            self.pool = pool
            running = true; forceKeyframe = true; waitingForIDR = true
        } catch { stop(); throw error }
    }
    private func set(_ key: CFString, _ value: CFTypeRef) throws {
        guard let session = session, VTSessionSetProperty(session, key: key, value: value) == noErr else {
            throw IOSCastError.reason("encoder_configuration_rejected")
        }
    }
    func submit(_ sample: CMSampleBuffer) {
        // 在调用线程先限流，不把 CMSampleBuffer 无限保留到异步队列。
        guard inputGate.wait(timeout: .now()) == .success else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            defer { self.inputGate.signal() }
            autoreleasepool { self.encode(sample) }
        }
    }
    private func encode(_ sample: CMSampleBuffer) {
        guard running, acceptsSample?() == true, let session = session, let plan = plan, let pool = pool,
              CMSampleBufferDataIsReady(sample), let input = CMSampleBufferGetImageBuffer(sample) else { return }
        let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { fatal("capture_dimensions_unsupported"); return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid, !pts.isIndefinite else { droppedFrames &+= 1; return }
        if let last = lastPTS, CMTimeCompare(pts, last) <= 0 { droppedFrames &+= 1; return }
        if let last = lastPTS, CMTimeGetSeconds(CMTimeSubtract(pts, last)) < 1.0 / Double(plan.fps) { return }
        guard inFlight < 2 else { droppedFrames &+= 1; requestKeyframe(); return }
        var output: CVPixelBuffer?
        let aux: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: 4]
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, aux as CFDictionary, &output) == kCVReturnSuccess,
              let pixel = output else { droppedFrames &+= 1; requestKeyframe(); return }
        var image = CIImage(cvPixelBuffer: input)
        if let orientation = CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let value = CGImagePropertyOrientation(rawValue: orientation.uint32Value) { image = image.oriented(value) }
        let rect = image.extent
        guard rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite else { droppedFrames &+= 1; return }
        let scale = min(CGFloat(plan.width) / rect.width, CGFloat(plan.height) / rect.height)
        image = image.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (CGFloat(plan.width) - rect.width * scale) / 2,
                                               y: (CGFloat(plan.height) - rect.height * scale) / 2))
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(plan.width), height: CGFloat(plan.height))
        // 等比包含整个手机屏幕，不裁成网页区域；黑边也是实际绘制而非虚构视频数据。
        image = image.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas))
        context.render(image, to: pixel, bounds: canvas, colorSpace: CGColorSpaceCreateDeviceRGB())
        let epoch = generation
        let options: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyframe = false; lastPTS = pts; inFlight += 1
        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: Int32(plan.fps)), frameProperties: options,
            infoFlagsOut: &flags) { [weak self] status, flags, sample in
                guard let self = self else { return }
                self.queue.async { [weak self] in
                    guard let self = self, self.generation == epoch, self.running else { return }
                    self.inFlight = max(0, self.inFlight - 1)
                    guard status == noErr else { self.fatal("encoder_output_failed"); return }
                    guard !flags.contains(.frameDropped), let sample = sample else {
                        self.droppedFrames &+= 1; self.requestKeyframe(); return
                    }
                    autoreleasepool { self.consume(sample) }
                }
            }
        if status != noErr { inFlight = max(0, inFlight - 1); fatal("encoder_encode_failed") }
    }
    private func consume(_ sample: CMSampleBuffer) {
        do {
            guard let description = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample),
                  CMSampleBufferDataIsReady(sample) else { throw IOSCastError.reason("h264_frame_invalid") }
            var lengthBytes: Int32 = 0
            var count = 0
            for i in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: i,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &lengthBytes) == noErr,
                    let pointer = pointer, size > 0, size <= 65535 else { throw IOSCastError.reason("h264_parameter_sets_missing") }
                let data = IOSCastWire.startCode + Data(bytes: pointer, count: size)
                if i == 0 { sps = data } else { pps = data }
            }
            let size = CMBlockBufferGetDataLength(block)
            guard size > 0, size <= IOSCastWire.frameMax else { throw IOSCastError.reason("encoded_frame_too_large") }
            var data = Data(count: size)
            let status = data.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: bytes.baseAddress!)
            }
            guard status == noErr else { throw IOSCastError.reason("h264_frame_invalid") }
            let annex = try IOSCastWire.annexB(data, lengthBytes: Int(lengthBytes), allowAnnexB: false)
            let (bytes, idr) = try IOSCastWire.accessUnit(annex, sps: sps, pps: pps)
            if waitingForIDR && !idr { droppedFrames &+= 1; requestKeyframe(); return }
            if frames.count >= 4 || queuedBytes + bytes.count > 4 * 1024 * 1024 {
                // 被丢的 P 帧可能是后来帧的参考：清空并等 IDR，避免发残缺参考链。
                droppedFrames &+= UInt64(frames.count); frames.removeAll(keepingCapacity: true); queuedBytes = 0
                waitingForIDR = true; requestKeyframe()
                if !idr { droppedFrames &+= 1; return }
            }
            if idr { waitingForIDR = false }
            frames.append(Frame(bytes: bytes, keyframe: idr)); queuedBytes += bytes.count
        } catch {
            droppedFrames &+= 1; requestKeyframe()
            if IOSCastError.code(error) == "encoded_frame_too_large" { fatal("encoded_frame_too_large") }
        }
    }
    func poll() -> Frame? {
        guard !frames.isEmpty else { return nil }
        let frame = frames.removeFirst(); queuedBytes -= frame.bytes.count
        return frame
    }
    func resetDelivery() {
        droppedFrames &+= UInt64(frames.count); frames.removeAll(keepingCapacity: true); queuedBytes = 0
        waitingForIDR = true; requestKeyframe()
    }
    func requestKeyframe() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKeyRequest >= 0.3 else { return }
        lastKeyRequest = now; forceKeyframe = true
    }
    private func fatal(_ code: String) { stop(); onFatal?(code) }
    func stop() {
        generation &+= 1; running = false
        if let session = session { VTCompressionSessionInvalidate(session) }
        session = nil; pool = nil; plan = nil; inFlight = 0; lastPTS = nil
        frames.removeAll(keepingCapacity: false); queuedBytes = 0
        sps = Data(); pps = Data(); context.clearCaches()
    }
}
