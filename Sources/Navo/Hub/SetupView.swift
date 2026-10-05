import SwiftUI

/// The top of Settings: what Navo needs on this Mac, step by step, and every model with its
/// size and whether it is downloaded. Someone who just installed Navo sees what to do next;
/// later it is the place to check what is on the Mac and what is not.
struct SetupSection: View {
    /// The Hugging Face token typed below, for the gated Cohere model.
    let token: String
    let permissionsGranted: Bool

    @EnvironmentObject private var engine: LocalEngineManager
    @EnvironmentObject private var settings: AppSettings
    @State private var showModels = false
    /// Read when the page opens and after a download, not each time the page is drawn.
    @State private var freeDisk: Int64?

    private var dictation: SpeechEngine { settings.dictationEngine }
    private var speechReady: Bool { engine.isDownloaded(dictation) }
    private var writingReady: Bool { WritingModel.allCases.contains { engine.isDownloaded($0) } }
    private var cleanupNeeded: Bool { settings.cleanupMode == .local }
    private var cleanupReady: Bool { !cleanupNeeded || engine.cleanupModelDownloaded }
    /// Everything dictation needs. AI writing is an extra.
    private var complete: Bool { engine.isInstalled && speechReady && cleanupReady && permissionsGranted }

    var body: some View {
        Section {
            if complete {
                Label(summary, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                steps
            }
            if !writingReady && engine.isInstalled && complete {
                SetupStep(
                    number: nil,
                    done: false,
                    title: "AI writing is not set up (optional)",
                    detail: "For summaries and rewrites on this Mac, download a language model."
                ) {
                    WritingDownloadButton(model: settings.writingModel)
                }
            }
            if engine.isBusy && engine.state != .installing {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: engine.installProgress)
                    Text(engine.installStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let failure = downloadFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            DisclosureGroup("Models on this Mac", isExpanded: $showModels) {
                ModelsTable(token: token)
            }
        } header: {
            Text(complete ? "Setup" : "Setup: what Navo needs on this Mac")
        } footer: {
            Text(footer)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            // Open while something is missing, so it is the first thing a new user reads.
            if !complete { showModels = true }
            freeDisk = SetupSection.freeDiskBytes
        }
        .onChange(of: engine.isBusy) { _, busy in
            if !busy { freeDisk = SetupSection.freeDiskBytes }
        }
    }

    /// The last download that failed, whichever model it was for.
    private var downloadFailure: String? {
        if let failure = engine.cleanupDownloadError {
            return "Cleanup model: \(failure)"
        }
        for speech in SpeechEngine.allCases {
            if let failure = engine.downloadErrors[speech] { return "\(speech.shortName): \(failure)" }
        }
        for model in WritingModel.allCases {
            if let failure = engine.modelDownloadErrors[model] { return "\(model.shortName): \(failure)" }
        }
        return nil
    }

    @ViewBuilder
    private var steps: some View {
        SetupStep(
            number: 1,
            done: engine.isInstalled,
            title: engine.isInstalled ? "The local engine is installed" : "Install the local engine",
            detail: engine.state == .installing
                ? engine.installStatus
                : "Python and MLX, the speech model for dictation and the small cleanup model, about 7 GB, one time. Then Navo works offline. No account is needed: with no Hugging Face token Navo sets up Audar, which is public."
        ) {
            if engine.state == .installing {
                ProgressView(value: engine.installProgress)
                    .frame(width: 120)
            } else if !engine.isInstalled {
                Button("Install") { engine.install(huggingFaceToken: token) }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.isBusy)
            }
        }
        SetupStep(
            number: 2,
            done: engine.isInstalled && speechReady,
            title: speechReady ? "\(dictation.title) is downloaded" : "Download a speech model (required)",
            detail: speechReady
                ? "It turns what you say into text. Others can be added below."
                : (engine.isInstalled
                    ? "\(dictation.title) is the model for dictation and it is not on this Mac yet."
                    : "Comes with step 1.")
        ) {
            if engine.isInstalled && !speechReady {
                Button("Download, \(SetupSection.gb(dictation.downloadGB))") {
                    engine.download(dictation, huggingFaceToken: token)
                }
                .disabled(engine.isBusy)
                .help(dictation.isGated ? "Needs the Hugging Face token under Speech engines" : "Public model, no token needed")
            }
        }
        if cleanupNeeded {
            SetupStep(
                number: 3,
                done: engine.isInstalled && engine.cleanupModelDownloaded,
                title: engine.cleanupModelDownloaded ? "The cleanup model is downloaded" : "Download the cleanup model (recommended)",
                detail: engine.cleanupModelDownloaded
                    ? "It removes fillers and fixes punctuation after each dictation."
                    : (engine.isInstalled
                        ? "Without it Navo still works, with a lighter cleanup."
                        : "Comes with step 1.")
            ) {
                if engine.isInstalled && !engine.cleanupModelDownloaded {
                    Button("Download, \(SetupSection.gb(ModelsTable.cleanupGB))") { engine.downloadCleanupModel() }
                        .disabled(engine.isBusy)
                }
            }
        }
        SetupStep(
            number: cleanupNeeded ? 4 : 3,
            done: permissionsGranted,
            title: permissionsGranted ? "Microphone and Accessibility are allowed" : "Allow Microphone and Accessibility",
            detail: permissionsGranted
                ? "Navo can hear you and paste the text where you type."
                : "Under Permissions, just below."
        ) {
            EmptyView()
        }
        SetupStep(
            number: cleanupNeeded ? 5 : 4,
            done: writingReady,
            title: writingReady ? "AI writing is ready" : "AI writing (optional)",
            detail: writingReady
                ? "Summaries and rewrites are written on this Mac."
                : "For summaries and rewrites on this Mac, download a language model. Dictation does not need it."
        ) {
            if engine.isInstalled && !writingReady {
                WritingDownloadButton(model: settings.writingModel)
            }
        }
    }

    private var summary: String {
        var parts = ["engine installed", settings.enabledEngines.filter { engine.isDownloaded($0) }.map(\.shortName).joined(separator: " and ")]
        if let writer = WritingModel.allCases.first(where: { engine.isDownloaded($0) && $0 == settings.writingModel })
            ?? WritingModel.allCases.first(where: { engine.isDownloaded($0) }) {
            parts.append("\(writer.shortName) for AI writing")
        }
        return "Navo is set up: " + parts.filter { !$0.isEmpty }.joined(separator: ", ") + "."
    }

    private var footer: String {
        var text = "Models are downloaded once from Hugging Face into ~/.cache/huggingface, then everything runs on this Mac with no internet."
        if let free = freeDisk {
            text += " Free space on this Mac: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))."
        }
        return text
    }

    static func gb(_ value: Double) -> String {
        String(format: "%.1f GB", value)
    }

    /// Space macOS can make available on the disk that holds the models.
    static var freeDiskBytes: Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

/// One line of the setup list: a number or a check mark, what it is, and what to click.
private struct SetupStep<Trailing: View>: View {
    let number: Int?
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                } else if let number {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "circle.dashed")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(done ? .regular : .medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 1)
    }
}

