import Foundation

/// How long one piece of work took, and how fast the model was: a dictation, an AI answer, or a
/// meeting or file transcribed. Only numbers and the model's name are kept, never the text.
///
/// Speech is measured by its speed, seconds of audio per second of work (20× means a minute of
/// speech in 3 seconds), so a short and a long recording compare fairly. A language model is
/// measured by the time to its first word (mostly reading the prompt), then its writing speed in
/// tokens a second, and the whole time; and by its tokens: the context window, how much of it a
/// request filled, the sizes in and out, and how many characters fit in a token (how well its
/// tokenizer knows the language, so the same text costs fewer tokens).
struct PerfRecord: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case dictation
        case meeting
        case file
        case writing
        case test

        var title: String {
            switch self {
            case .dictation: return "Dictation"
            case .meeting: return "Meeting"
            case .file: return "File"
            case .writing: return "AI writing"
            case .test: return "Test"
            }
        }

        var icon: String {
            switch self {
            case .dictation: return "mic"
            case .meeting: return "record.circle"
            case .file: return "doc"
            case .writing: return "sparkles"
            case .test: return "checkmark.circle"
            }
        }

        var isSpeech: Bool { self == .dictation || self == .meeting || self == .file }
    }

    let id: String
    var createdAt = Date()
    var kind: Kind
    /// The dictation or session it belongs to.
    var refID: String?
    /// "cohere", "audar", "gemma", "custom-…"
    var model: String
    var modelName: String
    var audioSeconds: Double?
    /// Dictation: from letting go of the key to the text being ready. AI: the whole answer.
    /// Meeting or file: the whole transcription job.
    var totalMs: Int?
    /// Speech requests, as long as they took (waiting in line and loading included).
    var transcribeMs: Int?
    /// The engine's own time on the audio (no waiting, no loading).
    var computeMs: Int?
    var cleanupMs: Int?
    /// The model was asleep and loaded first.
    var loadMs: Int?
    var firstTokenMs: Int?
    var promptTokens: Int?
    var outputTokens: Int?
    /// Writing speed after the first token.
    var tokensPerSecond: Double?
    /// Most of the speech was transcribed while it was spoken.
    var live = false
    /// More to say: the cleanup model, the number of parts.
    var detail: String?
    /// AI: tokens one request could hold (prompt plus answer), and the most the model was made for.
    var contextTokens: Int?
    var modelContextTokens: Int?
    /// AI: the room the answer had, in tokens.
    var maxOutputTokens: Int?
    /// AI: prompt plus answer of the fullest request.
    var fullestTokens: Int?
    /// AI: characters of everything sent and of the answer.
    var inputChars: Int?
    var outputChars: Int?
    /// AI: the text worked on alone (no instructions), in characters and in tokens.
    var textChars: Int?
    var textTokens: Int?
    /// AI: requests it took (a long text is read in parts).
    var requests: Int?
    /// AI: the answer reached its length limit and was cut off.
    var cutOff = false

    init(kind: Kind, model: String, modelName: String) {
        id = UUID().uuidString
        self.kind = kind
        self.model = model
        self.modelName = modelName
    }

    init(
        id: String, createdAt: Date, kind: Kind, refID: String?, model: String, modelName: String,
        audioSeconds: Double?, totalMs: Int?, transcribeMs: Int?, computeMs: Int?, cleanupMs: Int?,
        loadMs: Int?, firstTokenMs: Int?, promptTokens: Int?, outputTokens: Int?,
        tokensPerSecond: Double?, live: Bool, detail: String?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.refID = refID
        self.model = model
        self.modelName = modelName
        self.audioSeconds = audioSeconds
        self.totalMs = totalMs
        self.transcribeMs = transcribeMs
        self.computeMs = computeMs
        self.cleanupMs = cleanupMs
        self.loadMs = loadMs
        self.firstTokenMs = firstTokenMs
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.tokensPerSecond = tokensPerSecond
        self.live = live
        self.detail = detail
    }

    /// Seconds of audio per second of the engine's work (20 means a minute of speech in 3 s).
    var speed: Double? {
        // Live: most of it was transcribed while it was spoken, so the time after does not measure speed.
        guard !live, let audio = audioSeconds, audio > 0 else { return nil }
        let work = computeMs ?? transcribeMs.map { max(0, $0 - (loadMs ?? 0)) }
        guard let work, work > 0 else { return nil }
        return audio / (Double(work) / 1000)
    }

    // MARK: Tokens

    /// How much of the context window the fullest request filled, 0 to 1.
    var contextUsed: Double? {
        Perf.ratio(fullestTokens, contextTokens)
    }

    /// Characters of the text per token: higher means the tokenizer knows the language better.
    var charsPerToken: Double? {
        Perf.ratio(textChars, textTokens)
    }

    var outputCharsPerToken: Double? {
        Perf.ratio(outputChars, outputTokens)
    }

    /// Tokens spent on the instructions and the chat layout, not on the text.
    var instructionTokens: Int? {
        guard let prompt = promptTokens, let text = textTokens, prompt >= text else { return nil }
        return prompt - text
    }

    /// The window was smaller than the model could take: Navo's limit keeps the memory down.
    var windowIsNavos: Bool {
        guard let window = contextTokens, let own = modelContextTokens else { return false }
        return window < own
    }

    /// One line with the numbers that matter for this kind of work.
    var summary: String {
        var parts: [String] = []
        if kind.isSpeech {
            if let audio = audioSeconds { parts.append("\(Perf.seconds(audio)) of audio") }
            if let speed { parts.append("\(Perf.speed(speed)) real time") }
            if kind == .dictation, let total = totalMs {
                parts.append("text ready \(Perf.ms(total)) after you let go")
            } else if let total = totalMs {
                parts.append("done in \(Perf.ms(total))")
            }
            if let cleanup = cleanupMs, cleanup > 0 { parts.append("cleanup \(Perf.ms(cleanup))") }
        } else {
            if let first = firstTokenMs { parts.append("first word \(Perf.ms(first))") }
            if let speed = tokensPerSecond { parts.append("\(Perf.int(speed)) tokens a second") }
            if let total = totalMs { parts.append("\(Perf.ms(total)) in all") }
            if let prompt = promptTokens, let output = outputTokens {
                parts.append("\(Perf.count(prompt)) tokens in, \(Perf.count(output)) out")
            } else if let output = outputTokens {
                parts.append("\(Perf.count(output)) tokens")
            }
            if let used = contextUsed, let window = contextTokens {
                parts.append("\(Perf.percent(used)) of a \(Perf.count(window)) context")
            }
            if cutOff { parts.append("cut off at its length limit") }
        }
        if let load = loadMs, load > 0 { parts.append("model loaded first, \(Perf.ms(load))") }
        return parts.joined(separator: ", ")
    }

    /// Everything measured about an AI answer, a line each: its tokens, then its time.
    var writingBreakdown: String {
        var lines: [String] = []
        if let window = contextTokens {
            var line = "Context window: \(Perf.count(window)) tokens a request, prompt and answer together"
            if let own = modelContextTokens {
                line += windowIsNavos
                    ? " (the model was made for \(Perf.count(own)); Navo keeps it smaller to stay within its memory limit)"
                    : " (all the model was made for)"
            } else {
                line += " (how much the model was made for is not known)"
            }
            lines.append(line + ".")
        }
        if let fullest = fullestTokens, let used = contextUsed {
            let which = (requests ?? 1) > 1 ? "The fullest request" : "This request"
            lines.append("\(which) filled \(Perf.count(fullest)) tokens, \(Perf.percent(used)) of the window.")
        }
        if let prompt = promptTokens {
            var line = "In: \(Perf.count(prompt)) tokens"
            if let chars = inputChars { line += ", \(Perf.count(chars)) characters" }
            if let text = textTokens, let chars = textChars {
                line += ". Your text: \(Perf.count(text)) tokens for \(Perf.count(chars)) characters"
                if let per = charsPerToken { line += " (\(Perf.decimal(per)) characters a token)" }
            }
            if let instructions = instructionTokens { line += "; instructions and layout: \(Perf.count(instructions)) tokens" }
            lines.append(line + ".")
        }
        if let output = outputTokens {
            var line = "Out: \(Perf.count(output)) tokens"
            if let chars = outputChars {
                line += ", \(Perf.count(chars)) characters"
                if let per = outputCharsPerToken { line += " (\(Perf.decimal(per)) a token)" }
            }
            if let room = maxOutputTokens { line += ", of up to \(Perf.count(room)) allowed" }
            if let prompt = promptTokens, prompt > 0 {
                line += ". \(Perf.decimal(Double(output) / Double(prompt) * 100)) tokens out for every 100 in"
            }
            lines.append(line + ".")
        }
        if cutOff { lines.append("The answer was cut off: it reached its length limit.") }
        if let requests, requests > 1 { lines.append("\(requests) requests: a long text read in parts.") }
        var time: [String] = []
        if let first = firstTokenMs { time.append("first word after \(Perf.ms(first))") }
        if let speed = tokensPerSecond { time.append("then \(Perf.decimal(speed)) tokens a second") }
        if let total = totalMs { time.append("\(Perf.ms(total)) in all") }
        if let load = loadMs, load > 0 { time.append("loading the model \(Perf.ms(load))") }
        if !time.isEmpty { lines.append("Time: " + time.joined(separator: ", ") + ".") }
        return lines.joined(separator: "\n")
    }

    /// The breakdown of a dictation's time, for a tooltip.
    var dictationBreakdown: String {
        var lines: [String] = []
        if let total = totalMs { lines.append("Text ready \(Perf.ms(total)) after you let go of the key.") }
        if let transcribe = transcribeMs {
            var line = "Speech to text: \(Perf.ms(transcribe))"
            if live { line += " for the last part (the rest was written while you talked)" }
            if let speed { line += ", \(Perf.speed(speed)) real time" }
            lines.append(line + ".")
        }
        if let cleanup = cleanupMs, cleanup > 0 { lines.append("Cleanup: \(Perf.ms(cleanup))" + (detail.map { ", \($0)" } ?? "") + ".") }
        if let load = loadMs, load > 0 { lines.append("The model was asleep and loaded first: \(Perf.ms(load)).") }
        if let audio = audioSeconds { lines.append("You spoke for \(Perf.seconds(audio)).") }
        return lines.joined(separator: "\n")
    }
}

