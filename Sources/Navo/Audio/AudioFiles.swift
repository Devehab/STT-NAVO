import AVFoundation
import Foundation

/// 16 kHz mono Float32, the format every speech engine gets.
enum SpeechAudio {
    static let sampleRate = 16_000

    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRate),
        channels: 1,
        interleaved: false
    )!

    private final class Once {
        var consumed = false
    }

    /// Converts one captured buffer with a converter that keeps its state between calls (streaming).
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float] {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        let once = Once()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if once.consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            once.consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for value in samples {
            sum += value * value
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Maps RMS to 0...1 on a -55...-5 dBFS scale.
    static func level(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 55) / 50))
    }
}

/// Writes 16-bit mono PCM WAV while recording. The header sizes are filled in on close;
/// a file left open by a crash is still readable with `WAVFile.readSamples`.
final class StreamingWAVWriter {
    let url: URL
    let sampleRate: Int
    private(set) var sampleCount = 0
    private var handle: FileHandle?

    init(url: URL, sampleRate: Int = SpeechAudio.sampleRate) throws {
        self.url = url
        self.sampleRate = sampleRate
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: url.path, contents: WAVFile.header(sampleCount: 0, sampleRate: sampleRate)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.handle = handle
    }

    deinit {
        try? close()
    }

    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        try append(int16: samples.map { Int16(max(-1, min(1, $0)) * 32767) })
    }

    func append(int16 samples: [Int16]) throws {
        guard let handle, !samples.isEmpty else { return }
        let little = samples.map { $0.littleEndian }
        let data = little.withUnsafeBytes { Data($0) }
        try handle.write(contentsOf: data)
        sampleCount += samples.count
    }

    func appendSilence(_ count: Int) throws {
        guard count > 0 else { return }
        try append(int16: [Int16](repeating: 0, count: count))
    }

    /// Writes the final sizes into the header and closes the file.
    func close() throws {
        guard let handle else { return }
        self.handle = nil
        let dataBytes = UInt32(sampleCount * 2)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: WAVFile.littleEndian(UInt32(36) + dataBytes))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: WAVFile.littleEndian(dataBytes))
        try handle.synchronize()
        try handle.close()
    }
}

enum WAVFile {
    static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }

    static func header(sampleCount: Int, sampleRate: Int) -> Data {
        let dataBytes = UInt32(sampleCount * 2)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian(UInt32(36) + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian(UInt32(16)))
        data.append(littleEndian(UInt16(1))) // PCM
        data.append(littleEndian(UInt16(1))) // mono
        data.append(littleEndian(UInt32(sampleRate)))
        data.append(littleEndian(UInt32(sampleRate * 2)))
        data.append(littleEndian(UInt16(2)))
        data.append(littleEndian(UInt16(16)))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian(dataBytes))
        return data
    }

    /// Reads a 16-bit mono PCM WAV written by Navo. A zero or wrong size in the header
    /// (a file that was never closed) is ignored: everything after the header is audio.
    static func readSamples(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 12, data.prefix(4) == Data("RIFF".utf8) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        var offset = 12
        while offset + 8 <= data.count {
            let id = data.subdata(in: offset..<(offset + 4))
            let size = Int(data.subdata(in: (offset + 4)..<(offset + 8)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            let body = offset + 8
            if id == Data("data".utf8) {
                let available = data.count - body
                let length = (size > 0 && size <= available) ? size : available
                let count = length / 2
                var samples = [Int16](repeating: 0, count: count)
                samples.withUnsafeMutableBytes { target in
                    data.copyBytes(to: target.bindMemory(to: UInt8.self), from: body..<(body + count * 2))
                }
                return samples.map { Int16(littleEndian: $0) }
            }
            offset = body + size + (size % 2)
        }
        return []
    }

    static func duration(ofSamples count: Int) -> TimeInterval {
        Double(count) / Double(SpeechAudio.sampleRate)
    }
}
