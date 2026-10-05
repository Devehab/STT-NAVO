import Foundation

/// An answer, and what wrote it.
struct AIAnswer {
    let text: String
    let model: WritingModel
    /// Something worth saying next to the answer (a long text read in parts, another model used).
    let note: String?
    /// Speed and memory of the request, to show that it stayed within the limit.
    let stats: String?
}

/// Summaries and rewrites of transcripts with a language model on this Mac (Gemma or Llama),
/// through the local Navo engine. Nothing is sent anywhere. While a language model writes, the
/// speech models are out of memory (the engine keeps one kind loaded at a time), and they come
/// back by themselves the next time you dictate or transcribe.
@MainActor
final class AIWriter: ObservableObject {
    /// Answers kept while Navo runs, so opening the same text again shows them right away.
    private static let cacheLimit = 60

    private let settings: AppSettings
    /// The local engine the models run in (the AI panel follows its downloads).
    let engine: LocalEngineManager
    private var cache: [String: AIAnswer] = [:]

    init(settings: AppSettings, engine: LocalEngineManager) {
        self.settings = settings
        self.engine = engine
        LegacyGemini.erase()
    }

    // MARK: Models

    func isDownloaded(_ model: WritingModel) -> Bool {
        engine.isDownloaded(model)
    }

    /// The model that will write: the chosen one, or the other one when only that is downloaded.
    var readyModel: WritingModel? {
        if isDownloaded(settings.writingModel) { return settings.writingModel }
        return WritingModel.allCases.first { isDownloaded($0) }
    }

    /// The AI panel closed: the language model leaves memory now instead of a minute later.
    func finished() {
        engine.unloadWritingModels()
    }

    // MARK: Writing

    struct TestResult {
        let reply: String
        let seconds: Double
        let stats: String?
    }

    /// A tiny request that proves the model loads and answers, with its speed and memory.
    func test(_ model: WritingModel) async throws -> TestResult {
        try await ensureEngine()
        guard isDownloaded(model) else { throw notDownloaded(model) }
        let started = Date()
        let answer = try await client(model).write(
            system: "Reply with one short friendly sentence.",
            user: "Say that you are ready to write.",
            temperature: 0.2,
            maxTokens: 40
        )
        let result = TestResult(reply: answer.text, seconds: Date().timeIntervalSince(started), stats: stats(answer))
        engine.unloadWritingModels()
        return result
    }

