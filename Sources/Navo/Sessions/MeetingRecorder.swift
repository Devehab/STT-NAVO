import AVFoundation
import Foundation

/// What a meeting recording captures.
enum MeetingSource: String, CaseIterable, Identifiable {
    case both
    case system
    case mic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return "Mac audio and my microphone"
        case .system: return "Mac audio only"
        case .mic: return "My microphone only"
        }
    }

    var shortTitle: String {
        switch self {
        case .both: return "Mac + mic"
        case .system: return "Mac audio"
        case .mic: return "Microphone"
        }
    }

    var tracks: [RecordingTrack] {
        switch self {
        case .both: return [.mic, .system]
        case .system: return [.system]
        case .mic: return [.mic]
        }
    }
}

enum RecordingTrack: String {
    case mic
    case system
}

/// Writes a recording as numbered parts, one WAV per track and part, so a crash or a full disk
/// loses at most the part being written. Confined to the recorder's writer queue.
///
/// Each track moves to its next part on its own, exactly every `partSamples`, so the tracks
/// stay sample-continuous across parts: part N of the microphone and part N of the Mac audio
/// cover the same stretch of time and can be mixed side by side.
final class PartWriter {
    let directory: URL
    let tracks: [RecordingTrack]
    let partSamples: Int
    /// A track this far behind another (its device stopped delivering) is padded with silence,
    /// so the tracks never drift apart. Normal delivery keeps them within a fraction of a second.
    let maxLag = 2 * SpeechAudio.sampleRate
    private var writers: [RecordingTrack: StreamingWAVWriter] = [:]
    private var partNumbers: [RecordingTrack: Int] = [:]
    private var reportedParts = 0
    /// Called with the number of parts that every track has finished.
    var onPartSaved: (@Sendable (Int) -> Void)?
    /// Sees every sample written to a track, padding included, in order (for live text).
    var onWrite: (@Sendable ([Float], RecordingTrack) -> Void)?

    init(directory: URL, tracks: [RecordingTrack], partSeconds: Int) throws {
        self.directory = directory
        self.tracks = tracks
        self.partSamples = max(10, partSeconds) * SpeechAudio.sampleRate
        for track in tracks {
            try open(track, part: 1)
        }
    }

    static func url(in directory: URL, part: Int, track: RecordingTrack) -> URL {
        directory.appendingPathComponent(String(format: "part-%04d-%@.wav", part, track.rawValue))
    }

    func append(_ samples: [Float], to track: RecordingTrack) throws {
        try write(samples, to: track)
        let lead = total(track)
        for other in tracks where other != track && total(other) + maxLag < lead {
            try write([Float](repeating: 0, count: lead - total(other)), to: other)
        }
    }

    /// Pads the tracks that are behind with silence, so they line up again (used at a pause).
    func align() throws {
        let totals = tracks.map(total)
        let longest = totals.max() ?? 0
        for (track, count) in zip(tracks, totals) where count < longest {
            try write([Float](repeating: 0, count: longest - count), to: track)
        }
    }

    private func write(_ samples: [Float], to track: RecordingTrack) throws {
        guard writers[track] != nil, !samples.isEmpty else { return }
        onWrite?(samples, track)
        var remaining = samples[...]
        while !remaining.isEmpty {
            guard let writer = writers[track], let part = partNumbers[track] else { return }
            let take = min(partSamples - writer.sampleCount, remaining.count)
            try writer.append(Array(remaining.prefix(take)))
            remaining = remaining.dropFirst(take)
            if writer.sampleCount >= partSamples {
                try writer.close()
                try open(track, part: part + 1)
                reportFinishedParts()
            }
        }
    }

    /// Closes the last part of every track, even after a write error. Returns the number of parts.
    func finish() -> Int {
        try? align()
        var last = 0
        for track in tracks {
            guard let writer = writers[track], let part = partNumbers[track] else { continue }
            let empty = writer.sampleCount == 0
            try? writer.close()
            if empty {
                try? FileManager.default.removeItem(at: Self.url(in: directory, part: part, track: track))
                last = max(last, part - 1)
            } else {
                last = max(last, part)
            }
        }
        writers = [:]
        return last
    }

    private func open(_ track: RecordingTrack, part: Int) throws {
        writers[track] = try StreamingWAVWriter(url: Self.url(in: directory, part: part, track: track))
        partNumbers[track] = part
    }

    private func total(_ track: RecordingTrack) -> Int {
        ((partNumbers[track] ?? 1) - 1) * partSamples + (writers[track]?.sampleCount ?? 0)
    }

