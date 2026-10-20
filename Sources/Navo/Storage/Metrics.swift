import Foundation

/// How long one piece of work took, and how fast the model was: a dictation, an AI answer, or a
/// meeting or file transcribed. Only numbers and the model's name are kept, never the text.
///
/// Speech is measured by its speed, seconds of audio per second of work (20× means a minute of
/// speech in 3 seconds), so a short and a long recording compare fairly. A language model is
/// measured by the time to its first word (mostly reading the prompt), then its writing speed in
/// tokens a second, and the whole time.
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
            if let speed = tokensPerSecond { parts.append("\(Int(speed.rounded())) tokens a second") }
            if let total = totalMs { parts.append("\(Perf.ms(total)) in all") }
            if let tokens = outputTokens { parts.append("\(tokens) tokens") }
        }
        if let load = loadMs, load > 0 { parts.append("model loaded first, \(Perf.ms(load))") }
        return parts.joined(separator: ", ")
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
        value < 60 ? String(format: "%.1f s", value) : String(format: "%d:%02d min", Int(value) / 60, Int(value) % 60)
    }

    static func speed(_ value: Double) -> String {
        value >= 10 ? "\(Int(value.rounded()))×" : String(format: "%.1f×", value)
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
        try? db?.saveMetric(record)
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
        try? db?.pruneMetrics(before: Date().addingTimeInterval(-Double(Self.keepDays) * 86_400))
        reload()
    }

    func clear() {
        try? db?.deleteAllMetrics()
        reload()
    }

    private func reload() {
        recent = (try? db?.metrics(limit: Self.memoryLimit)) ?? []
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
        Dictionary(grouping: recent.filter { !$0.kind.isSpeech }, by: \.model).map { model, records in
            WritingSummary(
                model: model,
                name: records.first?.modelName ?? model,
                count: records.count,
                firstTokenMs: Perf.median(records.compactMap(\.firstTokenMs).map(Double.init)),
                tokensPerSecond: Perf.median(records.compactMap(\.tokensPerSecond)),
                totalMs: Perf.median(records.compactMap(\.totalMs).map(Double.init)),
                loadMs: Perf.median(records.compactMap(\.loadMs).filter { $0 > 0 }.map(Double.init))
            )
        }
        .sorted { $0.count > $1.count }
    }
}
