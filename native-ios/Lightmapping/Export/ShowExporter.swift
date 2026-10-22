import AVFoundation
import CoreVideo
import Metal
import Photos

enum ExportResolution: String, CaseIterable, Identifiable {
    case hd720 = "720p", hd1080 = "1080p", uhd4K = "4K"
    var id: String { rawValue }

    func size(aspect: Float) -> SIMD2<Int> {
        let h: Int
        switch self {
        case .hd720: h = 720
        case .hd1080: h = 1080
        case .uhd4K: h = 2160
        }
        // Even dimensions are required by the encoders.
        let w = Int((Float(h) * aspect / 2).rounded()) * 2
        return SIMD2(w, h)
    }
}

struct ExportOptions {
    var resolution: ExportResolution = .hd1080
    var fps: Int = 30
    /// Used when the timeline is empty: exports the active scene for this long.
    var fallbackDuration: Double = 30
    var includeAudio = true
}

/// Renders a project offline, frame by frame, into a movie. Every modulation source is
/// derived from the timeline and the pre-analysed audio track, so exports are repeatable.
final class ShowExporter {
    enum ExportError: LocalizedError {
        case metal, writer(String)
        var errorDescription: String? {
            switch self {
            case .metal: return "Metal isn't available."
            case .writer(let s): return "Couldn't write the video: \(s)"
            }
        }
    }

    private var cancelled = false
    func cancel() { cancelled = true }