    private func reportFinishedParts() {
        let finished = (partNumbers.values.min() ?? 1) - 1
        if finished > reportedParts {
            reportedParts = finished
            onPartSaved?(finished)
        }
    }
}

/// Joins the parts of a recording into one WAV, mixing the microphone and Mac audio tracks.
enum PartCombiner {
    /// Part numbers found on disk, in order.
    static func parts(in directory: URL) -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let numbers = names.compactMap { name -> Int? in
            guard name.hasPrefix("part-"), name.hasSuffix(".wav") else { return nil }
            return Int(name.dropFirst(5).prefix(4))
        }
        return Array(Set(numbers)).sorted()
    }

    /// Writes `output` and returns its duration in seconds. The parts are left in place.
    static func combine(directory: URL, into output: URL) throws -> TimeInterval {
        let writer = try StreamingWAVWriter(url: output)
        for part in parts(in: directory) {
            var tracks: [[Int16]] = []
            for track in [RecordingTrack.mic, .system] {
                let url = PartWriter.url(in: directory, part: part, track: track)
                if FileManager.default.fileExists(atPath: url.path) {
                    tracks.append(try WAVFile.readSamples(url))
                }
            }
            try writer.append(int16: mix(tracks))
        }
        let count = writer.sampleCount
        try writer.close()
        return WAVFile.duration(ofSamples: count)
    }

    static func mix(_ tracks: [[Int16]]) -> [Int16] {
        guard tracks.count > 1 else { return tracks.first ?? [] }
        let length = tracks.map(\.count).max() ?? 0
        var mixed = [Int16](repeating: 0, count: length)
        for index in 0..<length {
            var sum: Int32 = 0
            for track in tracks where index < track.count {
                sum += Int32(track[index])
            }
            mixed[index] = Int16(clamping: sum)
        }
        return mixed
    }
}

/// A piece of a meeting ready for live transcription, saved as a WAV next to the recording.
struct LivePiece: Sendable {
    let index: Int
    let start: TimeInterval
    let end: TimeInterval
    /// Nil when the piece could not be saved; `problem` says why.
    let url: URL?
    /// Too short or too quiet to hold speech: nothing to send.
    let silent: Bool
    let problem: String?
}

/// Mixes the tracks as they are written and cuts the mix into pieces at pauses. Writer queue only.
private final class LiveFeed {
    private let mixer: TrackMixer
    private let cutter: PieceCutter
    private let directory: URL
    private let deliver: @Sendable (LivePiece) -> Void

    init(tracks: [RecordingTrack], pieceSeconds: Double, directory: URL, deliver: @escaping @Sendable (LivePiece) -> Void) {
        mixer = TrackMixer(tracks: tracks)
        cutter = PieceCutter(targetSeconds: pieceSeconds)
        self.directory = directory
        self.deliver = deliver
    }

    func add(_ samples: [Float], track: RecordingTrack) {
        for piece in cutter.append(mixer.append(samples, to: track)) {
            save(piece)
        }
    }

    /// Hands out what is buffered now (at a pause or at the end), without waiting for a full piece.
    func flush() {
        if let piece = cutter.finish() {
            save(piece)
        }
    }

    private func save(_ piece: PieceCutter.Piece) {
        let silent = piece.samples.count < SpeechAudio.sampleRate / 2 || SmartCut.isSilent(piece.samples)
        let url = directory.appendingPathComponent(String(format: "piece-%04d.wav", piece.index))
        do {
            if !silent {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try WAVWriter.write(samples: piece.samples, sampleRate: SpeechAudio.sampleRate, to: url)
            }
            deliver(LivePiece(index: piece.index, start: piece.startSeconds, end: piece.endSeconds,
                              url: silent ? nil : url, silent: silent, problem: nil))
        } catch {
            deliver(LivePiece(index: piece.index, start: piece.startSeconds, end: piece.endSeconds,
                              url: nil, silent: false, problem: "Could not save this piece: \(error.localizedDescription)"))
        }
    }
}

/// The part writer and the live feed, reached only on the recorder's writer queue (hence
/// unchecked: the queue is what keeps it safe).
private final class WriterBox: @unchecked Sendable {
    var writer: PartWriter?
    var live: LiveFeed?
    /// False while paused: buffers still in flight when the sources stopped are dropped,
    /// so the tracks stay aligned.
    var accepting = true

    init(_ writer: PartWriter?) {
        self.writer = writer
    }
}

