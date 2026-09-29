import AVFoundation
import Combine
import Foundation

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var isRunning = false
    @Published private(set) var cameraName = "未连接"

    var frameHandler: ((CMSampleBuffer, TimeInterval) -> Void)?
    var errorHandler: ((String) -> Void)?

    private let sessionQueue = DispatchQueue(label: "gesture.camera.session")
    /// AVCapture delegate 只做极轻量的收帧，不在这里同步跑 Vision。
    private let videoQueue = DispatchQueue(label: "gesture.camera.frames", qos: .userInitiated)
    /// V1.1: Vision 单独串行执行，避免慢推理阻塞 AVCapture delegate。
    private let visionQueue = DispatchQueue(label: "gesture.camera.vision", qos: .userInitiated)
    private let visionStateLock = NSLock()
    private let output = AVCaptureVideoDataOutput()
    private var configured = false
    private var acceptingFrames = false
    private var processingGeneration: UInt64 = 0
    private var visionProcessing = false
    private var pendingLatestFrame: (
        buffer: CMSampleBuffer,
        capturedAt: TimeInterval,
        generation: UInt64
    )?
    // V1.2: do not add a second software frame-rate gate here. The camera is already configured
    // near 30 FPS and latest-frame-wins provides backpressure. A 1/30 wall-clock guard can
    // accidentally turn a 29.97~30 FPS source into ~15 FPS when frame timing is slightly early.

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.configured {
                    try self.configureSession()
                    self.configured = true
                }
                guard !self.session.isRunning else { return }

                self.visionStateLock.lock()
                self.processingGeneration &+= 1
                self.acceptingFrames = true
                self.pendingLatestFrame = nil
                self.visionStateLock.unlock()

                self.session.startRunning()
                DispatchQueue.main.async {
                    self.isRunning = true
                }
            } catch {
                self.visionStateLock.lock()
                self.acceptingFrames = false
                self.pendingLatestFrame = nil
                self.visionStateLock.unlock()
                DispatchQueue.main.async {
                    self.errorHandler?(error.localizedDescription)
                    self.isRunning = false
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            // Close the mailbox before stopping the capture session. AVCapture can still deliver a
            // callback already queued on videoQueue; the generation check below makes that frame a no-op.
            self.visionStateLock.lock()
            self.acceptingFrames = false
            self.processingGeneration &+= 1
            self.pendingLatestFrame = nil
            self.visionStateLock.unlock()

            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }

        guard let camera = AVCaptureDevice.default(for: .video) else {
            throw CameraError.noCamera
        }

        // V1.2 realtime capture：若设备支持 60FPS，优先让采集层提供更“新”的帧。
        // Vision 仍由 latest-frame-wins 控制实际推理吞吐，因此这不会强迫 Vision 跑到 60FPS；
        // 但当一次推理结束时，mailbox 中等待的是最多约 16ms 前的新帧，而不是约 33ms 前的帧。
        let preferredFPS: Int32 = camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= 60 && $0.maxFrameRate >= 60
        }) ? 60 : 30
        if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= Double(preferredFPS) && $0.maxFrameRate >= Double(preferredFPS)
        }) {
            do {
                try camera.lockForConfiguration()
                let frameDuration = CMTime(value: 1, timescale: preferredFPS)
                camera.activeVideoMinFrameDuration = frameDuration
                camera.activeVideoMaxFrameDuration = frameDuration
                camera.unlockForConfiguration()
            } catch {
                // 帧率配置失败不影响摄像头使用，继续按系统默认值运行。
            }
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        // Vision 可以直接消费双平面 YUV。优先使用摄像头更接近原生的 420f，避免强制 BGRA
        // 色彩转换占用 CPU/内存带宽；不支持时再回退 BGRA。
        let preferredPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let pixelFormat = output.availableVideoPixelFormatTypes.contains(preferredPixelFormat)
            ? preferredPixelFormat
            : kCVPixelFormatType_32BGRA
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(output) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            // Vision 侧使用 .upMirrored 做方向转换，这里保持原始帧。
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = false
            }
        }

        DispatchQueue.main.async {
            self.cameraName = camera.localizedName
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Feed every capture frame into the latest-frame mailbox. If Vision is busy, the mailbox
        // replaces the pending frame instead of queueing stale work. Capture arrival time travels with
        // the frame so motion dt and latency compensation refer to the actual input frame, not the
        // later moment at which the Vision queue happens to begin processing it.
        enqueueLatestForVision(sampleBuffer, capturedAt: ProcessInfo.processInfo.systemUptime)
    }

    /// V1.1/V1.2 latest-frame-wins：Vision 忙时不积压旧帧，只保留最新帧。
    private func enqueueLatestForVision(_ sampleBuffer: CMSampleBuffer, capturedAt: TimeInterval) {
        visionStateLock.lock()
        guard acceptingFrames else {
            visionStateLock.unlock()
            return
        }
        let generation = processingGeneration
        if visionProcessing {
            pendingLatestFrame = (sampleBuffer, capturedAt, generation)
            visionStateLock.unlock()
            return
        }
        visionProcessing = true
        visionStateLock.unlock()

        visionQueue.async { [weak self] in
            self?.drainVision(startingWith: (sampleBuffer, capturedAt, generation))
        }
    }

    private func drainVision(
        startingWith firstFrame: (
            buffer: CMSampleBuffer,
            capturedAt: TimeInterval,
            generation: UInt64
        )
    ) {
        var current: (
            buffer: CMSampleBuffer,
            capturedAt: TimeInterval,
            generation: UInt64
        )? = firstFrame

        while let frame = current {
            visionStateLock.lock()
            let shouldProcess = acceptingFrames && frame.generation == processingGeneration
            visionStateLock.unlock()

            if shouldProcess {
                // The drain loop may live for minutes under a steady camera stream. Give each Vision
                // frame its own autorelease pool so temporary objects are reclaimed every frame.
                autoreleasepool {
                    frameHandler?(frame.buffer, frame.capturedAt)
                }
            }

            visionStateLock.lock()
            if acceptingFrames,
               let latest = pendingLatestFrame,
               latest.generation == processingGeneration {
                pendingLatestFrame = nil
                current = latest
                visionStateLock.unlock()
            } else {
                pendingLatestFrame = nil
                current = nil
                visionProcessing = false
                visionStateLock.unlock()
            }
        }
    }
}

private enum CameraError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCamera: return "没有找到可用摄像头。"
        case .cannotAddInput: return "无法将摄像头加入采集会话。"
        case .cannotAddOutput: return "无法创建摄像头视频输出。"
        }
    }
}