/// Number formats for the measurements.
enum Perf {
    static func ms(_ value: Int) -> String {
        value < 1000 ? "\(value) ms" : String(format: "%.1f s", Double(value) / 1000)
    }

    static func seconds(_ value: Double) -> String {
        value < 60 ? String(format: "%.1f s", value) : String(format: "%d:%02d min", Perf.int(value.rounded(.down)) / 60, Perf.int(value.rounded(.down)) % 60)
    }

    static func speed(_ value: Double) -> String {
        value >= 10 ? "\(int(value))×" : String(format: "%.1f×", value)
    }

    /// A whole number, safe for any double (infinity or NaN would stop the app in Int()).
    static func int(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), -1e15), 1e15))
    }

    /// `part` / `whole`, or nil when either is missing or the whole is zero.
    static func ratio(_ part: Int?, _ whole: Int?) -> Double? {
        guard let part, let whole, whole > 0, part >= 0 else { return nil }
        return Double(part) / Double(whole)
    }

    private static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// 6144 as "6,144".
    static func count(_ value: Int) -> String {
        grouped.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 6144 as "6.1K", 131072 as "131K": for the big figures.
    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1000: return "\(value)"
        case ..<10000: return String(format: "%.1fK", Double(value) / 1000)
        case ..<1_000_000: return "\(value / 1000)K"
        default: return String(format: "%.1fM", Double(value) / 1_000_000)
        }
    }

    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "–" }
        let value = fraction * 100
        return value > 0 && value < 1 ? "<1%" : "\(int(value))%"
    }

    /// 3.456 as "3.5", 37.2 as "37".
    static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        return value >= 10 ? "\(int(value))" : String(format: "%.1f", value)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// The measurements: saved in the database and summed up per model for the Performance page.
