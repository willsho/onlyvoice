import AVFoundation
import Foundation

/// Manages audio capture and provides real-time RMS levels + PCM data for streaming.
final class AudioEngine {
    private let engine = AVAudioEngine()
    private var isRunning = false

    /// Called with Base64-encoded PCM16 data chunks for streaming to API.
    var onAudioData: ((String) -> Void)?
    /// Called with current RMS level (0.0–1.0) for waveform visualization.
    var onRMSLevel: ((Float) -> Void)?

    /// Audio format: 16kHz mono PCM16
    private let sampleRate: Double = 16000
    private let channelCount: AVAudioChannelCount = 1
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    func start() throws {
        guard !isRunning else { return }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio input available"])
        }

        // Target format: 16kHz mono Float32 (we'll convert to PCM16 manually)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioEngine", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create target audio format"])
        }
        self.targetFormat = targetFormat
        self.converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        // Tap MUST use the input node's native hardware format; convert inside the callback.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func handleInputBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter = converter, let targetFormat = targetFormat else { return }

        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error || error != nil { return }
        if outBuffer.frameLength == 0 { return }
        processBuffer(outBuffer)
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let samples = floatData[0]

        // Calculate RMS
        var sumSquares: Float = 0
        for i in 0..<frameCount {
            let s = samples[i]
            sumSquares += s * s
        }
        let rms = sqrt(sumSquares / Float(max(frameCount, 1)))
        // Normalize RMS to 0–1 range (typical speech RMS ~0.01–0.1)
        let normalizedRMS = min(1.0, rms * 10.0)
        DispatchQueue.main.async { [weak self] in
            self?.onRMSLevel?(normalizedRMS)
        }

        // Convert Float32 to PCM16 (Int16) and Base64 encode
        var pcm16Data = Data(capacity: frameCount * 2)
        for i in 0..<frameCount {
            let clamped = max(-1.0, min(1.0, samples[i]))
            var int16Val = Int16(clamped * 32767.0)
            pcm16Data.append(Data(bytes: &int16Val, count: 2))
        }

        let base64String = pcm16Data.base64EncodedString()
        onAudioData?(base64String)
    }
}
