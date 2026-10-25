import AVFoundation
import os
import CurrentSenseCore

/// Optional tone whose pitch follows the validated signal level. The engine only exists while a
/// measurement runs (and shortly after); amplitude and pitch are ramped per sample to avoid clicks.
@MainActor
final class AudioFeedbackService {
    private struct Params { var freq: Float = 220; var amp: Float = 0 }

    private let params = OSAllocatedUnfairLock(initialState: Params())
    private var engine: AVAudioEngine?
    private var mapper = AudioToneMapper()
    private var lastUpdate: TimeInterval?
    private var generation = 0
    private var interrupted = false
    var onFailure: ((String) -> Void)?

    init() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if type == .began {
                    self.interrupted = true
                    self.params.withLock { $0.amp = 0 }
                    self.engine?.pause()
                } else {
                    self.interrupted = false   // resumes on the next update() if a measurement is still running
                }
            }
        }
    }

    /// Called at UI-state rate (~10 Hz) with the validated 0...1 level.
    func update(level: Double, enabled: Bool) {
        guard enabled, level > 0, !interrupted else { silence(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.5, lastUpdate.map { now - $0 } ?? 0.1)
        lastUpdate = now
        generation += 1                      // cancels any scheduled teardown
        guard ensureRunning() else { return }
        let target = mapper.update(level: level, active: true, dt: dt)
        params.withLock { $0.freq = Float(target.frequencyHz); $0.amp = Float(target.amplitude) }
    }

    /// Fade to silence; release the engine if nothing happens for a few seconds.
    func silence() {
        mapper.reset()
        lastUpdate = nil
        params.withLock { $0.amp = 0 }
        scheduleTeardown(after: 3.0)
    }

    /// Measurement stopped: fade out quickly and release all audio resources.
    func stop() {
        mapper.reset()
        lastUpdate = nil
        params.withLock { $0.amp = 0 }
        scheduleTeardown(after: 0.12)
    }

    private func scheduleTeardown(after seconds: Double) {
        guard engine != nil else { return }
        generation += 1
        let g = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self = self, self.generation == g else { return }
            self.teardown()
        }
    }

    private func teardown() {
        engine?.stop()
        engine = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            onFailure?("Audio session could not be released: \(error.localizedDescription)")
        }
    }

    private func ensureRunning() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            if let e = engine {
                if !e.isRunning {
                    try session.setActive(true)
                    try e.start()
                }
                return true
            }
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let e = AVAudioEngine()
            let sr = e.outputNode.outputFormat(forBus: 0).sampleRate
            guard sr > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else {
                onFailure?("Audio output is not available.")
                return false
            }
            let params = self.params
            var phase = 0.0, freq = 220.0, amp = 0.0
            var last = Params()
            let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
                if let p = params.withLockIfAvailable({ $0 }) { last = p }
                let targetF = Double(last.freq), targetA = Double(last.amp)
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                let k = 0.0015                                  // ~14 ms smoothing at 48 kHz
                for frame in 0..<Int(frameCount) {
                    freq += (targetF - freq) * k
                    amp += (targetA - amp) * k
                    phase += 2 * Double.pi * freq / sr
                    if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                    let v = Float(sin(phase) * amp)
                    for b in buffers { b.mutableData?.assumingMemoryBound(to: Float.self)[frame] = v }
                }
                return noErr
            }
            e.attach(node)
            e.connect(node, to: e.mainMixerNode, format: format)
            e.prepare()
            try e.start()
            engine = e
            return true
        } catch {
            onFailure?("Audio feedback unavailable: \(error.localizedDescription)")
            engine?.stop()
            engine = nil
            return false
        }
    }
}
