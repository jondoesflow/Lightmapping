import AVFoundation
import CoreVideo
import Metal
import MetalKit

/// Supplies textures for imported media, the camera and hand drawings.
/// `live` mode plays video in real time; `offline` mode (export) decodes frames
/// deterministically for the requested timestamp.
final class SourceManager: SourceTextureProvider {
    enum Mode { case live, offline }

    let device: MTLDevice
    let mode: Mode
    private let loader: MTKTextureLoader
    private var textureCache: CVMetalTextureCache?

    private var photos: [UUID: MTLTexture] = [:]
    private var livePlayers: [UUID: LiveVideoSource] = [:]
    private var offlineReaders: [UUID: OfflineVideoReader] = [:]
    private var drawings: [UUID: DrawingRenderer] = [:]
    private var lastUsed: [UUID: Date] = [:]

    init(device: MTLDevice, mode: Mode) {
        self.device = device
        self.mode = mode
        self.loader = MTKTextureLoader(device: device)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    func texture(for source: ContentSource, layerID: UUID, ctx: ModulationContext) -> MTLTexture? {
        lastUsed[layerID] = Date()
        switch source {
        case .generator:
            return nil
        case .photo(let id):
            if let t = photos[id] { return t }
            guard let url = ProjectStore.shared.assetURL(id),
                  let t = try? loader.newTexture(URL: url, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
            else { return nil }
            photos[id] = t
            return t
        case .video(let id):
            guard let cache = textureCache else { return nil }
            switch mode {
            case .live:
                if livePlayers[layerID] == nil, let url = ProjectStore.shared.assetURL(id) {
                    livePlayers[layerID] = LiveVideoSource(url: url, cache: cache)
                }
                return livePlayers[layerID]?.currentTexture()
            case .offline:
                if offlineReaders[layerID] == nil, let url = ProjectStore.shared.assetURL(id) {
                    offlineReaders[layerID] = OfflineVideoReader(url: url, cache: cache)
                }
                return offlineReaders[layerID]?.texture(at: ctx.time)
            }
        case .camera(let position):
            return CameraManager.shared.texture(for: position, device: device)
        case .drawing(let drawing):
            let r = drawings[layerID] ?? DrawingRenderer(device: device)
            drawings[layerID] = r
            return r.render(drawing, time: ctx.time)
        }
    }

    /// Stop players for layers that are no longer on screen.
    func purge(olderThan seconds: TimeInterval = 5) {
        let cutoff = Date().addingTimeInterval(-seconds)
        for (id, date) in lastUsed where date < cutoff {
            livePlayers[id]?.stop()
            livePlayers[id] = nil
            offlineReaders[id] = nil
            drawings[id] = nil
            lastUsed[id] = nil
        }
    }

    /// Restart live videos from the top (used when a show starts playing).
    func restartVideos() {
        livePlayers.values.forEach { $0.restart() }
    }
}

// MARK: - Live video

final class LiveVideoSource {
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let cache: CVMetalTextureCache
    private var current: CVMetalTexture?
    private var loopObserver: NSObjectProtocol?

    init(url: URL, cache: CVMetalTextureCache) {
        self.cache = cache
        let item = AVPlayerItem(url: url)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        player.play()
    }

    deinit {
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }

    func currentTexture() -> MTLTexture? {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time),
           let pb = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            current = makeMetalTexture(pb, cache: cache)
        }
        return current.flatMap(CVMetalTextureGetTexture)
    }

    func restart() { player.seek(to: .zero); player.play() }
    func stop() { player.pause() }
}

// MARK: - Offline video (export)

/// Sequential frame reader that loops the clip. Exports advance time monotonically,
/// so frames are read forward and the reader is rebuilt only when the clip wraps.
final class OfflineVideoReader {
    private let asset: AVURLAsset
    private let cache: CVMetalTextureCache
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var duration: Double = 0
    private var lastLocalTime: Double = .infinity
    private var current: CVMetalTexture?
    private var pending: CMSampleBuffer?

    init(url: URL, cache: CVMetalTextureCache) {
        asset = AVURLAsset(url: url)
        self.cache = cache
        duration = asset.duration.seconds
    }

    func texture(at time: Double) -> MTLTexture? {
        guard duration > 0 else { return nil }
        let local = time.truncatingRemainder(dividingBy: duration)
        if local < lastLocalTime { restart() }
        lastLocalTime = local

        while true {
            let sample = pending ?? output?.copyNextSampleBuffer()
            pending = nil
            guard let sample else { break }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if pts > local + 1e-3 {
                pending = sample // keep for a later frame
                if current == nil, let pb = CMSampleBufferGetImageBuffer(sample) { current = makeMetalTexture(pb, cache: cache) }
                break
            }
            if let pb = CMSampleBufferGetImageBuffer(sample) { current = makeMetalTexture(pb, cache: cache) }
        }
        return current.flatMap(CVMetalTextureGetTexture)
    }

    private func restart() {
        reader?.cancelReading()
        pending = nil
        guard let track = asset.tracks(withMediaType: .video).first, let r = try? AVAssetReader(asset: asset) else { return }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        o.alwaysCopiesSampleData = false
        r.add(o)
        r.startReading()
        reader = r
        output = o
    }
}

func makeMetalTexture(_ pb: CVPixelBuffer, cache: CVMetalTextureCache) -> CVMetalTexture? {
    var tex: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm,
                                              CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &tex)
    return tex
}
