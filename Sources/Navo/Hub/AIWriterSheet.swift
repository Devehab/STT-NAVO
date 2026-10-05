import SwiftUI

/// The text an AI panel works on. Its word count and direction are worked out once, here, not
/// each time the panel is drawn (which happens for every piece of a streamed answer).
struct AISource {
    let title: String
    let text: String
    let wordCount: Int
    let isArabic: Bool

    init(title: String, text: String) {
        self.title = title
        self.text = text
        wordCount = TextTools.wordCount(text)
        isArabic = TextTools.isRightToLeft(String(text.prefix(4_000)))
    }
}

/// Summaries and rewrites of one transcript: pick what to make on the left, read and copy it on
/// the right. A language model on this Mac writes it (Gemma or Llama): nothing is sent anywhere.
struct AIWriterSheet: View {
    let source: AISource

    @EnvironmentObject private var ai: AIWriter

    var body: some View {
        AIWriterPanel(source: source)
            .environmentObject(ai.engine)
    }
}

private struct AIWriterPanel: View {
    let source: AISource

    @EnvironmentObject private var ai: AIWriter
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: HubRouter
    @EnvironmentObject private var engine: LocalEngineManager
    @Environment(\.dismiss) private var dismiss

    @State private var action: WritingAction?
    @State private var language: OutputLanguage = .sameAsText
    @State private var result: String?
    /// The answer so far, while it is being written.
    @State private var partial = ""
    @State private var note: String?
    @State private var stats: String?
    @State private var status: String?
    @State private var problem: String?
    @State private var working = false
    @State private var job: Task<Void, Never>?
    @State private var copied = false

