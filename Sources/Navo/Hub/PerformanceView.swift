import SwiftUI

/// Settings > Performance: how fast each model is on this Mac, from what you actually did with it,
/// with what each number means.
struct PerformanceSections: View {
    /// Opens a file to run through every engine that is on (Settings' compare sheet).
    let compareOnFile: () -> Void

    @EnvironmentObject private var metrics: MetricsStore
    @EnvironmentObject private var engine: LocalEngineManager
    @EnvironmentObject private var router: HubRouter
    @State private var confirmClear = false

    var body: some View {
        speechSection
        writingSection
        recentSection
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
                            summary.waitMs.map { Figure(value: Perf.ms(Int($0)), label: "after you let go", help: "From letting go of the dictation key to the text being ready, cleanup included.") },
                            summary.cleanupMs.map { Figure(value: Perf.ms(Int($0)), label: "cleanup", help: "The cleanup model tidying the text, in a dictation.") },
                            summary.loadMs.map { Figure(value: Perf.ms(Int($0)), label: "to wake up", help: "Loading the model after it slept, before the first transcription.") },
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
                            summary.firstTokenMs.map { Figure(value: Perf.ms(Int($0)), label: "first word", help: "Time to the first token: the model reads your text before it writes. Longer texts take longer here.") },
                            summary.tokensPerSecond.map { Figure(value: "\(Int($0.rounded()))", label: "tokens a second", help: "Writing speed once it has started. A token is about three quarters of an English word, less in Arabic.") },
                            summary.totalMs.map { Figure(value: Perf.ms(Int($0)), label: "in all", help: "The whole answer, from asking to the last word.") },
                            summary.loadMs.map { Figure(value: Perf.ms(Int($0)), label: "to load", help: "Loading the model into memory when it was not there yet.") },
                        ].compactMap { $0 }
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
                        }
                        Spacer()
                        Text(record.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

    // MARK: What the numbers mean

    private var meaningSection: some View {
        Section {
            Meaning(title: "Speed, × real time", text: "Speech to text: how many seconds of audio the model turns into text in one second. 20× means a minute of speech in 3 seconds. It does not depend on how long you spoke, so it compares models fairly. Higher is better.")
            Meaning(title: "After you let go", text: "A dictation: from letting go of the key to the text being ready to paste, cleanup included. This is the wait you feel. With live text, most of a long dictation is written while you talk, so this stays short.")
            Meaning(title: "Cleanup", text: "The small language model that removes fillers and fixes punctuation after each dictation.")
            Meaning(title: "First word (time to first token)", text: "AI writing: how long the model reads your text before the first word of its answer appears. Longer texts take longer.")
            Meaning(title: "Tokens a second", text: "AI writing: how fast it writes once it has started. Around 20 or more reads comfortably.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.medium)
                Text("\(count) \(count == 1 ? noun : noun + "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 18) {
                ForEach(figures, id: \.self) { figure in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(figure.value)
                            .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(figure.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help(figure.help)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 3)
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
