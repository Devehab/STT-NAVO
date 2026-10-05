import AppKit
import SwiftUI

/// A recording or audio file to run through every speech engine.
struct CompareTarget: Identifiable {
    let id = UUID()
    let audioURL: URL
    let title: String
    let language: DictationLanguage
}

/// Runs one recording through the speech engines that are on (two at most) and shows the raw
/// transcripts side by side.
struct CompareSheet: View {
    let target: CompareTarget

    @EnvironmentObject private var engine: LocalEngineManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var language: DictationLanguage = .ar
    @State private var result: CompareClient.Result?
    @State private var error: String?
    @State private var running = false

    /// Engines that can answer now: loaded, or asleep (the request loads them).
    private var availableEngines: [SpeechEngine] {
        SpeechEngine.allCases.filter {
            let status = engine.engines[$0]?.status
            return status == "ready" || status == "asleep"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Compare engines")
                        .font(.title3.weight(.semibold))
                    Text(target.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Picker("Language", selection: $language) {
                    Text("Arabic").tag(DictationLanguage.ar)
                    Text("English").tag(DictationLanguage.en)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                Button(running ? "Running…" : "Run again") { run() }
                    .disabled(running)
            }

            HStack(alignment: .top, spacing: 14) {
                ForEach(settings.enabledEngines) { speech in
                    EngineResultCard(speech: speech, entry: entry(for: speech), running: running)
                }
            }
            .frame(minHeight: 220)

            otherEnginesRow

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            HStack {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 780, idealWidth: 860, minHeight: 380)
        .onAppear {
            // Every engine takes Arabic and English; Cohere has no Auto.
            language = target.language == .en ? .en : .ar
            run()
        }
        .onChange(of: availableEngines) { _, available in
            // An engine was turned on from this sheet: run again now that it can answer.
            guard !running, let result else { return }
            let missing = available.contains { speech in
                guard let entry = result.entries.first(where: { $0.engine == speech.rawValue }) else { return true }
                return entry.text == nil
            }
            if missing { run() }
        }
    }

    /// The engines that are off: one click turns one on while there is room, else how to make room.
    @ViewBuilder
    private var otherEnginesRow: some View {
        let others = SpeechEngine.allCases.filter { !settings.isEnabled($0) }
        if !others.isEmpty {
            if settings.enabledEngines.count < AppSettings.maxEnabledEngines {
                HStack(spacing: 8) {
                    Text("Compare with")
                        .foregroundStyle(.secondary)
                    ForEach(others) { speech in
                        let downloaded = engine.engines[speech]?.downloaded != false
                        Button(speech.shortName) { engine.setEnabled(speech, true) }
                            .disabled(!downloaded || running)
                            .help(downloaded ? "Turn \(speech.title) on and compare" : "Download \(speech.title) first in Settings > Speech engines")
                    }
                }
                .font(.callout)
            } else {
                Text("\(AppSettings.maxEnabledEngines) engines can be on at once. To compare with \(others.map(\.shortName).joined(separator: " or ")), turn one of these off in Settings > Speech engines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: String {
        var parts = ["Raw transcripts before cleanup, from engines on this Mac, one after the other."]
        if let result, result.duration > 0 {
            parts.append(String(format: "Audio: %.1f s.", result.duration))
        }
        return parts.joined(separator: " ")
    }

    private func entry(for speech: SpeechEngine) -> CompareClient.Entry? {
        result?.entries.first { $0.engine == speech.rawValue }
    }

    private func run() {
        guard !running else { return }
        running = true
        error = nil
        let url = target.audioURL
        let client = CompareClient(baseURL: engine.baseURL)
        let code = language.rawValue
        Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                running = false
            }
            do {
                result = try await client.compare(
                    fileURL: url,
                    language: code,
                    engines: settings.enabledEngines.map(\.rawValue)
                )
            } catch {
                self.error = engine.isRunning ? error.localizedDescription : "Start the local engine first."
            }
        }
    }
}

private struct EngineResultCard: View {
    let speech: SpeechEngine
    let entry: CompareClient.Entry?
    let running: Bool

    @EnvironmentObject private var engine: LocalEngineManager
    @EnvironmentObject private var settings: AppSettings
    @State private var copied = false

    private var info: LocalEngineManager.EngineInfo? { engine.engines[speech] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(speech.title)
                    .font(.headline)
                if settings.dictationEngine == speech {
                    Text("Dictation")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Spacer()
                if let ms = entry?.processingMs, entry?.text != nil {
                    Text(String(format: "%.1f s", Double(ms) / 1000))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let text = entry?.text, !text.isEmpty {
                HStack {
                    Text("\(TextTools.wordCount(text)) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        TextInjector.copy(text)
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            copied = false
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private var content: some View {
        if let text = entry?.text {
            ScrollView {
                Text(text.isEmpty ? "No speech recognized." : text)
                    .font(.system(size: 14.5))
                    .lineSpacing(3)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, TextTools.isRightToLeft(text) ? .rightToLeft : .leftToRight)
            }
        } else if running {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").foregroundStyle(.secondary)
            }
        } else if let failure = entry?.error {
            unavailable(failure)
        } else {
            Text("Not run yet.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func unavailable(_ failure: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if info?.downloaded == false {
                Text("Not downloaded yet. Download it in Settings > Speech engines.")
                    .foregroundStyle(.secondary)
            } else if info?.status == "off" {
                Text("Turned off, so it is not using memory.")
                    .foregroundStyle(.secondary)
                Button("Turn on and compare") { engine.setEnabled(speech, true) }
                    .disabled(!settings.canEnable(speech))
            } else if info?.status == "loading" || info?.status == "asleep" {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading the model, the comparison runs when it is ready.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(failure)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
    }
}
