import AVFoundation
import Foundation

/// Decodes any audio file macOS can read (WAV, MP3, iPhone Voice Memos M4A, AAC, AIFF, CAF, FLAC)
/// into 16 kHz mono, a few seconds at a time, from any point in the file. An hour of audio never
/// sits in memory at once.
final class AudioStream {
    enum StreamError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail): return "Navo can't read this audio file (\(detail))"
            }
        }
    }

    private final class ReadState {
        var error: Error?
        var finished = false
    }

    let totalSeconds: TimeInterval
    private(set) var reachedEnd = false
    private let file: AVAudioFile
    private let converter: AVAudioConverter

    init(url: URL, startAt seconds: TimeInterval = 0) throws {
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw StreamError.unreadable(error.localizedDescription)
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: SpeechAudio.format) else {
            throw StreamError.unreadable("unsupported format")
        }
        converter.downmix = true
        self.converter = converter
        let rate = file.fileFormat.sampleRate
        totalSeconds = rate > 0 ? Double(file.length) / rate : 0
        if seconds > 0 {
            let frame = AVAudioFramePosition(seconds * file.processingFormat.sampleRate)
            if frame >= file.length {
                reachedEnd = true
            } else {
                file.framePosition = frame
            }
        }
    }

    /// Duration of a file without decoding it, or nil when macOS cannot read it.
    static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// The samples between two times, for redoing one part of a transcript.
    static func samples(of url: URL, from start: TimeInterval, to end: TimeInterval) throws -> [Float] {
        let stream = try AudioStream(url: url, startAt: start)
        let wanted = max(0, Int((end - start) * Double(SpeechAudio.sampleRate)))
        var samples: [Float] = []
        samples.reserveCapacity(wanted)
        while samples.count < wanted, let block = try stream.read() {
            samples.append(contentsOf: block)
        }
        return Array(samples.prefix(wanted))
    }

    /// The next few seconds, or nil at the end of the file.
    func read() throws -> [Float]? {
        while !reachedEnd {
            let block = try readBlock()
            if !block.isEmpty { return block }
        }
        return nil
    }

    private func readBlock() throws -> [Float] {
        guard let output = AVAudioPCMBuffer(pcmFormat: SpeechAudio.format, frameCapacity: AVAudioFrameCount(SpeechAudio.sampleRate * 4)) else {
            throw StreamError.unreadable("out of memory")
        }
        let state = ReadState()
        let source = file
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { packets, inputStatus in
            if state.finished {
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: packets) else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try source.read(into: buffer, frameCount: packets)
            } catch {
                if source.framePosition < source.length {
                    state.error = error
                }
                state.finished = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            if buffer.frameLength == 0 {
                state.finished = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        if let error = state.error {
            throw StreamError.unreadable(error.localizedDescription)
        }
        if status == .error {
            throw StreamError.unreadable(conversionError?.localizedDescription ?? "conversion failed")
        }
        if status == .endOfStream || (state.finished && output.frameLength == 0) {
            reachedEnd = true
        }
        guard let channel = output.floatChannelData, output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

/// Hands out a long audio file in pieces of about `pieceSeconds`, each cut inside a pause near
/// its end (SmartCut through PieceCutter, the same cutting as live meeting text), so no word is
/// split between two pieces.
final class AudioChunker {
    struct Chunk {
        let index: Int
        let start: TimeInterval
        let samples: [Float]

        var end: TimeInterval { start + Double(samples.count) / Double(SpeechAudio.sampleRate) }
    }

    let totalSeconds: TimeInterval
    private let stream: AudioStream
    private let cutter: PieceCutter
    private var ready: [PieceCutter.Piece] = []
    private var finished = false

    /// Starts at `startAt` seconds (after the parts already transcribed), numbering from `firstIndex`.
    init(url: URL, pieceSeconds: TimeInterval, startAt: TimeInterval = 0, firstIndex: Int = 0) throws {
        stream = try AudioStream(url: url, startAt: startAt)
        totalSeconds = stream.totalSeconds
        cutter = PieceCutter(
            targetSeconds: pieceSeconds,
            startSample: Int((startAt * Double(SpeechAudio.sampleRate)).rounded()),
            firstIndex: firstIndex
        )
    }

    /// The next piece, or nil at the end of the file.
    func next() throws -> Chunk? {
        while ready.isEmpty && !finished {
            if let block = try stream.read() {
                ready.append(contentsOf: cutter.append(block))
            } else {
                finished = true
                if let last = cutter.finish() {
                    ready.append(last)
                }
            }
        }
        guard !ready.isEmpty else { return nil }
        let piece = ready.removeFirst()
        return Chunk(index: piece.index, start: piece.startSeconds, samples: piece.samples)
    }
}
