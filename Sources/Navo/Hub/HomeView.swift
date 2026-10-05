import AppKit
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: HistoryStore
    @EnvironmentObject private var settings: AppSettings

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? "there"
    }

    private var hint: String {
        let key = settings.pushToTalkKey
        if key == .off {
            return "Click Speak on the Flow Bar to dictate into any app."
        }
        return "Hold \(key.shortName) and talk, release to insert. Double-tap \(key.shortName) for hands-free, Esc cancels."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Welcome back, \(firstName)")
                            .font(.system(size: 30, weight: .semibold))
                        Text(hint)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    LanguageSwitch()
                }

                EngineNotice()

                StatsRow(stats: store.stats)

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("History")
                            .font(.system(size: 20, weight: .semibold))
                        Spacer()
                        SearchField("Search history", text: $store.searchText)
                            .frame(width: 300)
                    }

                    if store.items.isEmpty {
                        Group {
                            if store.searchText.isEmpty {
                                ContentUnavailableView(
                                    "No dictations yet",
                                    systemImage: "waveform",
                                    description: Text("Everything you dictate is saved here, grouped by day.")
                                )
                            } else {
                                ContentUnavailableView.search(text: store.searchText)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        // One lazy list of rows, so only the rows in view are drawn, however long
                        // the history is.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(store.groups) { group in
                                DayHeader(title: group.title, first: group.id == store.groups.first?.id)
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                    HistoryRow(item: item, first: index == 0, last: index == group.items.count - 1)
                                }
                            }
                        }
                    }
                }

                if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Language

/// The dictation language, one click away, with the shortcut spelled out under it.
private struct LanguageSwitch: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Picker("Dictation language", selection: $settings.language) {
                ForEach(settings.dictationEngine.languages) { language in
                    Text(language.name).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(settings.languageShortcut.map { "Switch anywhere: \($0.spelled)" } ?? "Language of what you dictate")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help("The language you dictate in. \(settings.dictationEngine.shortName) takes " + settings.dictationEngine.languages.map(\.name).joined(separator: ", ") + ".")
    }
}

// MARK: Engine banner

/// The banner when the engine can't take dictation yet. Its own view, so only it follows the
/// engine's frequent updates (memory use, model state), not the whole page.
private struct EngineNotice: View {
    @EnvironmentObject private var engine: LocalEngineManager

    var body: some View {
        if !engine.state.canDictate {
            EngineBanner()
        }
    }
}

private struct EngineBanner: View {
    @EnvironmentObject private var engine: LocalEngineManager
    @EnvironmentObject private var router: HubRouter

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            icon
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if engine.state == .installing {
                    ProgressView(value: engine.installProgress)
                        .frame(maxWidth: 360)
                }
            }
            Spacer()
            Button(buttonTitle) {
                router.section = .settings
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.2)))
    }

    @ViewBuilder
    private var icon: some View {
        switch engine.state {
        case .notInstalled:
            Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(navoBrandGradient)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
        default:
            ProgressView().controlSize(.small)
        }
    }

    private var title: String {
        switch engine.state {
        case .notInstalled: return "Install the local speech engine"
        case .installing: return "Installing the local engine"
        case .failed: return "The local engine needs attention"
        default: return "Loading the speech model"
        }
    }

    private var subtitle: String {
        switch engine.state {
        case .notInstalled:
            return "Navo runs speech recognition and a small cleanup model on this Mac. One-time download, then everything works offline."
        case .installing:
            return engine.installStatus
        case .failed(let message):
            return message
        default:
            return "Takes a few seconds after launch. You can already start talking."
        }
    }

    private var buttonTitle: String {
        switch engine.state {
        case .notInstalled: return "Set up"
        case .failed: return "Open Settings"
        default: return "Details"
        }
    }
}

// MARK: Stats

private struct StatsRow: View {
    let stats: UsageStats

