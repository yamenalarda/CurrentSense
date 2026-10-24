import AVFoundation
import Combine
import Foundation

/// Produces a low-volume variable-pitch tone while a magnetic field change is detected.
/// AVAudioSession.Category.ambient deliberately respects the iPhone Silent switch
/// and mixes with other audio instead of overriding the user's mute choice.
@MainActor
final class FieldToneFeedback: ObservableObject {
    private final class OscillatorPhase {
        // Accessed only from AVAudioSourceNode's render callback.
        var value = 0.0
    }

    private let engine = AVAudioEngine()
    private let varispeed = AVAudioUnitVarispeed()
    private var isConfigured = false
    private var isToneActive = false
    private var smoothedRate: Double?

    func update(fieldChangeMicrotesla: Double?, measuring: Bool) {
        guard measuring,
              let field = fieldChangeMicrotesla,
              field.isFinite,
              field >= 0 else {
            stopTone()
            return
        }

        if isToneActive {
            guard field >= FieldToneMapping.releaseThresholdMicrotesla else {
                stopTone()
                return
            }
        } else {
            guard field >= FieldToneMapping.activationThresholdMicrotesla else { return }
            guard startToneIfPossible() else { return }
        }

        let mappingField = max(field, FieldToneMapping.activationThresholdMicrotesla)
        guard let targetRate = FieldToneMapping.rate(forFieldChangeMicrotesla: mappingField) else {
            return
        }

        let nextRate: Double
        if let smoothedRate {
            // Smooth pitch movement so small sensor fluctuations do not sound rough.
            nextRate = smoothedRate + (targetRate - smoothedRate) * 0.32
        } else {
            nextRate = targetRate
        }
        smoothedRate = min(max(nextRate, FieldToneMapping.minimumPlaybackRate),
                           FieldToneMapping.maximumPlaybackRate)

        if abs(Double(varispeed.rate) - (smoothedRate ?? targetRate)) >= 0.015 {
            varispeed.rate = Float(smoothedRate ?? targetRate)
        }
    }

    func stopTone() {
        if isToneActive {
            engine.stop()
            isToneActive = false
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
        smoothedRate = nil
    }

    private func startToneIfPossible() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            // .ambient is silenced by the iPhone Ring/Silent switch and allows
            // other audio to continue. Do not switch to .playback or override mute.
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if !isConfigured {
                try configureEngine()
            }
            varispeed.rate = Float(FieldToneMapping.minimumPlaybackRate)
            try engine.start()
            isToneActive = true
            smoothedRate = nil
            return true
        } catch {
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            isToneActive = false
            smoothedRate = nil
            return false
        }
    }

    private func configureEngine() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            throw ToneEngineError.unsupportedAudioFormat
        }

        let phase = OscillatorPhase()
        let baseFrequency = 440.0
        let twoPi = 2.0 * Double.pi
        let sampleRate = format.sampleRate
        let sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in buffers {
                guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                    continue
                }
                for index in 0..<Int(frameCount) {
                    samples[index] = Float(sin(phase.value) * 0.28)
                    phase.value += twoPi * baseFrequency / sampleRate
                    if phase.value >= twoPi {
                        phase.value -= twoPi
                    }
                }
            }
            return noErr
        }

        engine.attach(sourceNode)
        engine.attach(varispeed)
        engine.connect(sourceNode, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.24
        isConfigured = true
    }

    private enum ToneEngineError: Error {
        case unsupportedAudioFormat
    }
}
