import Foundation

/// One recording or file in a request about several: its title and date line, and its text.
struct AIDocument: Sendable, Equatable {
    let heading: String
    let text: String
}

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
    private let metrics: MetricsStore?
    private var cache: [String: AIAnswer] = [:]

    init(settings: AppSettings, engine: LocalEngineManager, metrics: MetricsStore? = nil) {
        self.settings = settings
        self.engine = engine
        self.metrics = metrics
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
        try await logged("Testing \(model.title)") {
            try await ensureEngine()
            guard isDownloaded(model) else { throw notDownloaded(model) }
            let started = Date()
            let answer = try await client(model).write(
                system: "Reply with one short friendly sentence.",
                user: "Say that you are ready to write.",
                temperature: 0.2,
                maxTokens: 40
            )
            record(answer, model: model, kind: .test, started: started, detail: "the test sentence")
            let result = TestResult(reply: answer.text, seconds: Date().timeIntervalSince(started), stats: stats(answer))
            engine.unloadWritingModels()
            return result
        }
    }

    /// Runs `body`; a failure goes to the problems log on its way to the caller (who shows it).
    private func logged<T>(_ what: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ProblemLog.shared.report("AI writing", "\(what): \(error.localizedDescription)")
            throw error
        }
    }

    /// Makes `action` from `text`. A text longer than the model reads at once is read in parts
    /// first. `fresh` writes again instead of reusing the last answer; `onStatus` hears what is
    /// going on, `onText` the answer so far while it is written.
    /// With `documents` (several recordings or files, oldest first), `text` is all of them and
    /// the model reads them as separate transcripts.
    func run(
        _ action: WritingAction,
        on text: String,
        documents: [AIDocument] = [],
        language: OutputLanguage,
        fresh: Bool = false,
        onStatus: (@MainActor @Sendable (String) -> Void)? = nil,
        onText: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> AIAnswer {
        try await logged(action.title) {
            try await write(action, on: text, documents: documents, language: language, fresh: fresh, onStatus: onStatus, onText: onText)
        }
    }

    private func write(
        _ action: WritingAction,
        on text: String,
        documents: [AIDocument],
        language: OutputLanguage,
        fresh: Bool,
        onStatus: (@MainActor @Sendable (String) -> Void)?,
        onText: (@MainActor @Sendable (String) -> Void)?
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
        let started = Date()
        var limit = action.partLimit
        var written: WritingClient.Answer
        var partCount = 1
        while true {
            do {
                if documents.count > 1 {
                    (written, partCount) = try await writeSeveral(action, documents: documents, language: language, model: model, limit: limit, onStatus: onStatus, onText: onText)
                } else {
                    (written, partCount) = try await write(action, text: text, language: language, model: model, limit: limit, onStatus: onStatus, onText: onText)
                }
                break
            } catch let failure as WritingClient.Failure where failure.tooLong && limit > 800 {
                // Text that takes more tokens than usual (rare scripts, long codes): smaller parts.
                limit /= 2
                ProblemLog.shared.report(
                    "AI writing",
                    "\(model.title): a part did not fit the context window (\(failure.message)) Navo read the text in smaller parts and went on.",
                    once: true
                )
            }
        }
        if documents.count > 1 {
            notes.append("\(documents.count) transcripts, oldest first\(partCount > 1 ? ": \(model.shortName) took \(partCount) requests" : "").")
        } else if partCount > 1 {
            notes.append("A long text: \(model.shortName) read it in \(partCount) parts.")
        }
        let several = documents.count > 1 ? ", \(documents.count) transcripts" : ""
        record(written, model: model, kind: .writing, started: started,
               detail: action.title + several + (partCount > 1 ? ", \(partCount) requests" : ""))
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
            var whole: WritingClient.Answer?
            for (index, part) in parts.enumerated() {
                onStatus?("Rewriting part \(index + 1) of \(parts.count)…")
                let before = whole?.text ?? ""
                let piece = try await client.write(
                    system: action.instructions(language: language),
                    user: part,
                    temperature: action.temperature,
                    maxTokens: action.maxTokens
                ) { soFar in
                    onText?(before.isEmpty ? soFar : before + "\n\n" + soFar)
                }
                if whole == nil { whole = piece } else { whole?.merge(piece) }
                whole?.text = before.isEmpty ? piece.text : before + "\n\n" + piece.text
            }
            return (whole ?? WritingClient.Answer(text: ""), parts.count)
        }

        // Notes of every part, then notes of the notes while they are still too long to read at once.
        // Their tokens count too: the answer's figures are those of every request it took.
        var spent: WritingClient.Answer?
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
                if spent == nil { spent = taken } else { spent?.merge(taken) }
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
        guard var whole = spent else { return (answer, parts.count) }
        whole.merge(answer)
        whole.text = answer.text
        return (whole, parts.count)
    }

    /// Several transcripts, oldest first. All of them in one request when they fit; otherwise
    /// notes of each one (part by part when it is long), headed by its title and date, then the
    /// answer from the notes. A clean rewrite keeps each one apart: its heading, then its text
    /// rewritten part by part. Returns the answer and how many requests it took.
    private func writeSeveral(
        _ action: WritingAction,
        documents: [AIDocument],
        language: OutputLanguage,
        model: WritingModel,
        limit: Int,
        onStatus: (@MainActor @Sendable (String) -> Void)?,
        onText: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> (WritingClient.Answer, Int) {
        let client = client(model)
        var spent: WritingClient.Answer?
        var requests = 0
        func count(_ answer: WritingClient.Answer) {
            requests += 1
            if spent == nil { spent = answer } else { spent?.merge(answer) }
        }

        if action == .tidy {
            var written = ""
            for (index, document) in documents.enumerated() {
                let parts = TextParts.split(document.text, limit: limit)
                var body = ""
                for (partIndex, part) in parts.enumerated() {
                    onStatus?("Rewriting \(index + 1) of \(documents.count)" + (parts.count > 1 ? ", part \(partIndex + 1) of \(parts.count)" : "") + "…")
                    let before = (written.isEmpty ? "" : written + "\n\n\n") + document.heading + "\n\n" + (body.isEmpty ? "" : body + "\n\n")
                    let piece = try await client.write(
                        system: action.instructions(language: language),
                        user: part,
                        temperature: action.temperature,
                        maxTokens: action.maxTokens
                    ) { soFar in
                        onText?(before + soFar)
                    }
                    body += (body.isEmpty ? "" : "\n\n") + piece.text
                    count(piece)
                }
                written += (written.isEmpty ? "" : "\n\n\n") + document.heading + "\n\n" + body
            }
            var whole = spent ?? WritingClient.Answer(text: "")
            whole.text = written
            return (whole, requests)
        }

        let joined = documents.map { "\($0.heading)\n\n\($0.text)" }.joined(separator: "\n\n\n")
        if joined.count <= limit {
            let answer = try await client.write(
                system: action.instructions(language: language, several: documents.count),
                user: joined,
                temperature: action.temperature,
                maxTokens: action.maxTokens,
                onText: onText
            )
            return (answer, 1)
        }

        // Notes of each one, so none is lost among the others, each headed by its title and date.
        var notes: [String] = []
        for (index, document) in documents.enumerated() {
            let parts = TextParts.split(document.text, limit: max(400, limit - document.heading.count - 2))
            var taken: [String] = []
            for (partIndex, part) in parts.enumerated() {
                onStatus?("Reading \(index + 1) of \(documents.count)" + (parts.count > 1 ? ", part \(partIndex + 1) of \(parts.count)" : "") + "…")
                let answer = try await client.write(
                    system: WritingAction.notesInstructions,
                    user: document.heading + "\n\n" + part,
                    temperature: 0.2,
                    maxTokens: 500
                )
                taken.append(answer.text)
                count(answer)
            }
            notes.append(document.heading + "\n" + taken.joined(separator: "\n"))
        }

        // Notes of the notes while they are still too long to read at once.
        var material = TextParts.split(notes.joined(separator: "\n\n"), limit: limit)
        var round = 1
        while material.count > 1 {
            var shorter: [String] = []
            for (index, part) in material.enumerated() {
                onStatus?("Putting the notes together, \(index + 1) of \(material.count)…")
                let answer = try await client.write(
                    system: WritingAction.notesInstructions,
                    user: part,
                    temperature: 0.2,
                    maxTokens: 500
                )
                shorter.append(answer.text)
                count(answer)
            }
            let joinedNotes = shorter.joined(separator: "\n")
            let next = TextParts.split(joinedNotes, limit: limit)
            material = next.count < material.count ? next : [String(joinedNotes.prefix(limit))]
            round += 1
        }
        onStatus?("Writing the \(action.title.lowercased()) of all \(documents.count)…")
        let answer = try await client.write(
            system: action.instructions(language: language, fromNotes: true, several: documents.count),
            user: material.first ?? "",
            temperature: action.temperature,
            maxTokens: action.maxTokens,
            onText: onText
        )
        count(answer)
        var whole = spent ?? answer
        whole.text = answer.text
        whole.finishReason = answer.finishReason
        return (whole, requests)
    }

    // MARK: Size

    /// What a request will take, worked out before it is sent: the text's tokens (estimated from
    /// how many characters this model fits in a token, measured on your own answers when there
    /// are some), the room one request has, and so how many requests it takes.
    struct Plan: Equatable {
        let tokens: Int
        let window: Int
        let requests: Int
        /// Rough, from this model's measured speed.
        let seconds: Double
        let modelName: String

        var fitsAtOnce: Bool { requests == 1 }
    }

    func plan(_ action: WritingAction, text: String, documents: [AIDocument], isArabic: Bool) -> Plan {
        let model = readyModel ?? settings.writingModel
        let measured = metrics?.writingSummaries.first { $0.model == model.rawValue }
        let window = engine.llms[model]?.windowTokens ?? measured?.contextTokens ?? 6_144
        let perToken = measured?.charsPerToken ?? (isArabic ? 3.0 : 4.2)
        let tokens = Int((Double(text.count) / max(1, perToken)).rounded())
        let limit = action.partLimit

        // The same cuts the writer makes.
        var notesRequests = 0
        var finalRequests = 1
        if action == .tidy {
            let texts = documents.count > 1 ? documents.map(\.text) : [text]
            finalRequests = texts.reduce(0) { $0 + max(1, TextParts.split($1, limit: limit).count) }
        } else if documents.count > 1 {
            let joinedCount = documents.reduce(0) { $0 + $1.heading.count + $1.text.count + 3 }
            if joinedCount > limit {
                notesRequests = documents.reduce(0) { $0 + max(1, TextParts.split($1.text, limit: max(400, limit - $1.heading.count - 2)).count) }
            }
        } else {
            let parts = TextParts.split(text, limit: limit).count
            if parts > 1 { notesRequests = parts }
        }
        // Notes are about 1,500 characters a part: more than a request holds means another round.
        if notesRequests > 0 {
            let notesChars = notesRequests * 1_500
            if notesChars > limit { notesRequests += Int((Double(notesChars) / Double(limit)).rounded(.up)) }
        }
        let speed = measured?.tokensPerSecond ?? 25
        let readSpeed = 400.0 // tokens of prompt a second, roughly, on Apple silicon
        let notesSeconds = Double(notesRequests) * (Double(limit) / perToken / readSpeed + 250 / speed)
        let finalSeconds = Double(finalRequests) * (Double(min(tokens, Int(Double(limit) / perToken))) / readSpeed + Double(action.maxTokens) * 0.5 / speed)
        return Plan(
            tokens: tokens,
            window: window,
            requests: notesRequests + finalRequests,
            seconds: notesSeconds + finalSeconds,
            modelName: model.shortName
        )
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

    /// Keeps the figures of an answer for the Performance page.
    private func record(_ answer: WritingClient.Answer, model: WritingModel, kind: PerfRecord.Kind, started: Date, detail: String) {
        var record = PerfRecord(kind: kind, model: model.rawValue, modelName: model.title)
        record.totalMs = Int(Date().timeIntervalSince(started) * 1000)
        record.firstTokenMs = answer.firstTokenMs
        record.tokensPerSecond = answer.decodeTokensPerSecond ?? answer.tokensPerSecond
        record.promptTokens = answer.promptTokens > 0 ? answer.promptTokens : nil
        record.outputTokens = answer.completionTokens > 0 ? answer.completionTokens : nil
        record.loadMs = answer.loadMs
        record.detail = detail
        record.contextTokens = answer.contextTokens
        record.modelContextTokens = answer.modelContextTokens
        record.maxOutputTokens = answer.maxOutputTokens
        record.fullestTokens = answer.fullestTokens
        record.inputChars = answer.inputChars
        record.outputChars = answer.outputChars
        record.textChars = answer.textChars
        record.textTokens = answer.textTokens
        record.requests = answer.requests
        record.cutOff = answer.finishReason == "length"
        metrics?.record(record)
        // A figure the engine could not give: the answer is fine, the measurement is not complete.
        for problem in answer.problems {
            ProblemLog.shared.report("Measurements", "\(model.title): \(problem)", once: true)
        }
    }

    /// Time to the first word, writing speed, the whole time, and the memory the models process
    /// used: the larger of what MLX reports as its peak for the answer and what macOS counts for
    /// the process now, with the model loaded.
    private func stats(_ answer: WritingClient.Answer) -> String? {
        var parts: [String] = []
        if let first = answer.firstTokenMs {
            var text = "first word after \(Perf.ms(first))"
            if let load = answer.loadMs, load > 0 { text += " (loading \(Perf.ms(load)))" }
            parts.append(text)
        }
        if let speed = answer.decodeTokensPerSecond ?? answer.tokensPerSecond, speed > 0 {
            parts.append("then \(Perf.int(speed)) tokens a second")
        }
        if let total = answer.totalMs {
            parts.append("\(Perf.ms(total)) in all")
        }
        if answer.promptTokens > 0 {
            var tokens = "\(Perf.count(answer.promptTokens)) tokens in, \(Perf.count(answer.completionTokens)) out"
            if let window = answer.contextTokens, let fullest = answer.fullestTokens, let used = Perf.ratio(fullest, window) {
                tokens += " (\(Perf.percent(used)) of a \(Perf.count(window)) context)"
            }
            parts.append(tokens)
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
        firstTokenMs = firstTokenMs ?? other.firstTokenMs
        decodeTokensPerSecond = other.decodeTokensPerSecond ?? decodeTokensPerSecond
        loadMs = max(loadMs ?? 0, other.loadMs ?? 0)
        totalMs = (totalMs ?? 0) + (other.totalMs ?? 0)
        contextTokens = other.contextTokens ?? contextTokens
        modelContextTokens = other.modelContextTokens ?? modelContextTokens
        maxOutputTokens = other.maxOutputTokens ?? maxOutputTokens
        inputChars = Self.sum(inputChars, other.inputChars)
        outputChars = Self.sum(outputChars, other.outputChars)
        textChars = Self.sum(textChars, other.textChars)
        textTokens = Self.sum(textTokens, other.textTokens)
        requests += other.requests
        fullestTokens = [fullestTokens, other.fullestTokens].compactMap { $0 }.max()
        problems += other.problems.filter { !problems.contains($0) }
    }

    private static func sum(_ a: Int?, _ b: Int?) -> Int? {
        guard a != nil || b != nil else { return nil }
        return (a ?? 0) + (b ?? 0)
    }
}