@MainActor
final class MetricsStore: ObservableObject {
    /// How long measurements are kept.
    static let keepDays = 90
    private static let memoryLimit = 3000

    /// Newest first.
    @Published private(set) var recent: [PerfRecord] = []
    private var byRef: [String: PerfRecord] = [:]
    private let db: Database?

    init(db: Database?) {
        self.db = db
        prune()
    }

    func record(_ record: PerfRecord) {
        do {
            try db?.saveMetric(record)
        } catch {
            ProblemLog.shared.report("Measurements", "Could not save a measurement: \(error.localizedDescription)", once: true)
        }
        recent.insert(record, at: 0)
        if recent.count > Self.memoryLimit { recent.removeLast(recent.count - Self.memoryLimit) }
        if let ref = record.refID { byRef[ref] = record }
    }

    /// The measurement of a dictation or session, if there is one.
    func record(for refID: String) -> PerfRecord? {
        byRef[refID]
    }

    /// Drops measurements older than `keepDays`, and those of dictations and recordings that were deleted.
    func prune() {
        do {
            try db?.pruneMetrics(before: Date().addingTimeInterval(-Double(Self.keepDays) * 86_400))
        } catch {
            ProblemLog.shared.report("Measurements", "Could not drop old measurements: \(error.localizedDescription)", once: true)
        }
        reload()
    }

