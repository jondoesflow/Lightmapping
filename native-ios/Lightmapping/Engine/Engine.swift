import AVFoundation
import Combine
import MetalKit
import QuartzCore
import SwiftUI

/// Live meter values for the UI, published at a low rate so SwiftUI isn't redrawn at 60 fps.
final class Meters: ObservableObject {
    @Published var audio = AudioBands()
    @Published var lfo: [Float] = []
    @Published var envelope: [Float] = []
    @Published var tracking = TrackingValues()
    @Published var beat: Double = 0
}

/// Owns the project, the render loop and every live input. Views mutate the project
/// through the helpers here so saving, scene switching and timeline playback stay consistent.
@MainActor
final class Engine: ObservableObject {
    @Published var project: Project { didSet { scheduleSave() } }
    @Published var selectedSurfaceID: UUID?
    @Published var showOutlines = true
    @Published var audioInputEnabled = false { didSet { audioInputEnabled ? mic.start() : mic.stop() } }
    @Published var trackingEnabled = false { didSet { CameraManager.shared.trackingEnabled = trackingEnabled } }
    @Published var midiNotesSwitchScenes = true
    @Published private(set) var transitionTargetID: UUID?
    @Published private(set) var isTimelinePlaying = false
    @Published private(set) var timelinePosition: Double = 0
    @Published private(set) var externalDisplayConnected = false
    @Published var midiLearnActive = false

    let meters = Meters()
    let renderer: Renderer
    let sources: SourceManager
    let midi = MIDIManager()
    let mic = LiveAudioInput()

    private var displayLink: CADisplayLink?
    private let views = NSHashTable<MTKView>.weakObjects()
    private let inFlight = DispatchSemaphore(value: 3)
    private let clockStart = CACurrentMediaTime()
    private var beatOrigin: Double = 0
    private var lastBeat: Double = 0
    private var envelopeTriggers: [Double?] = []
    private var transition: (from: UUID, to: UUID, start: Double, style: TransitionStyle, duration: Double)?
    private var tapTimes: [Double] = []
    private var frameCount = 0
    private var saveTask: Task<Void, Never>?
    private var midiLearnCallback: ((ModSource) -> Void)?

    // Timeline playback
    private var audioPlayer: AVAudioPlayer?
    private var trackAnalysis: (id: UUID, analysis: AudioAnalysis)?
    private var timelineStart: Double = 0
    private var lastTimelineClipID: UUID?