    func export(_ project: Project, options: ExportOptions, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let renderer = Renderer() else { throw ExportError.metal }
        let sources = SourceManager(device: renderer.device, mode: .offline)
        renderer.sources = sources
        let size = options.resolution.size(aspect: project.outputAspect)
        renderer.setOutputSize(size)

        var timeline = project.timeline
        timeline.sortClips()
        let duration = timeline.clips.isEmpty ? options.fallbackDuration : timeline.duration

        let audioURL = timeline.audioAssetID.flatMap { ProjectStore.shared.assetURL($0) }
        let analysis = audioURL.flatMap { try? AudioAnalysis.analyze(url: $0, fps: Double(options.fps)) }

        let videoURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        let codec: AVVideoCodecType = options.resolution == .uhd4K ? .hevc : .h264
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: size.x,
            AVVideoHeightKey: size.y,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: size.x * size.y * options.fps / 6],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.x,
            kCVPixelBufferHeightKey as String: size.y,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        guard writer.canAdd(input) else { throw ExportError.writer("input rejected") }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "start failed") }
        writer.startSession(atSourceTime: .zero)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, renderer.device, nil, &cache)
        guard let cache, let pool = adaptor.pixelBufferPool else { throw ExportError.writer("no pixel buffer pool") }

        let fps = Double(options.fps)
        let frameCount = Int(duration * fps)
        var lastOnset: Double?
        for f in 0..<frameCount {
            if cancelled { writer.cancelWriting(); throw CancellationError() }
            let t = Double(f) / fps
            var ctx = context(project: project, timeline: timeline, time: t)
            if let analysis {
                ctx.audio = analysis.bands(at: t)
                if ctx.audio.onset { lastOnset = t }
            }
            ctx.envelope = envelopes(project, ctx: ctx, lastOnset: lastOnset)
            let state = frameState(project: project, timeline: timeline, time: t, ctx: ctx)

            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { throw ExportError.writer("pixel buffer allocation failed") }
            var cvTex: CVMetalTexture?
            let attrs = [kCVMetalTextureUsage: MTLTextureUsage([.renderTarget, .shaderRead]).rawValue] as CFDictionary
            CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, attrs, .bgra8Unorm, size.x, size.y, 0, &cvTex)
            guard let cvTex, let target = CVMetalTextureGetTexture(cvTex),
                  let cb = renderer.queue.makeCommandBuffer() else { throw ExportError.metal }
            renderer.encodeFrame(state, into: cb, target: target)
            cb.commit()
            cb.waitUntilCompleted()

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(options.fps)))
            if f % 10 == 0 { progress(Double(f) / Double(max(frameCount, 1)) * 0.9) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "unknown") }

        let finalURL = ProjectStore.shared.exportsDir.appendingPathComponent(
            "\(project.name.replacingOccurrences(of: "/", with: "-")) \(options.resolution.rawValue) \(Int(Date().timeIntervalSince1970)).mov")
        if options.includeAudio, let audioURL {
            try await mux(video: videoURL, audio: audioURL, duration: duration, to: finalURL)
            try? FileManager.default.removeItem(at: videoURL)
        } else {
            try FileManager.default.moveItem(at: videoURL, to: finalURL)
        }
        progress(1)
        return finalURL
    }

    // MARK: Deterministic modulation

    private func context(project: Project, timeline: Timeline, time t: Double) -> ModulationContext {
        var ctx = ModulationContext()
        ctx.time = t
        ctx.beat = t * project.bpm / 60
        ctx.lfo = project.lfos.map { $0.value(beat: ctx.beat) }
        ctx.macros = project.macros
        for lane in timeline.automation {
            if let v = lane.value(at: t), ctx.macros.indices.contains(lane.macroIndex) { ctx.macros[lane.macroIndex] = v }
        }
        return ctx
    }

    private func envelopes(_ project: Project, ctx: ModulationContext, lastOnset: Double?) -> [Float] {
        let secondsPerBeat = 60 / project.bpm
        return project.envelopes.map { env in
            let since: Double?
            switch env.trigger {
            case .beat: since = (ctx.beat - floor(ctx.beat)) * secondsPerBeat
            case .bar: since = (ctx.beat / 4 - floor(ctx.beat / 4)) * secondsPerBeat * 4
            case .audioOnset: since = lastOnset.map { ctx.time - $0 }
            case .midiNote, .manual: since = nil
            }
            return env.value(sinceTrigger: since)
        }
    }

    private func frameState(project: Project, timeline: Timeline, time t: Double, ctx: ModulationContext) -> FrameState {
        let sceneByID = Dictionary(uniqueKeysWithValues: project.scenes.map { ($0.id, $0) })
        let fallback = project.activeScene ?? MapScene(name: "Empty")
        guard let clip = timeline.clip(at: t), let scene = sceneByID[clip.sceneID] else {
            return FrameState(project: project, scene: fallback, ctx: ctx)
        }
        var state = FrameState(project: project, scene: scene, ctx: ctx)
        // Transition in from the previous clip's scene at the start of each clip.
        let tr = project.transition
        if tr.style != .cut, t - clip.start < tr.duration,
           let i = timeline.clips.firstIndex(where: { $0.id == clip.id }), i > 0,
           let prev = sceneByID[timeline.clips[i - 1].sceneID], prev.id != scene.id {
            state.scene = prev
            state.incoming = (scene, Float((t - clip.start) / tr.duration), tr.style)
        }
        return state
    }

    // MARK: Audio

    private func mux(video: URL, audio: URL, duration: Double, to output: URL) async throws {
        let comp = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        guard let vSrc = try await videoAsset.loadTracks(withMediaType: .video).first,
              let vDst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError.writer("missing video track") }
        try vDst.insertTimeRange(range, of: vSrc, at: .zero)
        if let aSrc = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let aDst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try await audioAsset.load(.duration)
            // Loop the track if the show is longer than the song.
            var cursor = CMTime.zero
            while cursor < range.duration {
                let remaining = range.duration - cursor
                let chunk = CMTimeMinimum(remaining, audioDuration)
                try aDst.insertTimeRange(CMTimeRange(start: .zero, duration: chunk), of: aSrc, at: cursor)
                cursor = cursor + chunk
            }
        }
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.writer("export session unavailable")
        }
        session.outputURL = output
        session.outputFileType = .mov
        await session.export()
        if session.status != .completed { throw ExportError.writer(session.error?.localizedDescription ?? "mux failed") }
    }

    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CocoaError(.userCancelled) }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
