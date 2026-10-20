import SwiftUI

/// Settings > Performance: how fast each model is on this Mac, from what you actually did with it,
/// with what each number means.
struct PerformanceSections: View {
    /// Opens a file to run through every engine that is on (Settings' compare sheet).
    let compareOnFile: () -> Void

    @EnvironmentObject private var metrics: MetricsStore
    @EnvironmentObject private var engine: LocalEngineManager
    @EnvironmentObject private var router: HubRouter
    @ObservedObject private var problems = ProblemLog.shared
    @State private var confirmClear = false
    @State private var confirmClearProblems = false
    @State private var openRecord: String?

    var body: some View {
        speechSection
        writingSection
        recentSection
        problemsSection
        meaningSection
    }

    // MARK: Speech

    private var speechSection: some View {
        Section {
            let summaries = metrics.speechSummaries
            if summaries.isEmpty {
                Text("No measurements yet. Dictate, record a meeting or transcribe a file: the numbers appear here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summaries) { summary in
                    SummaryRow(
                        title: summary.name,
                        count: summary.count,
                        noun: "transcription",
                        figures: [
                            summary.speed.map { Figure(value: Perf.speed($0), label: "real time", help: "Seconds of audio per second of work. \(Perf.speed($0)) means a minute of speech in \(Perf.seconds(60 / $0)).") },
                            summary.waitMs.map { Figure(value: Perf.ms(Perf.int($0)), label: "after you let go", help: "From letting go of the dictation key to the text being ready, cleanup included.") },
                            summary.cleanupMs.map { Figure(value: Perf.ms(Perf.int($0)), label: "cleanup", help: "The cleanup model tidying the text, in a dictation.") },
                            summary.loadMs.map { Figure(value: Perf.ms(Perf.int($0)), label: "to wake up", help: "Loading the model after it slept, before the first transcription.") },
                        ].compactMap { $0 }
                    )
                }
            }
            HStack {
                Text("Compare the engines on the same recording, for a fair test")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Compare on a file…", action: compareOnFile)
                    .disabled(!engine.isRunning)
                    .help("Runs one audio file through every engine that is on, side by side, with each one's time")
            }
        } header: {
            SectionTitle("Speech to text", "waveform")
        } footer: {
            Text("The middle value of the last \(MetricsStore.keepDays) days, so one unusual run does not count much. Speed is measured on the audio itself, so a short dictation and a long meeting compare fairly.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Language models

    private var writingSection: some View {
        Section {
            let summaries = metrics.writingSummaries
            if summaries.isEmpty {
                Text("No measurements yet. Ask for a summary or a rewrite with the AI button, or test a model in Cleanup and AI.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summaries) { summary in
                    SummaryRow(
                        title: summary.name,
                        count: summary.count,
                        noun: "answer",
                        figures: [
                            summary.firstTokenMs.map { Figure(value: Perf.ms(Perf.int($0)), label: "first word", help: "Time to the first token: the model reads your text before it writes. Longer texts take longer here.") },
                            summary.tokensPerSecond.map { Figure(value: "\(Perf.int($0))", label: "tokens a second", help: "Writing speed once it has started. A token is about three quarters of an English word, less in Arabic.") },
                            summary.totalMs.map { Figure(value: Perf.ms(Perf.int($0)), label: "in all", help: "The whole answer, from asking to the last word.") },
                            summary.loadMs.map { Figure(value: Perf.ms(Perf.int($0)), label: "to load", help: "Loading the model into memory when it was not there yet.") },
                        ].compactMap { $0 },
                        tokens: tokenFigures(summary)
                    )
                }
            }
            HStack {
                Text("Measure a model with one short answer")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Test in Cleanup and AI") { router.settingsPane = .writing }
            }
        } header: {
            SectionTitle("AI writing", "sparkles")
        }
    }

    /// The second row of a language model: its context window and its tokens.
    private func tokenFigures(_ summary: MetricsStore.WritingSummary) -> [Figure] {
        var figures: [Figure] = []
        if let window = summary.contextTokens {
            var help = "Context window: the tokens one request can hold, your text, the instructions and the answer together."
            if let own = summary.modelContextTokens {
                help += window < own
                    ? " The model was made for \(Perf.count(own)); Navo keeps it to \(Perf.count(window)) so it stays within its memory limit. A longer text is read in parts."
                    : " That is all the model was made for."
            }
            figures.append(Figure(value: Perf.compact(window), label: "context", help: help))
        }
        if let own = summary.modelContextTokens {
            figures.append(Figure(value: Perf.compact(own), label: "model's own", help: "The longest context the model was made for, from its own files."))
        }
        if let prompt = summary.promptTokens {
            figures.append(Figure(value: Perf.compact(Perf.int(prompt)), label: "tokens in", help: "A typical request: your text plus the instructions, in tokens."))
        }
        if let output = summary.outputTokens {
            figures.append(Figure(value: Perf.compact(Perf.int(output)), label: "tokens out", help: "A typical answer, in tokens."))
        }
        if let used = summary.contextUsed {
            figures.append(Figure(value: Perf.percent(used), label: "of the context", help: "How full a typical request was. Near 100% the text is read in parts, which takes longer."))
        }
        if let per = summary.charsPerToken {
            figures.append(Figure(value: Perf.decimal(per), label: "characters a token", help: "How many characters of your text fit in one token. Higher means the model's tokenizer knows the language better: the same text costs fewer tokens, fits more in the context and is read faster."))
        }
        if summary.cutOffs > 0 {
            figures.append(Figure(value: "\(summary.cutOffs)", label: "cut off", help: "Answers that reached their length limit and stopped before the end."))
        }
        return figures
    }

    // MARK: Recent

    private var recentSection: some View {
        Section {
            if metrics.recent.isEmpty {
                Text("Nothing measured yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(metrics.recent.prefix(25)) { record in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: record.kind.icon)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(record.modelName).fontWeight(.medium)
                                Text(record.kind.title).foregroundStyle(.secondary)
                                if record.live {
                                    Text("live").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(record.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = record.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            if openRecord == record.id {
                                Text(record.kind.isSpeech ? record.dictationBreakdown : record.writingBreakdown)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 3)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(record.createdAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !record.kind.isSpeech {
                                Button(openRecord == record.id ? "Less" : "Details") {
                                    openRecord = openRecord == record.id ? nil : record.id
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                                .help("Every figure of this answer: the context window, the tokens in and out, the characters a token and the time")
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            HStack {
                Spacer()
                Button("Clear the measurements…", role: .destructive) { confirmClear = true }
                    .disabled(metrics.recent.isEmpty)
            }
        } header: {
            SectionTitle("Recent", "clock")
        }
        .confirmationDialog("Clear every measurement?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { metrics.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the timings go. Your dictations, recordings and texts stay.")
        }
    }

    // MARK: Problems

    private var problemsSection: some View {
        Section {
            if problems.entries.isEmpty {
                Text("Nothing went wrong. When something fails, a model, a transcription, or a figure that could not be measured, Navo carries on and notes it here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(problems.entries.prefix(12)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.area).fontWeight(.medium)
                            Text(entry.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(entry.date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
                if problems.entries.count > 12 {
                    Text("\(problems.entries.count - 12) more in the log file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Show the log file") { problems.reveal() }
                    .help("Logs/problems.log in Navo's folder: one line for each problem, with the time")
                Button("Copy all") { problems.copyAll() }
                    .disabled(problems.entries.isEmpty)
                    .help("Copies every problem, to paste into a message or a bug report")
                Spacer()
                Button("Clear…", role: .destructive) { confirmClearProblems = true }
                    .disabled(problems.entries.isEmpty)
            }
        } header: {
            SectionTitle("Problems log", "exclamationmark.triangle")
        } footer: {
            Text("What failed and why, without stopping Navo, so it can be fixed later. Only the problem is written, never your text.")
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Clear the problems log?", isPresented: $confirmClearProblems) {
            Button("Clear", role: .destructive) { problems.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: What the numbers mean

    private var meaningSection: some View {
        Section {
            Meaning(title: "Speed, × real time", text: "Speech to text: how many seconds of audio the model turns into text in one second. 20× means a minute of speech in 3 seconds. It does not depend on how long you spoke, so it compares models fairly. Higher is better.")
            Meaning(title: "After you let go", text: "A dictation: from letting go of the key to the text being ready to paste, cleanup included. This is the wait you feel. With live text, most of a long dictation is written while you talk, so this stays short.")
            Meaning(title: "Cleanup", text: "The small language model that removes fillers and fixes punctuation after each dictation.")
            Meaning(title: "First word (time to first token)", text: "AI writing: how long the model reads your text before the first word of its answer appears. Longer texts take longer.")
            Meaning(title: "Tokens a second", text: "AI writing: how fast it writes once it has started. Around 20 or more reads comfortably.")
            Meaning(title: "Context window", text: "AI writing: how many tokens one request can hold, your text, the instructions and the answer together. Navo keeps it smaller than the model could take, so the model stays within its memory limit; a longer text is read in parts. \"Model's own\" is the most the model was made for.")
            Meaning(title: "Tokens in, tokens out", text: "The size of a request and of its answer, in tokens, the units a model reads and writes. \"Of the context\" is how full the fullest request was.")
            Meaning(title: "Characters a token", text: "How many characters of your text fit in one token. A model whose tokenizer knows the language well puts more in each token: the same text then costs fewer tokens, fits more in the context and is read faster. Compare models on the same language: Arabic usually gets fewer characters a token than English.")
            Meaning(title: "In all", text: "The whole job, from asking to the last word, or the whole transcription of a file.")
            Meaning(title: "To wake up / to load", text: "A model that slept to free memory loads again first (Settings > Speech engines > Free memory when idle). Only the first use after a sleep pays this.")
        } header: {
            SectionTitle("What the numbers mean", "questionmark.circle")
        } footer: {
            Text("Measured on this Mac only, from your own use: numbers, the model's name and the time, never your text. They are kept \(MetricsStore.keepDays) days, and go with the dictation or recording they belong to when it is deleted.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct Figure: Hashable {
    let value: String
    let label: String
    let help: String
}

private struct SummaryRow: View {
    let title: String
    let count: Int
    let noun: String
    let figures: [Figure]
    /// A second row: a language model's context and tokens.
    var tokens: [Figure] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.medium)
                Text("\(count) \(count == 1 ? noun : noun + "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            row(figures)
            if !tokens.isEmpty {
                row(tokens, size: 14)
            }
        }
        .padding(.vertical, 3)
    }

    private func row(_ figures: [Figure], size: CGFloat = 17) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 14, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(figures, id: \.self) { figure in
                VStack(alignment: .leading, spacing: 1) {
                    Text(figure.value)
                        .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(figure.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help(figure.help)
            }
        }
    }
}

private struct Meaning: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.medium)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
