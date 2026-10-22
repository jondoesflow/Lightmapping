import Accelerate
import AVFoundation

/// FFT band analysis shared by the live microphone path and offline (export) analysis.
/// Band values are auto-gained against a slowly decaying peak so visuals respond the
/// same whether the room is quiet or loud.
final class BandAnalyzer {
    static let fftSize = 1024
    private let log2n = vDSP_Length(10)
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: BandAnalyzer.fftSize)
    private var peaks: [Float] = [1e-3, 1e-3, 1e-3, 1e-3]
    private var smoothed = AudioBands()
    private var bassAverage: Float = 0
    private var lastOnset: Double = -1

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(BandAnalyzer.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `samples` must hold at least `fftSize` mono samples.
    func analyze(_ samples: UnsafePointer<Float>, sampleRate: Double, time: Double, dt: Double) -> AudioBands {
        let n = BandAnalyzer.fftSize
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }

        let binHz = sampleRate / Double(n)
        func band(_ lo: Double, _ hi: Double) -> Float {
            let a = max(1, Int(lo / binHz)), b = min(n / 2 - 1, Int(hi / binHz))
            guard b > a else { return 0 }
            var sum: Float = 0
            vDSP_sve(Array(mags[a...b]), 1, &sum, vDSP_Length(b - a + 1))
            return sqrt(sum / Float(b - a + 1))
        }
        let raw = [rms, band(20, 250), band(250, 2000), band(2000, 8000)]

        // Auto-gain: decay peaks by ~50% over 4 seconds.
        let decay = Float(pow(0.5, dt / 4))
        var norm = [Float](repeating: 0, count: 4)
        for i in 0..<4 {
            peaks[i] = max(raw[i], peaks[i] * decay, 1e-4)
            norm[i] = min(1, raw[i] / peaks[i])
            // Gate out the noise floor.
            if raw[i] < 1e-4 { norm[i] = 0 }
        }

        // Fast attack, slower release.
        func follow(_ old: Float, _ new: Float) -> Float {
            let k: Float = new > old ? 0.6 : Float(min(1, dt * 6))
            return old + (new - old) * k
        }
        smoothed.level = follow(smoothed.level, norm[0])
        smoothed.bass = follow(smoothed.bass, norm[1])
        smoothed.mid = follow(smoothed.mid, norm[2])
        smoothed.high = follow(smoothed.high, norm[3])

        bassAverage += (norm[1] - bassAverage) * Float(min(1, dt * 2))
        smoothed.onset = norm[1] > 0.6 && norm[1] > bassAverage * 1.4 && time - lastOnset > 0.15
        if smoothed.onset { lastOnset = time }
        return smoothed
    }
}

/// Live microphone analysis.
final class LiveAudioInput {
    private let engine = AVAudioEngine()
    private let analyzer = BandAnalyzer()
    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: BandAnalyzer.fftSize)
    private var bands = AudioBands()
    private var pendingOnset = false
    private var lastTime = CACurrentMediaTime()
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(BandAnalyzer.fftSize), format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        lock.lock(); bands = AudioBands(); lock.unlock()
    }

    /// Latest bands. `onset` is latched until read so the render loop never misses a hit.
    func read() -> AudioBands {
        lock.lock(); defer { lock.unlock() }
        var b = bands
        b.onset = pendingOnset
        pendingOnset = false
        return b
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let n = BandAnalyzer.fftSize
        if count >= n {
            ring = Array(UnsafeBufferPointer(start: ch + (count - n), count: n))
        } else {
            ring.removeFirst(count)
            ring.append(contentsOf: UnsafeBufferPointer(start: ch, count: count))
        }
        let now = CACurrentMediaTime()
        let dt = now - lastTime
        lastTime = now
        let result = ring.withUnsafeBufferPointer {
            analyzer.analyze($0.baseAddress!, sampleRate: buffer.format.sampleRate, time: now, dt: dt)
        }
        lock.lock()
        bands = result
        if result.onset { pendingOnset = true }
        lock.unlock()
    }
}

/// Pre-computed per-frame bands for an audio file. Used for timeline playback and export
/// so audio-reactive visuals are identical every time the show runs.
struct AudioAnalysis {
    let fps: Double
    let frames: [AudioBands]
    let duration: Double

    func bands(at t: Double) -> AudioBands {
        guard !frames.isEmpty, t >= 0 else { return AudioBands() }
        let i = min(frames.count - 1, Int(t * fps))
        return frames[i]
    }

    static func analyze(url: URL, fps: Double = 60) throws -> AudioAnalysis {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate, channels: 1, interleaved: false)!
        let total = AVAudioFrameCount(file.length)
        // Read via a converter so stereo / int formats become mono float.
        guard let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: total) else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: src)
        guard let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { throw CocoaError(.fileReadCorruptFile) }
        var fed = false
        var err: NSError?
        _ = converter.convert(to: mono, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        if let err { throw err }

        let sr = format.sampleRate
        let samples = UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength))
        let n = BandAnalyzer.fftSize
        let analyzer = BandAnalyzer()
        let duration = Double(samples.count) / sr
        let frameCount = Int(duration * fps)
        var frames: [AudioBands] = []
        frames.reserveCapacity(frameCount)
        var window = [Float](repeating: 0, count: n)
        for f in 0..<frameCount {
            let t = Double(f) / fps
            let end = Int(t * sr)
            let start = max(0, end - n)
            window.withUnsafeMutableBufferPointer { w in
                w.initialize(repeating: 0)
                for i in start..<min(end, samples.count) { w[n - (end - i)] = samples[i] }
            }
            frames.append(window.withUnsafeBufferPointer { analyzer.analyze($0.baseAddress!, sampleRate: sr, time: t, dt: 1 / fps) })
        }
        return AudioAnalysis(fps: fps, frames: frames, duration: duration)
    }
}