    var body: some View {
        HStack(spacing: 14) {
            StatCard(
                value: TextTools.compactNumber(stats.totalWords),
                label: "Words dictated",
                icon: "text.bubble.fill",
                tint: Color(red: 0.55, green: 0.40, blue: 1.0)
            )
            StatCard(value: "\(stats.averageWPM)", label: "Words per minute", icon: "speedometer", tint: Color(red: 0.16, green: 0.56, blue: 1.0))
            StatCard(
                value: "\(stats.streakDays)",
                label: stats.streakDays == 1 ? "Day streak" : "Days in a row",
                icon: "flame.fill",
                tint: Color(red: 1.0, green: 0.50, blue: 0.16)
            )
            StatCard(value: "\(stats.minutesSaved)", label: "Minutes saved", icon: "clock.fill", tint: Color(red: 0.16, green: 0.74, blue: 0.46))
        }
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.gradient))
                .shadow(color: tint.opacity(0.35), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.14), tint.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.22)))
    }
}

// MARK: History

private struct DayHeader: View {
    let title: String
    let first: Bool

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .padding(.top, first ? 0 : 26)
            .padding(.bottom, 8)
    }
}

/// One dictation. The text takes the whole width; pointing at the row lights it up and shows
/// its buttons at the end of the details line.
private struct HistoryRow: View {
    let item: Dictation
    /// First and last of its day: the rounded ends of the day's card.
    let first: Bool
    let last: Bool

    @EnvironmentObject private var store: HistoryStore
    @EnvironmentObject private var playback: AudioPlayback
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ai: AIWriter
    @EnvironmentObject private var router: HubRouter
    /// Called, not followed: following dictation would redraw every row many times a second
    /// while you talk.
    @Environment(\.hubControllers) private var controllers

    @State private var hovering = false
    @State private var comparing: CompareTarget?
    @State private var showOriginal = false
    @State private var editing = false
    @State private var copied = false
    @State private var confirmDelete = false
    @State private var writing = false