    init(project: Project) {
        guard let renderer = Renderer() else { fatalError("Metal is required") }
        self.renderer = renderer
        self.project = project
        self.sources = SourceManager(device: renderer.device, mode: .live)
        renderer.sources = sources
        envelopeTriggers = Array(repeating: nil, count: project.envelopes.count)
        let link = CADisplayLink(target: DisplayLinkTarget(engine: self), selector: #selector(DisplayLinkTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    var now: Double { CACurrentMediaTime() - clockStart }

    // MARK: Views & output

    func attach(_ view: MTKView) {
        view.device = renderer.device
        view.colorPixelFormat = renderer.pixelFormat
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        views.add(view)
    }

    func detach(_ view: MTKView) { views.remove(view) }

    func setExternalDisplay(size: CGSize?) {
        externalDisplayConnected = size != nil
        let s = size ?? CGSize(width: 1920, height: 1080)
        renderer.setOutputSize(SIMD2(Int(s.width), Int(s.height)))
        project.outputAspect = Float(s.width / max(s.height, 1))
    }

    // MARK: Render loop

    fileprivate func tick() {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        frameCount += 1
        let t = now
        var ctx = makeContext(time: t)
        processTimeline(t, ctx: &ctx)
        processTriggers(t, ctx: &ctx)
        ctx.envelope = project.envelopes.enumerated().map { i, env in
            env.value(sinceTrigger: envelopeTriggers.indices.contains(i) ? envelopeTriggers[i].map { t - $0 } : nil)
        }

        let state = frameState(ctx: ctx, time: t)
        guard let cb = renderer.queue.makeCommandBuffer() else { inFlight.signal(); return }
        renderer.encodeFrame(state, into: cb)
        for view in views.allObjects where view.window != nil {
            renderer.present(renderer.outputTexture, to: view, commandBuffer: cb)
        }
        let sem = inFlight
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()

        if frameCount % 4 == 0 { publishMeters(ctx) }
        if frameCount % 120 == 0 {
            sources.purge()
            CameraManager.shared.stopIfIdle()
        }
        if midiLearnActive, let learned = midi.takeLastCC() {
            midiLearnCallback?(.midiCC(channel: learned.channel, cc: learned.cc))
            midiLearnActive = false
            midiLearnCallback = nil
        }
    }

    func makeContext(time t: Double) -> ModulationContext {
        var ctx = ModulationContext()
        ctx.time = t
        ctx.beat = (t - beatOrigin) * project.bpm / 60
        ctx.lfo = project.lfos.map { $0.value(beat: ctx.beat) }
        ctx.macros = project.macros
        ctx.midiCC = midi.cc
        ctx.tracking = trackingEnabled ? CameraManager.shared.tracking : TrackingValues()
        if isTimelinePlaying, let a = trackAnalysis?.analysis {
            ctx.audio = a.bands(at: timelinePosition)
        } else if audioInputEnabled {
            ctx.audio = mic.read()
        }
        return ctx
    }

    private func frameState(ctx: ModulationContext, time t: Double) -> FrameState {
        let current = project.activeScene ?? MapScene(name: "Empty")
        var state = FrameState(project: project, scene: current, ctx: ctx,
                               showOutlines: showOutlines, selectedSurfaceID: selectedSurfaceID)
        if let tr = transition,
           let from = project.scenes.first(where: { $0.id == tr.from }),
           let to = project.scenes.first(where: { $0.id == tr.to }) {
            let p = Float(min(1, (t - tr.start) / max(tr.duration, 0.001)))
            state.scene = from
            state.incoming = (to, p, tr.style)
            if p >= 1 {
                transition = nil
                transitionTargetID = nil
                project.activeSceneID = tr.to
            }
        }
        return state
    }

    private func processTriggers(_ t: Double, ctx: inout ModulationContext) {
        let beatIndex = floor(ctx.beat)
        let newBeat = beatIndex != floor(lastBeat)
        let newBar = newBeat && Int(beatIndex) % 4 == 0
        lastBeat = ctx.beat

        let notes = midi.drainNotes()
        if midiNotesSwitchScenes {
            // Pads from C1 (36) upward select scenes in order.
            for n in notes where n.note >= 36 {
                let i = n.note - 36
                if project.scenes.indices.contains(i) { goToScene(project.scenes[i].id) }
            }
        }

        if envelopeTriggers.count != project.envelopes.count {
            envelopeTriggers = Array(repeating: nil, count: project.envelopes.count)
        }
        for (i, env) in project.envelopes.enumerated() {
            let fire: Bool
            switch env.trigger {
            case .beat: fire = newBeat
            case .bar: fire = newBar
            case .audioOnset: fire = ctx.audio.onset
            case .midiNote: fire = !notes.isEmpty
            case .manual: fire = false
            }
            if fire { envelopeTriggers[i] = t }
        }
    }

    private func publishMeters(_ ctx: ModulationContext) {
        meters.audio = ctx.audio
        meters.lfo = ctx.lfo
        meters.envelope = ctx.envelope
        meters.tracking = ctx.tracking
        meters.beat = ctx.beat
    }

    // MARK: Tempo & envelopes

    func tapTempo() {
        let t = now
        tapTimes = tapTimes.filter { t - $0 < 3 } + [t]
        if tapTimes.count >= 2 {
            let intervals = zip(tapTimes, tapTimes.dropFirst()).map { $1 - $0 }
            let avg = intervals.reduce(0, +) / Double(intervals.count)
            project.bpm = min(240, max(40, (60 / avg).rounded()))
        }
        beatOrigin = t
    }

    func triggerManualEnvelopes() {
        for (i, env) in project.envelopes.enumerated() where env.trigger == .manual {
            if envelopeTriggers.indices.contains(i) { envelopeTriggers[i] = now }
        }
    }

    func learnMIDI(_ callback: @escaping (ModSource) -> Void) {
        _ = midi.takeLastCC()
        midiLearnCallback = callback
        midiLearnActive = true
    }

    // MARK: Scenes

    func goToScene(_ id: UUID) {
        if let tr = transition {
            if tr.to == id { return }
            project.activeSceneID = tr.to // snap the running transition
            transition = nil
        }
        guard id != project.activeSceneID, let from = project.activeSceneID else {
            project.activeSceneID = id
            return
        }
        let tr = project.transition
        if tr.style == .cut || tr.duration <= 0 {
            project.activeSceneID = id
            transitionTargetID = nil
        } else {
            transition = (from, id, now, tr.style, tr.duration)
            transitionTargetID = id
        }
    }

    func addScene(duplicating source: MapScene? = nil) {
        var scene = MapScene(name: "Scene \(project.scenes.count + 1)")
        if let source {
            scene.name = source.name + " copy"
            scene.tint = source.tint
            // New layer IDs so generator textures aren't shared between scenes.
            scene.assignments = source.assignments.mapValues { content in
                var c = content
                c.layers = c.layers.map { var l = $0; l.id = UUID(); return l }
                return c
            }
        }
        project.scenes.append(scene)
        goToScene(scene.id)
    }

    func deleteScene(_ id: UUID) {
        guard project.scenes.count > 1 else { return }
        project.scenes.removeAll { $0.id == id }
        project.timeline.clips.removeAll { $0.sceneID == id }
        if project.activeSceneID == id { project.activeSceneID = project.scenes.first?.id }
    }

    // MARK: Surfaces

    var selectedSurface: Surface? { project.surfaces.first { $0.id == selectedSurfaceID } }

    @discardableResult
    func addSurface(_ shape: SurfaceShape, name: String? = nil, mesh: WarpMesh? = nil, preset: VisualPreset? = nil) -> UUID {
        let aspect = project.outputAspect
        let defaultSize = SIMD2<Float>(0.35 / aspect * 1.4, 0.35 * 1.4) // roughly square on the output
        let offset = Float(project.surfaces.count % 5) * 0.04
        var surface = Surface(name: name ?? "\(shape.displayName) \(project.surfaces.count + 1)", shape: shape,
                              mesh: mesh ?? .rect(center: SIMD2(0.5 + offset, 0.5 + offset), size: defaultSize))
        if case .text = shape {
            surface.mesh = mesh ?? .rect(center: SIMD2(0.5, 0.5), size: SIMD2(0.6, 0.25))
        }
        project.surfaces.append(surface)
        let layer = (preset ?? PresetLibrary.all.randomElement()!).makeLayer()
        updateContent(surfaceID: surface.id) { $0.layers = [layer] }
        selectedSurfaceID = surface.id
        return surface.id
    }

    /// Three faces of a box seen corner-on (top, left, right), sharing edges.
    func addBox() {
        let group = UUID()
        let a = project.outputAspect
        let c = SIMD2<Float>(0.5, 0.52)
        let w: Float = 0.16 / a * 1.6, h: Float = 0.12, d: Float = 0.22
        let top = c + SIMD2(0, -h * 2), left = c + SIMD2(-w, -h), right = c + SIMD2(w, -h)
        let bottom = c + SIMD2(0, d), bl = left + SIMD2(0, d), br = right + SIMD2(0, d)
        let meshes = [
            WarpMesh.quad(left, top, c, right),       // top face
            WarpMesh.quad(left, c, bl, bottom),        // left face
            WarpMesh.quad(c, right, bottom, br),       // right face
        ]
        let names = ["Box top", "Box left", "Box right"]
        let preset = PresetLibrary.all.randomElement()!
        for i in 0..<3 {
            let id = addSurface(.boxFace(index: i), name: names[i], mesh: meshes[i], preset: preset)
            updateSurface(id) { $0.groupID = group }
        }
    }

    func updateSurface(_ id: UUID, _ change: (inout Surface) -> Void) {
        guard let i = project.surfaceIndex(id) else { return }
        change(&project.surfaces[i])
    }

    func deleteSurface(_ id: UUID) {
        project.surfaces.removeAll { $0.id == id }
        for i in project.scenes.indices { project.scenes[i].assignments[id] = nil }
        if selectedSurfaceID == id { selectedSurfaceID = nil }
    }

    func duplicateSurface(_ id: UUID) {
        guard let s = project.surfaces.first(where: { $0.id == id }) else { return }
        var copy = s
        copy.id = UUID()
        copy.name = s.name + " copy"
        copy.groupID = nil
        copy.mesh.translate(by: SIMD2(0.03, 0.03))
        project.surfaces.append(copy)
        for i in project.scenes.indices {
            if var c = project.scenes[i].assignments[id] {
                c.layers = c.layers.map { var l = $0; l.id = UUID(); return l }
                project.scenes[i].assignments[copy.id] = c
            }
        }
        selectedSurfaceID = copy.id
    }

    func moveSurface(_ id: UUID, by delta: Int) {
        guard let i = project.surfaceIndex(id) else { return }
        let j = min(max(i + delta, 0), project.surfaces.count - 1)
        project.surfaces.swapAt(i, j)
    }

    /// Edit a surface's content in the active scene (or a given scene).
    func updateContent(surfaceID: UUID, sceneID: UUID? = nil, _ change: (inout SurfaceContent) -> Void) {
        guard let si = project.sceneIndex(sceneID ?? project.activeSceneID) ?? project.scenes.indices.first else { return }
        var content = project.scenes[si].content(for: surfaceID)
        change(&content)
        project.scenes[si].assignments[surfaceID] = content
    }

    func content(for surfaceID: UUID) -> SurfaceContent {
        project.activeScene?.content(for: surfaceID) ?? SurfaceContent()
    }

    // MARK: Timeline

    func playTimeline() {
        project.timeline.sortClips()
        guard !project.timeline.clips.isEmpty else { return }
        stopTimeline()
        if let audioID = project.timeline.audioAssetID, let url = ProjectStore.shared.assetURL(audioID) {
            audioPlayer = try? AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            if trackAnalysis?.id != audioID {
                Task.detached(priority: .userInitiated) {
                    if let a = try? AudioAnalysis.analyze(url: url) {
                        await MainActor.run { self.trackAnalysis = (audioID, a) }
                    }
                }
            }
        }
        timelineStart = now
        lastTimelineClipID = nil
        isTimelinePlaying = true
        audioPlayer?.currentTime = 0
        audioPlayer?.play()
        sources.restartVideos()
    }

    func stopTimeline() {
        isTimelinePlaying = false
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private func processTimeline(_ t: Double, ctx: inout ModulationContext) {
        guard isTimelinePlaying else { return }
        let tl = project.timeline
        var pos = audioPlayer.map { $0.currentTime } ?? (t - timelineStart)
        if pos >= tl.duration || (audioPlayer != nil && !(audioPlayer!.isPlaying)) {
            // Loop the show.
            timelineStart = t
            audioPlayer?.currentTime = 0
            audioPlayer?.play()
            pos = 0
        }
        if abs(pos - timelinePosition) > 1.0 / 30 { timelinePosition = pos }
        if let clip = tl.clip(at: pos), clip.id != lastTimelineClipID {
            let isFirstClip = lastTimelineClipID == nil
            lastTimelineClipID = clip.id
            if isFirstClip {
                // Start the show on its first scene without a transition.
                transition = nil
                transitionTargetID = nil
                project.activeSceneID = clip.sceneID
            } else {
                goToScene(clip.sceneID)
            }
        }
        for lane in tl.automation {
            if let v = lane.value(at: pos), ctx.macros.indices.contains(lane.macroIndex) { ctx.macros[lane.macroIndex] = v }
        }
        if let a = trackAnalysis?.analysis { ctx.audio = a.bands(at: pos) }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = project
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            try? ProjectStore.shared.save(snapshot)
        }
    }

    func saveNow() { try? ProjectStore.shared.save(project) }
}

/// CADisplayLink retains its target; this breaks the cycle with the engine.
private final class DisplayLinkTarget: NSObject {
    weak var engine: Engine?
    init(engine: Engine) { self.engine = engine }
    @objc func tick() { MainActor.assumeIsolated { engine?.tick() } }
}