    func clear() {
        try? db?.deleteAllMetrics()
        reload()
    }

    private func reload() {
        do {
            recent = try db?.metrics(limit: Self.memoryLimit) ?? []
        } catch {
            recent = []
            ProblemLog.shared.report("Measurements", "Could not read the measurements: \(error.localizedDescription)", once: true)
        }
        var map: [String: PerfRecord] = [:]
        for record in recent.reversed() {
            if let ref = record.refID { map[ref] = record }
        }
        byRef = map
    }

    // MARK: Summaries

    struct SpeechSummary: Identifiable {
        let model: String
        let name: String
        let count: Int
        let speed: Double?
        let waitMs: Double?
        let cleanupMs: Double?
        let loadMs: Double?
        var id: String { model }
    }

    struct WritingSummary: Identifiable {
        let model: String
        let name: String
        let count: Int
        let firstTokenMs: Double?
        let tokensPerSecond: Double?
        let totalMs: Double?
        let loadMs: Double?
        /// The latest window, and the most the model was made for.
        let contextTokens: Int?
        let modelContextTokens: Int?
        /// Typical tokens in and out of an answer, and how full the window was.
        let promptTokens: Double?
        let outputTokens: Double?
        let contextUsed: Double?
        /// Characters of your text per token.
        let charsPerToken: Double?
        let cutOffs: Int
        var id: String { model }
    }

    /// Typical figures of each speech engine (the middle value, so one odd run does not count much).
    var speechSummaries: [SpeechSummary] {
        Dictionary(grouping: recent.filter { $0.kind.isSpeech }, by: \.model).map { model, records in
            let dictations = records.filter { $0.kind == .dictation }
            // The usual wait: a model waking up has its own figure, so those runs are left out here.
            let warm = dictations.filter { ($0.loadMs ?? 0) == 0 }
            return SpeechSummary(
                model: model,
                name: records.first?.modelName ?? model,
                count: records.count,
                speed: Perf.median(records.compactMap(\.speed)),
                waitMs: Perf.median((warm.isEmpty ? dictations : warm).compactMap(\.totalMs).map(Double.init)),
                cleanupMs: Perf.median(dictations.compactMap(\.cleanupMs).filter { $0 > 0 }.map(Double.init)),
                loadMs: Perf.median(records.compactMap(\.loadMs).filter { $0 > 0 }.map(Double.init))
            )
        }
        .sorted { $0.count > $1.count }
    }

    var writingSummaries: [WritingSummary] {
        Dictionary(grouping: recent.filter { !$0.kind.isSpeech }, by: \.model)
            .map { Self.writingSummary(model: $0.key, records: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private static func writingSummary(model: String, records: [PerfRecord]) -> WritingSummary {
        func median(_ values: [Int]) -> Double? { Perf.median(values.map(Double.init)) }
        let firstToken = median(records.compactMap(\.firstTokenMs))
        let speed = Perf.median(records.compactMap(\.tokensPerSecond))
        let total = median(records.compactMap(\.totalMs))
        let load = median(records.compactMap(\.loadMs).filter { $0 > 0 })
        let window = records.lazy.compactMap(\.contextTokens).first
        let own = records.lazy.compactMap(\.modelContextTokens).first
        let prompt = median(records.compactMap(\.promptTokens))
        let output = median(records.compactMap(\.outputTokens))
        let used = Perf.median(records.compactMap(\.contextUsed))
        let perToken = Perf.median(records.compactMap(\.charsPerToken))
        return WritingSummary(
            model: model,
            name: records.first?.modelName ?? model,
            count: records.count,
            firstTokenMs: firstToken,
            tokensPerSecond: speed,
            totalMs: total,
            loadMs: load,
            contextTokens: window,
            modelContextTokens: own,
            promptTokens: prompt,
            outputTokens: output,
            contextUsed: used,
            charsPerToken: perToken,
            cutOffs: records.filter(\.cutOff).count
        )
    }
}
