import AVFoundation
import Foundation

enum RecorderError: LocalizedError {
    case noInputDevice
    case unsupportedFormat
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone found"
        case .unsupportedFormat: return "The microphone format is not supported"
        case .engine(let message): return "Could not start the microphone: \(message)"
        }
    }
}

/// Captures the default microphone and converts it on the fly to 16 kHz mono Float32,
/// the format Cohere Transcribe expects.
final class AudioRecorder {
    struct Recording {
        let samples: [Float]
        let duration: TimeInterval
        let peakRMS: Float
    }

    static let sampleRate: Double = 16_000

    /// Called on the audio thread with a 0...1 loudness value for the waveform.
    var onLevel: (@Sendable (Float) -> Void)?

    private final class ConversionState {
        var consumed = false
    }

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peak: Float = 0

    var isRecording: Bool { engine != nil }

    func start() throws {
        guard engine == nil else { return }
        // A fresh engine per session follows changes of the default input device.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else { throw RecorderError.unsupportedFormat }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(Self.sampleRate) * 60)
        peak = 0
        lock.unlock()

        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            throw RecorderError.engine(error.localizedDescription)
        }
        self.engine = engine
    }

    func stop() -> Recording {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil

        lock.lock()
        let captured = samples
        let peakValue = peak
        samples = []
        peak = 0
        lock.unlock()

        return Recording(
            samples: captured,
            duration: Double(captured.count) / Self.sampleRate,
            peakRMS: peakValue
        )
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let rms = Self.rms(buffer)

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        let state = ConversionState()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if state.consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            state.consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData else { return }
        let count = Int(output.frameLength)

        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
        if rms > peak { peak = rms }
        lock.unlock()

        onLevel?(Self.normalizedLevel(rms))
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        let channel = data[0]
        var sum: Float = 0
        for index in 0..<frames {
            let value = channel[index]
            sum += value * value
        }
        return (sum / Float(frames)).squareRoot()
    }

    /// Maps RMS to 0...1 on a -55...-5 dBFS scale.
    private static func normalizedLevel(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 55) / 50))
    }
}

enum WAVWriter {
    /// Writes 16-bit PCM mono WAV.
    static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
        let pcm: [Int16] = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        let dataBytes = pcm.count * 2
        var data = Data(capacity: 44 + dataBytes)

        func appendInteger<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendInteger(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendInteger(UInt32(16))
        appendInteger(UInt16(1))
        appendInteger(UInt16(1))
        appendInteger(UInt32(sampleRate))
        appendInteger(UInt32(sampleRate * 2))
        appendInteger(UInt16(2))
        appendInteger(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        appendInteger(UInt32(dataBytes))
        pcm.withUnsafeBufferPointer { data.append($0) }
        try data.write(to: url, options: .atomic)
    }
}

enum MicrophonePermission {
    static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