/// "Download Gemma, 5.2 GB", or its progress while it downloads.
struct WritingDownloadButton: View {
    let model: WritingModel

    @EnvironmentObject private var engine: LocalEngineManager

    var body: some View {
        if engine.downloadingModel == model {
            ProgressView(value: engine.installProgress)
                .frame(width: 120)
        } else {
            Button("Download \(model.shortName), \(SetupSection.gb(model.downloadGB))") {
                engine.download(model)
            }
            .disabled(engine.isBusy || !engine.isInstalled)
            .help(engine.isInstalled ? "Public model, no token needed" : "Install the local engine first")
        }
    }
}

/// Every model Navo can use: what it is for, its size, whether it is needed and whether it is
/// on this Mac.
private struct ModelsTable: View {
    let token: String

    /// The small cleanup model (Qwen3 4B, 4 bit).
    static let cleanupGB = 2.3

    @EnvironmentObject private var engine: LocalEngineManager
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SpeechEngine.allCases) { speech in
                ModelLine(
                    name: speech.title,
                    purpose: speech.purpose,
                    need: speech == settings.dictationEngine ? "Required, used for dictation" : "Optional",
                    required: speech == settings.dictationEngine,
                    gb: speech.downloadGB,
                    downloaded: engine.isDownloaded(speech),
                    downloading: engine.downloading == speech
                ) {
                    engine.download(speech, huggingFaceToken: token)
                }
                Divider()
            }
            ModelLine(
                name: "Cleanup model (Qwen3 4B)",
                purpose: "Tidies each dictation: fillers, punctuation",
                need: settings.cleanupMode == .local ? "Recommended" : "Not used with your cleanup setting",
                required: false,
                gb: Self.cleanupGB,
                downloaded: engine.cleanupModelDownloaded,
                downloading: engine.downloadingCleanup
            ) {
                engine.downloadCleanupModel()
            }
            ForEach(WritingModel.allCases) { model in
                Divider()
                ModelLine(
                    name: "\(model.title) (\(model.maker))",
                    purpose: "AI writing: summaries and rewrites",
                    need: model == settings.writingModel ? "Optional, chosen for AI writing" : "Optional",
                    required: false,
                    gb: model.downloadGB,
                    downloaded: engine.isDownloaded(model),
                    downloading: engine.downloadingModel == model
                ) {
                    engine.download(model)
                }
            }
            Divider()
            Text(totals)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .padding(.top, 4)
    }

    private var totals: String {
        var downloaded = 0.0
        var count = 0
        for speech in SpeechEngine.allCases where engine.isDownloaded(speech) {
            downloaded += speech.downloadGB
            count += 1
        }
        if engine.cleanupModelDownloaded {
            downloaded += Self.cleanupGB
            count += 1
        }
        for model in WritingModel.allCases where engine.isDownloaded(model) {
            downloaded += model.downloadGB
            count += 1
        }
        let total = SpeechEngine.allCases.count + WritingModel.allCases.count + 1
        return "\(count) of \(total) models are on this Mac, about \(SetupSection.gb(downloaded)). Two speech models can be on at once, and a language model never shares memory with a speech model."
    }
}

private struct ModelLine: View {
    let name: String
    let purpose: String
    let need: String
    let required: Bool
    let gb: Double
    let downloaded: Bool
    let downloading: Bool
    let download: () -> Void

    @EnvironmentObject private var engine: LocalEngineManager

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: downloaded ? "checkmark.circle.fill" : (required ? "exclamationmark.circle.fill" : "circle"))
                .foregroundStyle(downloaded ? Color.green : (required ? Color.orange : Color.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text("\(purpose). \(need).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(SetupSection.gb(gb))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Group {
                if downloading {
                    ProgressView(value: engine.installProgress)
                } else if downloaded {
                    Text("Downloaded")
                        .foregroundStyle(.green)
                } else {
                    Button("Download", action: download)
                        .disabled(engine.isBusy || !engine.isInstalled)
                        .help(engine.isInstalled ? "Download it now" : "Install the local engine first")
                }
            }
            .font(.callout)
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }
}
