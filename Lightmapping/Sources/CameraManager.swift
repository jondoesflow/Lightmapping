import AVFoundation
import Metal
import Vision

/// Shared camera session. Feeds live camera content and, when enabled, hand and face
/// tracking used as modulation sources.
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = CameraManager()

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.capture")
    private let visionQueue = DispatchQueue(label: "camera.vision")
    private let lock = NSLock()

    private var cache: CVMetalTextureCache?
    private var latest: CVMetalTexture?
    private var position: CameraPosition = .back
    private var configured = false
    private var lastRequested = Date.distantPast
    private var frameCount = 0
    private var visionBusy = false

    private var _tracking = TrackingValues()
    var trackingEnabled = false {
        didSet { if trackingEnabled { ensureRunning(position) } }
    }

    var tracking: TrackingValues {
        lock.lock(); defer { lock.unlock() }
        return _tracking
    }

    func texture(for position: CameraPosition, device: MTLDevice) -> MTLTexture? {
        lastRequested = Date()
        if cache == nil { CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) }
        ensureRunning(position)
        lock.lock(); defer { lock.unlock() }
        return latest.flatMap(CVMetalTextureGetTexture)
    }

    private func ensureRunning(_ position: CameraPosition) {
        queue.async { [self] in
            if !configured || position != self.position {
                configure(position)
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Stops the camera when neither content nor tracking has used it for a while.
    func stopIfIdle() {
        guard !trackingEnabled, Date().timeIntervalSince(lastRequested) > 3 else { return }
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    private func configure(_ position: CameraPosition) {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = .hd1280x720
        let pos: AVCaptureDevice.Position = position == .front ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
        else { session.commitConfiguration(); return }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let conn = output.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(0) { conn.videoRotationAngle = 0 }
            conn.isVideoMirrored = position == .front
        }
        session.commitConfiguration()
        self.position = position
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if let cache, let tex = makeMetalTexture(pb, cache: cache) {
            lock.lock(); latest = tex; lock.unlock()
        }
        frameCount += 1
        if trackingEnabled && frameCount % 3 == 0 && !visionBusy {
            visionBusy = true
            visionQueue.async { [self] in
                runVision(pb)
                visionBusy = false
            }
        }
    }

    private func runVision(_ pb: CVPixelBuffer) {
        let hands = VNDetectHumanHandPoseRequest()
        hands.maximumHandCount = 1
        let faces = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up)
        try? handler.perform([hands, faces])

        var t = tracking
        if let hand = hands.results?.first,
           let index = try? hand.recognizedPoint(.indexTip), let thumb = try? hand.recognizedPoint(.thumbTip),
           index.confidence > 0.3, thumb.confidence > 0.3 {
            // Vision is y-up; modulation values are y-down to match the canvas.
            t.handX = smooth(t.handX, Float(index.location.x))
            t.handY = smooth(t.handY, Float(1 - index.location.y))
            let d = hypot(index.location.x - thumb.location.x, index.location.y - thumb.location.y)
            t.pinch = smooth(t.pinch, Float(max(0, min(1, 1 - (d - 0.02) / 0.15))))
        }
        if let face = faces.results?.first {
            let box = face.boundingBox
            t.faceX = smooth(t.faceX, Float(box.midX))
            t.faceY = smooth(t.faceY, Float(1 - box.midY))
            if let inner = face.landmarks?.innerLips?.normalizedPoints, !inner.isEmpty {
                let ys = inner.map(\.y)
                let open = (ys.max()! - ys.min()!) // relative to face box height
                t.mouthOpen = smooth(t.mouthOpen, Float(max(0, min(1, (open - 0.02) / 0.15))))
            }
        }
        lock.lock(); _tracking = t; lock.unlock()
    }

    private func smooth(_ old: Float, _ new: Float) -> Float { old + (new - old) * 0.5 }
}