    private var sourceIsArabic: Bool { source.isArabic }
    private var model: WritingModel { settings.writingModel }
    private var modelReady: Bool { engine.isDownloaded(model) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if modelReady {
                HStack(spacing: 0) {
                    choices
                        .frame(width: 270)
                    Divider()
                    resultPane
                }
            } else {
                downloadPane
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 580)
        .onDisappear {
            job?.cancel()
            // The language model leaves memory now, so the speech models have room again.
            ai.finished()
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(navoBrandGradient))
            VStack(alignment: .leading, spacing: 2) {
                Text("Summarize or rewrite")
                    .font(.headline)
                Text("\(source.title), \(source.wordCount.formatted()) words")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Picker("Model", selection: $settings.writingModel) {
                ForEach(WritingModel.allCases) { choice in
                    Text(engine.isDownloaded(choice) ? choice.title : "\(choice.title) (not downloaded)").tag(choice)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(working)
            .help("The model on this Mac that writes. Change it and pick an action again to compare.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var choices: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(WritingAction.Group.allCases) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.rawValue.uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                        ForEach(group.actions) { item in
                            ActionCard(action: item, selected: item == action) {
                                run(item, language: item.defaultLanguage(sourceIsArabic: sourceIsArabic))
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var resultPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let action {
                HStack(spacing: 10) {
                    Label(action.title, systemImage: action.icon)
                        .font(.headline)
                    Spacer()
                    // Any text into either language: Arabic into English and English into Arabic.
                    Picker("Write in", selection: languageChoice(for: action)) {
                        ForEach(action.languages) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("The language to write it in")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                Divider()
                content(for: action)
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "text.badge.star")
                        .font(.system(size: 34))
                        .foregroundStyle(navoBrandGradient)
                    Text("Pick what to make from this text")
                        .font(.headline)
                    Text("A summary, or the same message as an email, a text message or a clean rewrite, in English or Arabic, whatever language the text is in.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for action: WritingAction) -> some View {
        let arabic = action.writesArabic(language, sourceIsArabic: sourceIsArabic)
        if working {
            if partial.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text(status ?? "Writing with \(model.shortName)…")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    Button("Stop") { stop() }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The answer shows while it is written, and follows its last line.
                answerText(partial, arabic: arabic, following: true)
                Divider()
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status ?? "\(model.shortName) is writing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Stop") { stop() }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        } else if let problem {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                Text(problem)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 380)
                Button("Try again") { run(action, language: language, fresh: true) }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result {
            answerText(result, arabic: arabic, following: false)
            Divider()
            HStack(spacing: 10) {
                Button {
                    run(action, language: language, fresh: true)
                } label: {
                    Label("Write again", systemImage: "arrow.clockwise")
                }
                .help("Ask \(model.shortName) for a new version")
                if let line = [note, stats].compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(line)
                }
                Spacer()
                Button {
                    TextInjector.copy(result)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_300_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private func answerText(_ text: String, arabic: Bool, following: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text)
                    .font(.system(size: 14.5))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, arabic ? .rightToLeft : .leftToRight)
                    .padding(18)
                Color.clear
                    .frame(height: 1)
                    .id("end")
            }
            .onChange(of: text) { _, _ in
                if following { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    /// The chosen model is not on this Mac yet: what it is, and one button to get it.
    private var downloadPane: some View {
        let other = WritingModel.allCases.first { $0 != model && engine.isDownloaded($0) }
        return VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 32))
                .foregroundStyle(navoBrandGradient)
            Text("Download \(model.title) first")
                .font(.headline)
            Text("Summaries and rewrites are written on this Mac by an open language model, so your text is never sent anywhere. \(model.summary) It is downloaded once, then works offline.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if engine.downloadingModel == model {
                ProgressView(value: engine.installProgress)
                    .frame(maxWidth: 360)
                Text(engine.installStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !engine.isInstalled {
                Text("The local engine is not installed yet: AI writing runs in it.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Button("Open Settings") {
                    router.section = .settings
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 10) {
                    Button("Download \(model.shortName), \(String(format: "%.1f", model.downloadGB)) GB") {
                        engine.download(model)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.isBusy)
                    if let other {
                        Button("Use \(other.shortName) instead") { settings.writingModel = other }
                    }
                }
                if engine.isBusy {
                    Text("Another download is running. This one can start when it is done.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let failure = engine.modelDownloadErrors[model] {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 460)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            Text("Written on this Mac by \(model.title). Nothing is sent anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Running

    /// Choosing another language writes it again in that language.
    private func languageChoice(for action: WritingAction) -> Binding<OutputLanguage> {
        Binding(
            get: { language },
            set: { chosen in
                guard chosen != language else { return }
                run(action, language: chosen)
            }
        )
    }

    private func stop() {
        job?.cancel()
        job = nil
        working = false
        if partial.isEmpty {
            action = nil
        } else {
            // What was written so far stays, to read or copy.
            result = partial
            note = "Stopped before the end."
            stats = nil
        }
        partial = ""
        status = nil
    }

    private func run(_ chosen: WritingAction, language chosenLanguage: OutputLanguage, fresh: Bool = false) {
        job?.cancel()
        action = chosen
        language = chosenLanguage
        result = nil
        partial = ""
        note = nil
        stats = nil
        status = nil
        problem = nil
        copied = false
        working = true
        let text = source.text
        let writer = ai
        job = Task { @MainActor in
            do {
                let answer = try await writer.run(
                    chosen,
                    on: text,
                    language: chosenLanguage,
                    fresh: fresh,
                    onStatus: { message in
                        guard !Task.isCancelled else { return }
                        status = message
                    },
                    onText: { soFar in
                        guard !Task.isCancelled else { return }
                        partial = soFar
                    }
                )
                guard !Task.isCancelled else { return }
                result = answer.text
                note = answer.note
                stats = answer.stats
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                problem = error.localizedDescription
            }
            partial = ""
            status = nil
            working = false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct ActionCard: View {
    let action: WritingAction
    let selected: Bool
    let choose: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 11) {
                Image(systemName: action.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? Color.white.opacity(0.22) : Color.accentColor.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(action.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