/// Records a meeting: the Mac's sound, the microphone, or both, with pause and resume.
/// Audio goes to disk in parts as it comes in; stopping joins the parts into one file.
@MainActor
final class MeetingRecorder: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case paused
        case finishing
    }

    struct Finished {
        let sessionID: String
        let audioURL: URL?
        let duration: TimeInterval
        let error: String?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var partsSaved = 0
    @Published private(set) var problem: String?
    /// Seconds of recording with no sound at all from the Mac (a hint that the permission is missing).
    @Published private(set) var systemSilentSeconds: TimeInterval = 0
    @Published private(set) var source: MeetingSource = .both
    private(set) var sessionID: String?
    /// Pieces are being handed out for live text.
    @Published private(set) var isLive = false
    /// Length of the live pieces of the current recording, in seconds.
    private(set) var livePieceSeconds: Double = 0

    var onFinished: ((Finished) -> Void)?

    var isActive: Bool { phase != .idle }

    private var sources: [RecordingTrack: SampleSource] = [:]
    private var box = WriterBox(nil)
    private let writerQueue = DispatchQueue(label: "navo.meeting.writer", qos: .userInitiated)
    private var timer: Timer?
    private var lastLevelUpdate: [RecordingTrack: Date] = [:]
    private var systemHeard = false

    /// Starts recording into Sessions/<id>/parts. Throws when a source cannot start.
    /// With `livePieceSeconds`, the mix is also cut at pauses into pieces of about that length,
    /// handed to `onPiece` on the writer queue as each one closes.
    func start(
        sessionID: String,
        source: MeetingSource,
        partMinutes: Int,
        livePieceSeconds: Double? = nil,
        onPiece: (@Sendable (LivePiece) -> Void)? = nil
    ) throws {
        guard phase == .idle else { return }
        let box = WriterBox(nil)
        let queue = writerQueue

        var created: [RecordingTrack: SampleSource] = [:]
        for track in source.tracks {
            guard let capture: SampleSource = track == .mic ? MicCapture() : SystemAudio.makeCapture() else {
                throw CaptureError.systemAudioUnavailable
            }
            // Called on the capture threads: write on the writer queue, show levels on the main actor.
            capture.onSamples = { [weak self] samples in
                guard let self else { return }
                let level = SpeechAudio.level(SpeechAudio.rms(samples))
                queue.async {
                    guard box.accepting else { return }
                    do {
                        try box.writer?.append(samples, to: track)
                    } catch {
                        let message = "Could not save the recording: \(error.localizedDescription)"
                        Task { @MainActor in
                            self.problem = message
                        }
                    }
                }
                Task { @MainActor in
                    self.show(level: level, track: track)
                }
            }
            capture.onFailure = { [weak self] message in
                guard let self else { return }
                Task { @MainActor in
                    self.problem = message
                }
            }
            // A device change cost this track a moment of audio: pad it so the tracks line up again.
            capture.onRestart = {
                queue.async {
                    try? box.writer?.align()
                }
            }
            created[track] = capture
        }

        let directory = Paths.sessionDir(sessionID).appendingPathComponent("parts", isDirectory: true)
        let writer: PartWriter
        do {
            writer = try PartWriter(directory: directory, tracks: source.tracks, partSeconds: partMinutes * 60)
        } catch {
            try? FileManager.default.removeItem(at: Paths.sessionDir(sessionID))
            throw error
        }
        writer.onPartSaved = { [weak self] number in
            guard let self else { return }
            Task { @MainActor in
                self.partsSaved = number
            }
        }
        if let livePieceSeconds, let onPiece {
            box.live = LiveFeed(
                tracks: source.tracks,
                pieceSeconds: livePieceSeconds,
                directory: Paths.sessionDir(sessionID).appendingPathComponent("live", isDirectory: true),
                deliver: onPiece
            )
            writer.onWrite = { [weak box] samples, track in
                box?.live?.add(samples, track: track)
            }
        }
        box.writer = writer

        self.box = box
        self.sources = created
        self.sessionID = sessionID
        self.source = source
        elapsed = 0
        partsSaved = 0
        problem = nil
        systemSilentSeconds = 0
        systemHeard = false
        micLevel = 0
        systemLevel = 0
        do {
            try startSources()
        } catch {
            stopSources()
            writerQueue.sync {
                _ = box.writer?.finish()
                box.writer = nil
                box.live = nil
            }
            self.sources = [:]
            self.box = WriterBox(nil)
            self.sessionID = nil
            try? FileManager.default.removeItem(at: Paths.sessionDir(sessionID))
            throw error
        }
        isLive = livePieceSeconds != nil && onPiece != nil
        self.livePieceSeconds = livePieceSeconds ?? 0
        phase = .recording
        startTimer()
    }

    /// Stops handing out live pieces; the recording goes on.
    func stopLive() {
        let box = self.box
        writerQueue.async {
            box.live = nil
        }
        isLive = false
    }

    func pause() {
        guard phase == .recording else { return }
        stopSources()
        let box = self.box
        writerQueue.async {
            box.accepting = false
            try? box.writer?.align()
            // The text catches up to the pause instead of waiting for the next full piece.
            box.live?.flush()
        }
        phase = .paused
        micLevel = 0
        systemLevel = 0
    }

    func resume() {
        guard phase == .paused else { return }
        let box = self.box
        writerQueue.sync {
            box.accepting = true
        }
        do {
            try startSources()
            phase = .recording
            problem = nil
        } catch {
            stopSources() // one source started and the other did not: stay paused with neither running
            writerQueue.async {
                box.accepting = false
                try? box.writer?.align()
            }
            problem = error.localizedDescription
        }
    }

    /// Stops, joins the parts into recording.wav and reports through onFinished.
    func stop() {
        guard phase == .recording || phase == .paused, let sessionID else { return }
        let box = self.box
        stopSources()
        timer?.invalidate()
        timer = nil
        phase = .finishing
        micLevel = 0
        systemLevel = 0
        let directory = Paths.sessionDir(sessionID)
        writerQueue.async { [weak self] in
            _ = box.writer?.finish()
            box.writer = nil
            // The last piece goes out before onFinished, so live text is complete once it drains.
            box.live?.flush()
            box.live = nil
            let finished = MeetingRecorder.combine(sessionID: sessionID, directory: directory)
            guard let self else { return }
            Task { @MainActor in
                self.box = WriterBox(nil)
                self.sources = [:]
                self.sessionID = nil
                self.isLive = false
                self.phase = .idle
                self.onFinished?(finished)
            }
        }
    }

    /// Navo is quitting: close the files so the parts are complete. The next launch joins them.
    func closeForQuit() {
        guard phase == .recording || phase == .paused else { return }
        stopSources()
        let box = self.box
        writerQueue.sync {
            _ = box.writer?.finish()
            box.writer = nil
            box.live = nil
        }
        timer?.invalidate()
        isLive = false
        phase = .idle
    }

    /// Joins the parts of a recording. Also used at launch for recordings interrupted by a quit or crash.
    nonisolated static func combine(sessionID: String, directory: URL) -> Finished {
        let parts = directory.appendingPathComponent("parts", isDirectory: true)
        let output = directory.appendingPathComponent("recording.wav")
        do {
            guard !PartCombiner.parts(in: parts).isEmpty else {
                // Joined already (Navo quit right after joining, before saving): use the recording.
                if let size = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? NSNumber,
                   size.intValue > 44 {
                    let seconds = WAVFile.duration(ofSamples: (size.intValue - 44) / 2)
                    return Finished(sessionID: sessionID, audioURL: output, duration: seconds, error: nil)
                }
                return Finished(sessionID: sessionID, audioURL: nil, duration: 0, error: "Nothing was recorded")
            }
            let duration = try PartCombiner.combine(directory: parts, into: output)
            try? FileManager.default.removeItem(at: parts)
            return Finished(sessionID: sessionID, audioURL: output, duration: duration, error: nil)
        } catch {
            try? FileManager.default.removeItem(at: output)
            return Finished(
                sessionID: sessionID,
                audioURL: nil,
                duration: 0,
                error: "Could not join the recorded parts: \(error.localizedDescription). They are kept in \(parts.path)"
            )
        }
    }

    // MARK: Private

    private func startSources() throws {
        for capture in sources.values {
            try capture.start()
        }
    }

    private func stopSources() {
        for capture in sources.values {
            capture.stop()
        }
    }

    private func show(level: Float, track: RecordingTrack) {
        guard phase == .recording else { return }
        let now = Date()
        if let last = lastLevelUpdate[track], now.timeIntervalSince(last) < 0.1 { return }
        lastLevelUpdate[track] = now
        switch track {
        case .mic: micLevel = level
        case .system:
            systemLevel = level
            if level > 0 { systemHeard = true }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard phase == .recording else { return }
        elapsed += 0.5
        if source.tracks.contains(.system) && !systemHeard {
            systemSilentSeconds += 0.5
        } else {
            systemSilentSeconds = 0
        }
    }
}
