import Foundation

/// Cuts a stream of 16 kHz audio into pieces of about `targetSeconds`, each cut inside a pause
/// found by SmartCut within `radius` either side of the target. Used for live meeting text and
/// for long files alike, so both are cut the same way.
///
/// A cut is decided once the audio reaches target + radius + one second, so the pause at the far
/// end of the search range is measured in full. Holds at most that much audio.
final class PieceCutter {
    struct Piece {
        let index: Int
        /// First sample of the piece in the whole stream.
        let start: Int
        let samples: [Float]

        var startSeconds: Double { Double(start) / Double(SmartCut.sampleRate) }
        var endSeconds: Double { Double(start + samples.count) / Double(SmartCut.sampleRate) }
    }

    let target: Int
    let radius: Int
    private var buffer: [Float] = []
    private var bufferStart: Int
    private var nextIndex: Int

    init(targetSeconds: Double, startSample: Int = 0, firstIndex: Int = 0) {
        let seconds = max(10, targetSeconds)
        target = Int(seconds * Double(SmartCut.sampleRate))
        radius = SmartCut.radius(forTarget: seconds)
        bufferStart = startSample
        nextIndex = firstIndex
    }

    /// Adds audio; returns the pieces that are now complete.
    func append(_ samples: [Float]) -> [Piece] {
        guard !samples.isEmpty else { return [] }
        buffer.append(contentsOf: samples)
        var pieces: [Piece] = []
        while buffer.count >= target + radius + SmartCut.lookahead {
            pieces.append(take(cutPoint()))
        }
        return pieces
    }

    /// The audio is over: the rest, as one piece. `append` never leaves more than
    /// target + radius + one second, so this piece is never much longer than the others.
    func finish() -> Piece? {
        buffer.isEmpty ? nil : take(buffer.count)
    }

    private func cutPoint() -> Int {
        let cut = SmartCut.findCut(in: buffer, lo: target - radius, hi: target + radius, target: target)
        return max(1, min(cut, buffer.count))
    }

    private func take(_ count: Int) -> Piece {
        let piece = Piece(index: nextIndex, start: bufferStart, samples: Array(buffer[0..<count]))
        buffer.removeFirst(count)
        bufferStart += count
        nextIndex += 1
        return piece
    }
}

/// Mixes the tracks of a meeting recording as they are written, sample for sample and the same
/// way the finished recording is mixed (summed, then clipped), so live pieces line up exactly
/// with the saved file. Holds only the few buffers one track is ahead of the other.
final class TrackMixer {
    private let tracks: [RecordingTrack]
    private var pending: [RecordingTrack: [Float]] = [:]

    init(tracks: [RecordingTrack]) {
        self.tracks = tracks
        for track in tracks {
            pending[track] = []
        }
    }

    /// Adds samples written to one track; returns the mix for the stretch every track now covers.
    func append(_ samples: [Float], to track: RecordingTrack) -> [Float] {
        guard pending[track] != nil, !samples.isEmpty else { return [] }
        pending[track]?.append(contentsOf: samples)
        let ready = tracks.map { pending[$0]?.count ?? 0 }.min() ?? 0
        guard ready > 0 else { return [] }
        if tracks.count == 1 {
            let all = pending[track] ?? []
            pending[track] = []
            return all
        }
        var mixed = [Float](repeating: 0, count: ready)
        for other in tracks {
            guard let buffer = pending[other] else { continue }
            for i in 0..<ready {
                mixed[i] += buffer[i]
            }
            pending[other]?.removeFirst(ready)
        }
        for i in 0..<ready {
            mixed[i] = max(-1, min(1, mixed[i]))
        }
        return mixed
    }
}