    private var displayText: String {
        showOriginal ? item.rawText : item.cleanText
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: first ? 14 : 0,
            bottomLeadingRadius: last ? 14 : 0,
            bottomTrailingRadius: last ? 14 : 0,
            topTrailingRadius: first ? 14 : 0,
            style: .continuous
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(item.createdAt, style: .time)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 66, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 9) {
                if item.status == .failed {
                    failedContent
                } else {
                    ExpandableText(text: displayText)
                }
                meta
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        if hovering || item.status == .failed {
                            actions
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                        }
                    }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            shape
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(shape.fill(Color.accentColor.opacity(hovering ? 0.07 : 0)))
        )
        .overlay(alignment: .bottom) {
            if !last {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                    .padding(.leading, 100)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hovering = inside
            }
        }
        .sheet(isPresented: $editing) {
            EditDictationSheet(item: item)
                .environmentObject(store)
        }
        .sheet(isPresented: $writing) {
            AIWriterSheet(source: AISource(
                title: "Dictation, " + item.createdAt.formatted(date: .abbreviated, time: .shortened),
                text: displayText
            ))
            .environmentObject(ai)
            .environmentObject(settings)
            .environmentObject(router)
        }
        .sheet(item: $comparing) { target in
            if let engine = controllers?.engine {
                CompareSheet(target: target)
                    .environmentObject(engine)
                    .environmentObject(settings)
            }
        }
        .confirmationDialog("Delete this dictation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if playback.playingID == item.id { playback.stop() }
                store.delete(item)
            }
        } message: {
            Text("The text and its recording are removed from this Mac.")
        }
    }

    private var failedContent: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Transcription failed")
                    .font(.system(size: 14, weight: .medium))
                Text(item.errorMessage ?? "Unknown error")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            if item.hasAudio {
                // Does nothing while a dictation is running.
                Button("Retry") { controllers?.dictation.retry(item) }
            }
        }
    }

    private var meta: some View {
        HStack(spacing: 10) {
            if !item.language.isEmpty {
                Text(TextTools.languageLabel(item.language))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            if let app = item.appName, !app.isEmpty {
                Label(app, systemImage: "macwindow")
            }
            if item.status == .ok {
                Text("\(item.wordCount) \(item.wordCount == 1 ? "word" : "words")")
            }
            Text(TextTools.duration(item.duration))
            if let engineName = item.engine {
                Label(onDeviceLabel(engineName), systemImage: "cpu")
                    .help("Transcribed on this Mac by the local \(SpeechEngine.from(historyName: engineName).title) model")
            }
            if item.cleanup == CleanupMode.local.rawValue || item.cleanup == CleanupMode.custom.rawValue {
                Label("Polished", systemImage: "sparkles")
            } else if item.status == .ok, let note = item.errorMessage, !note.isEmpty {
                Label("Not polished", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .help(note)
            }
            if showOriginal {
                Text("Original transcript")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }

    /// "On this Mac, Audar, MLX, 1.2 s"
    private func onDeviceLabel(_ engineName: String) -> String {
        var parts = ["On this Mac", SpeechEngine.from(historyName: engineName).shortName]
        if engineName.contains("(mlx)") {
            parts.append("MLX")
        } else if engineName.contains("(transformers)") {
            parts.append("PyTorch")
        }
        if let latency = item.latencyMs {
            parts.append(String(format: "%.1f s", Double(latency) / 1000))
        }
        return parts.joined(separator: ", ")
    }

    /// The row's buttons, floating at the end of the details line.
    private var actions: some View {
        HStack(spacing: 1) {
            if item.hasAudio {
                RowButton(
                    icon: playback.playingID == item.id ? "stop.fill" : "play.fill",
                    help: playback.playingID == item.id ? "Stop" : "Play recording"
                ) {
                    playback.toggle(item)
                }
            }
            if item.status == .ok {
                RowButton(icon: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    TextInjector.copy(displayText)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                }
                if item.rawText != item.cleanText && !item.rawText.isEmpty {
                    RowButton(icon: showOriginal ? "text.badge.checkmark" : "text.quote", help: showOriginal ? "Show cleaned text" : "Show original transcript") {
                        showOriginal.toggle()
                    }
                }
                RowButton(icon: "pencil", help: "Edit") {
                    editing = true
                }
                RowButton(icon: "sparkles", help: "Summarize or rewrite with AI: an email, a text message or a clean rewrite, in English or Arabic") {
                    writing = true
                }
                .disabled(displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if item.hasAudio && item.status == .ok {
                RowButton(icon: "arrow.clockwise", help: "Transcribe again with \(settings.dictationEngine.shortName)") {
                    controllers?.dictation.retry(item)
                }
            }
            if item.hasAudio, let path = item.audioPath, controllers != nil {
                RowButton(icon: "rectangle.split.2x1", help: "Compare engines on this recording") {
                    comparing = CompareTarget(
                        audioURL: URL(fileURLWithPath: path),
                        title: "Recording from " + item.createdAt.formatted(date: .abbreviated, time: .shortened),
                        language: DictationLanguage(rawValue: item.language) ?? settings.language
                    )
                }
            }
            RowButton(icon: "trash", help: "Delete") {
                confirmDelete = true
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        )
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

private struct RowButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct EditDictationSheet: View {
    let item: Dictation

    @EnvironmentObject private var store: HistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit dictation")
                .font(.title3.weight(.semibold))
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minWidth: 560, minHeight: 240)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                .environment(\.layoutDirection, TextTools.isRightToLeft(text) ? .rightToLeft : .leftToRight)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var updated = item
                    updated.cleanText = text
                    updated.wordCount = TextTools.wordCount(text)
                    updated.language = TextTools.detectLanguage(text)
                    store.save(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .onAppear { text = item.cleanText }
    }
}