    /// Makes `action` from `text`. A text longer than the model reads at once is read in parts
    /// first. `fresh` writes again instead of reusing the last answer; `onStatus` hears what is
    /// going on, `onText` the answer so far while it is written.
    func run(
        _ action: WritingAction,
        on text: String,
        language: OutputLanguage,
        fresh: Bool = false,
        onStatus: (@MainActor @Sendable (String) -> Void)? = nil,
        onText: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> AIAnswer {
        try await ensureEngine()
        guard let model = readyModel else { throw notDownloaded(settings.writingModel) }
        let key = [action.rawValue, language.rawValue, model.rawValue, String(text.hashValue)].joined(separator: "|")
        if !fresh, let cached = cache[key] {
            return cached
        }
        var notes: [String] = []
        if model != settings.writingModel {
            notes.append("Written with \(model.shortName): \(settings.writingModel.shortName) is not downloaded.")
        }

        onStatus?("Getting \(model.shortName) ready. The speech models step out of memory while it writes.")
        var limit = action.partLimit
        var written: WritingClient.Answer
        var partCount = 1
        while true {
            do {
                (written, partCount) = try await write(action, text: text, language: language, model: model, limit: limit, onStatus: onStatus, onText: onText)
                break
            } catch let failure as WritingClient.Failure where failure.tooLong && limit > 800 {
                // Text that takes more tokens than usual (rare scripts, long codes): smaller parts.
                limit /= 2
            }
        }
        if partCount > 1 {
            notes.append("A long text: \(model.shortName) read it in \(partCount) parts.")
        }
        var result = written.text
        if written.finishReason == "length" {
            result += "\n\n(The answer was cut off here: it reached its length limit.)"
        }
        let answer = AIAnswer(text: result, model: model, note: notes.isEmpty ? nil : notes.joined(separator: " "), stats: stats(written))
        if cache.count >= Self.cacheLimit {
            cache.removeAll()
        }
        cache[key] = answer
        return answer
    }

    /// One request for a text that fits; for a longer one, notes of each part and then the answer
    /// from the notes (a clean rewrite is done part by part instead, since it keeps every word).
    private func write(
        _ action: WritingAction,
        text: String,
        language: OutputLanguage,
        model: WritingModel,
        limit: Int,
        onStatus: (@MainActor @Sendable (String) -> Void)?,
        onText: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> (WritingClient.Answer, Int) {
        let client = client(model)
        let parts = TextParts.split(text, limit: limit)
        guard parts.count > 1 else {
            let answer = try await client.write(
                system: action.instructions(language: language),
                user: parts.first ?? text,
                temperature: action.temperature,
                maxTokens: action.maxTokens,
                onText: onText
            )
            return (answer, 1)
        }

        if action == .tidy {
            var whole = WritingClient.Answer(text: "")
            for (index, part) in parts.enumerated() {
                onStatus?("Rewriting part \(index + 1) of \(parts.count)…")
                let before = whole.text
                let piece = try await client.write(
                    system: action.instructions(language: language),
                    user: part,
                    temperature: action.temperature,
                    maxTokens: action.maxTokens
                ) { soFar in
                    onText?(before.isEmpty ? soFar : before + "\n\n" + soFar)
                }
                whole.text = before.isEmpty ? piece.text : before + "\n\n" + piece.text
                whole.merge(piece)
            }
            return (whole, parts.count)
        }

        // Notes of every part, then notes of the notes while they are still too long to read at once.
        var material = parts
        var round = 1
        while material.count > 1 {
            var notes: [String] = []
            for (index, part) in material.enumerated() {
                onStatus?(round == 1
                    ? "Reading part \(index + 1) of \(material.count)…"
                    : "Putting the notes together, \(index + 1) of \(material.count)…")
                let taken = try await client.write(
                    system: WritingAction.notesInstructions,
                    user: part,
                    temperature: 0.2,
                    maxTokens: 500
                )
                notes.append(taken.text)
            }
            let joined = notes.joined(separator: "\n")
            let next = TextParts.split(joined, limit: limit)
            // Notes that did not get shorter would never end: write from what fits.
            material = next.count < material.count ? next : [String(joined.prefix(limit))]
            round += 1
        }
        onStatus?("Writing the \(action.title.lowercased())…")
        let answer = try await client.write(
            system: action.instructions(language: language, fromNotes: true),
            user: material.first ?? "",
            temperature: action.temperature,
            maxTokens: action.maxTokens,
            onText: onText
        )
        return (answer, parts.count)
    }

    // MARK: Engine

    private func client(_ model: WritingModel) -> WritingClient {
        WritingClient(baseURL: engine.baseURL(for: model))
    }

    private func notDownloaded(_ model: WritingModel) -> WritingClient.Failure {
        WritingClient.Failure(message: "\(model.title) is not downloaded yet. Download it in Settings > AI writing.", status: 503)
    }

    /// AI writing runs in the local engine: start it when it is stopped.
    private func ensureEngine() async throws {
        guard engine.isInstalled else {
            throw WritingClient.Failure(message: "Install the local engine in Settings first: AI writing runs in it, on this Mac.")
        }
        if engine.isRunning { return }
        engine.start()
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 200_000_000)
            if engine.isRunning { return }
            if case .failed(let message) = engine.state {
                throw WritingClient.Failure(message: message)
            }
        }
        throw WritingClient.Failure(message: "The local engine did not start. Open Settings > Speech engines to see why.")
    }

    /// Speed, and the memory the models process used: the larger of what MLX reports as its
    /// peak for the answer and what macOS counts for the process now, with the model loaded.
    private func stats(_ answer: WritingClient.Answer) -> String? {
        var parts: [String] = []
        if let speed = answer.tokensPerSecond, speed > 0 {
            parts.append("\(Int(speed.rounded())) tokens a second")
        }
        let memory = max(UInt64(max(0, answer.peakMemoryBytes ?? 0)), engine.modelsMemory ?? 0)
        if memory > 0 {
            parts.append("\(ProcessMemory.format(memory)) of memory")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

private extension WritingClient.Answer {
    /// Adds the figures of the next part of the same answer.
    mutating func merge(_ other: WritingClient.Answer) {
        finishReason = other.finishReason
        promptTokens += other.promptTokens
        completionTokens += other.completionTokens
        tokensPerSecond = other.tokensPerSecond ?? tokensPerSecond
        peakMemoryBytes = max(peakMemoryBytes ?? 0, other.peakMemoryBytes ?? 0)
    }
}
