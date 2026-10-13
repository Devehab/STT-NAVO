import Foundation

/// What live dictation has heard so far: the phrases that are done, and the one still being said.
struct LiveText: Equatable {
    /// Finished phrases, transcribed once each. They do not change any more.
    var settled = ""
    /// The phrase being spoken right now. It is transcribed again as it grows, so it may change.
    var preview = ""

    var isEmpty: Bool { settled.isEmpty && preview.isEmpty }
}

/// Transcribes a dictation while it is being spoken.
///
/// Every half second it looks at the audio not sent yet. When a phrase has ended (a real pause
/// of at least 350 ms, found the same way meetings are cut, so a word is never split), that phrase
/// is sent to the speech engine once and its text is settled. Between pauses, the phrase still
/// being said is sent again every second or so for a preview line. One request is out at a time,
/// and if previews come back too slowly for this Mac and engine, they stop and only finished
/// phrases are sent.
///
/// When the key is let go, a long dictation only needs its last phrase transcribed, so the text
/// is in almost at once. A short one (`fullPassSeconds` or less) is transcribed again in one go
/// as before, so its accuracy does not change at all. Anything that goes wrong here falls back
/// to that full transcription: live text is never worse than before, only faster.
@MainActor
final class LiveDictation {
    static let fullPassSeconds = 30.0
    private static let rate = Double(AudioRecorder.sampleRate)
    private static let tick: UInt64 = 500_000_000
    /// Unsent audio needed before looking for the end of a phrase.
    private static let phraseSeconds = 2.5
    /// A phrase is at least this long (short pauses inside a sentence do not cut it).
    private static let shortestPhrase = 1.5
    private static let pauseSeconds = 0.35
    /// With no pause at all, the phrase is cut anyway before the model's 30 second window fills.
    private static let longestPhrase = 24.0
    private static let previewEvery = 0.6
    private static let shortestPreview = 0.8
    /// A preview slower than this means this Mac and engine cannot keep up: previews stop.
    private static let slowPreview = 2.5

    /// Sends one piece of audio (a WAV file) to the speech engine.
    typealias Transcribe = @MainActor (URL) async throws -> TranscriptionClient.Result

    var onChange: ((LiveText) -> Void)?
    private(set) var text = LiveText() {
        didSet { if text != oldValue { onChange?(text) } }
    }
    /// The engine backend reported by the requests ("mlx"), for the history.
    private(set) var backend: String?

    private let recorder: AudioRecorder
    private let transcribe: Transcribe
    private var loop: Task<Void, Never>?
    /// Sample where the audio not settled yet begins.
    private var cut = 0
    private var phrases: [String] = []
    private var busy = false
    private var failed = false
    private var previews = true
    private var previewedUpTo = 0

    init(recorder: AudioRecorder, transcribe: @escaping Transcribe) {
        self.recorder = recorder
        self.transcribe = transcribe
    }

    func start() {
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: LiveDictation.tick)
                guard let self, !Task.isCancelled else { return }
                await self.step()
            }
        }
    }

    /// The recording was thrown away.
    func cancel() {
        loop?.cancel()
        loop = nil
    }

    /// The whole text from the live phrases plus the last one, or nil when the dictation should be
    /// transcribed in one go instead (short, or something went wrong while it was live).
    func finish(samples: [Float]) async -> TranscriptionClient.Result? {
        loop?.cancel()
        loop = nil
        while busy {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let seconds = Double(samples.count) / Self.rate
        guard !failed, seconds > Self.fullPassSeconds, cut <= samples.count else { return nil }
        var all = phrases
        let rest = Array(samples[cut...])
        if rest.count > Int(0.3 * Self.rate) && !SmartCut.isSilent(rest) {
            guard let last = await send(rest) else { return nil }
            if !last.text.isEmpty { all.append(last.text) }
        }
        let joined = all.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionClient.Result(text: joined, backend: backend, processingMs: nil, duration: seconds)
    }

    // MARK: Work

    private func step() async {
        guard !busy else { return }
        let total = recorder.sampleCount
        let unsent = total - cut
        if Double(unsent) >= Self.phraseSeconds * Self.rate, let end = phraseEnd(total: total) {
            await settle(upTo: end)
            return
        }
        guard previews,
              Double(unsent) >= Self.shortestPreview * Self.rate,
              Double(total - previewedUpTo) >= Self.previewEvery * Self.rate
        else { return }
        await preview(total: total)
    }

    /// Where the phrase that just ended stops: inside the latest pause, or forced when it is long.
    private func phraseEnd(total: Int) -> Int? {
        let base = max(0, cut - SmartCut.context)
        let audio = recorder.samples(from: base)
        let lo = cut - base + Int(Self.shortestPhrase * Self.rate)
        let hi = audio.count - Int(0.15 * Self.rate)
        guard hi > lo else { return nil }
        if let point = SmartCut.findPause(in: audio, lo: lo, hi: hi, target: hi, minimumSeconds: Self.pauseSeconds) {
            return base + point
        }
        if Double(audio.count - (cut - base)) >= Self.longestPhrase * Self.rate {
            return base + SmartCut.findCut(in: audio, lo: lo, hi: hi, target: hi)
        }
        return nil
    }

    private func settle(upTo end: Int) async {
        let start = cut
        let audio = recorder.samples(from: start)
        let piece = Array(audio.prefix(max(0, end - start)))
        cut = end
        previewedUpTo = end
        busy = true
        defer { busy = false }
        guard !SmartCut.isSilent(piece) else {
            text.preview = ""
            return
        }
        guard let result = await send(piece) else {
            // The full transcription takes over when the key is let go.
            failed = true
            loop?.cancel()
            return
        }
        if !result.text.isEmpty {
            phrases.append(result.text)
        }
        text = LiveText(settled: phrases.joined(separator: " "), preview: "")
    }

    private func preview(total: Int) async {
        let start = cut
        let audio = recorder.samples(from: start)
        previewedUpTo = total
        guard !SmartCut.isSilent(audio) else { return }
        busy = true
        defer { busy = false }
        let began = Date()
        let result = await send(audio)
        if Date().timeIntervalSince(began) > Self.slowPreview {
            previews = false
        }
        // A phrase settled meanwhile: this preview is out of date.
        guard let result, cut == start else { return }
        text.preview = result.text
    }

    private func send(_ samples: [Float]) async -> TranscriptionClient.Result? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("navo-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try WAVWriter.write(samples: samples, sampleRate: Int(Self.rate), to: url)
            let result = try await transcribe(url)
            if backend == nil { backend = result.backend }
            return result
        } catch {
            return nil
        }
    }
}
