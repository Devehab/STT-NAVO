import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The parts of Settings, each with its own page.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case dictation
    case engines
    case writing
    case notetaker
    case performance
    case flowBar
    case clipboard
    case privacy
    case storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .engines: return "Speech engines"
        case .writing: return "Cleanup and AI"
        case .notetaker: return "Notetaker and Transcribe"
        case .performance: return "Performance"
        case .flowBar: return "Flow Bar"
        case .clipboard: return "Clipboard"
        case .privacy: return "Privacy"
        case .storage: return "History and storage"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .dictation: return "mic.fill"
        case .engines: return "waveform"
        case .writing: return "sparkles"
        case .notetaker: return "record.circle"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .flowBar: return "capsule.bottomhalf.filled"
        case .clipboard: return "doc.on.clipboard.fill"
        case .privacy: return "hand.raised.fill"
        case .storage: return "externaldrive.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: return .gray
        case .dictation: return .red
        case .engines: return .blue
        case .writing: return .purple
        case .notetaker: return .orange
        case .performance: return .pink
        case .flowBar: return .teal
        case .clipboard: return .green
        case .privacy: return .indigo
        case .storage: return .brown
        }
    }

    /// One sentence under the title: what the page is for.
    var summary: String {
        switch self {
        case .general: return "What Navo needs on this Mac, the permissions, and how the text reaches your apps."
        case .dictation: return "The key you hold to talk, the language, and what happens while you speak."
        case .engines: return "The speech-to-text models on this Mac: download them, pick the one for dictation, and how much memory they use."
        case .writing: return "Tidying up what you said, and the language models that summarize and rewrite."
        case .notetaker: return "Meetings turned into text while they go on, and audio files turned into text."
        case .performance: return "How fast each model is on this Mac, measured on your own dictations, transcriptions and AI answers."
        case .flowBar: return "The small bar at the edge of the screen that shows you are dictating."
        case .clipboard: return "Everything you copy, kept on this Mac so you can paste it again later."
        case .privacy: return "Keep Navo out of screen sharing, and see for yourself that everything stays on this Mac."
        case .storage: return "Your dictations and recordings: how long they are kept, and deleting them."
        }
    }
}

/// A Settings page's icon: a white symbol on a colored tile, as in System Settings.
struct SettingsIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(pane.color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: pane.icon)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// A switch with a line under it that says what it does.
struct SettingToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(_ title: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A section title with its symbol.
struct SectionTitle: View {
    let title: String
    let icon: String

    init(_ title: String, _ icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label(title, systemImage: icon)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: LocalEngineManager
    @EnvironmentObject private var store: HistoryStore
    @EnvironmentObject private var router: HubRouter
    @EnvironmentObject private var ai: AIWriter

    @State private var microphone = MicrophonePermission.status
    @State private var accessibility = TextInjector.isTrusted
    @State private var hfToken = ""
    @State private var showLog = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var purgeMode: PurgeMode = .keepRecent
    @State private var purgeDays = 3
    @State private var purgeScope: PurgeScope = .textAndAudio
    @State private var purgeCount = 0
    @State private var confirmPurge = false
    @State private var purgeResult: String?
    @State private var retentionChange: RetentionChange?
    @State private var pickAudio = false
    @State private var comparing: CompareTarget?
    @State private var addingModel = false

    private struct RetentionChange: Identifiable {
        let id = UUID()
        let isText: Bool
        let days: Int
        let count: Int
    }

    private static let dayChoices = [1, 3, 7, 14, 30, 90]
    private static let idleChoices = [2, 5, 10, 30, 60, 0]
    private static let retentionChoices = [0, 1, 3, 7, 14, 30, 90]

    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var pane: SettingsPane { router.settingsPane }

    var body: some View {
        HStack(spacing: 0) {
            paneList
                .frame(width: 244)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                paneHeader
                Form {
                    paneContent
                }
                .formStyle(.grouped)
                .id(pane) // each page starts at its top
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .fileImporter(isPresented: $pickAudio, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result else { return }
            let target = CompareTarget(audioURL: url, title: url.lastPathComponent, language: settings.language)
            // Present after the open panel has closed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                comparing = target
            }
        }
        .sheet(item: $comparing) { target in
            CompareSheet(target: target)
                .environmentObject(engine)
                .environmentObject(settings)
        }
        .sheet(isPresented: $addingModel) {
            AddModelSheet()
                .environmentObject(engine)
                .environmentObject(settings)
                .environmentObject(ai)
        }
        .onReceive(permissionTimer) { _ in
            // Only a real change redraws the page.
            let mic = MicrophonePermission.status
            if mic != microphone { microphone = mic }
            let trusted = TextInjector.isTrusted
            if trusted != accessibility { accessibility = trusted }
        }
    }

    // MARK: Pages

    private var paneList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPane.allCases) { item in
                    Button {
                        router.settingsPane = item
                    } label: {
                        HStack(spacing: 10) {
                            SettingsIcon(pane: item, size: 24)
                            Text(item.title)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if needsAttention(item) {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 7, height: 7)
                                    .help("Something here needs you")
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(item == pane ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
        }
        .background(Color.primary.opacity(0.025))
    }

    private var paneHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            SettingsIcon(pane: pane, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title)
                    .font(.system(size: 22, weight: .semibold))
                Text(pane.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .general:
            SetupSection(token: hfToken, permissionsGranted: microphone == .authorized && accessibility)
            permissionsSection
            outputSection
        case .dictation:
            shortcutSection
            languageSection
        case .engines:
            engineSection
        case .writing:
            cleanupSection
            aiSection
        case .notetaker:
            notetakerSection
            transcribeSection
        case .performance:
            PerformanceSections(compareOnFile: { pickAudio = true })
        case .flowBar:
            flowBarSection
        case .clipboard:
            clipboardSection
        case .privacy:
            privateModeSection
            localProofSection
        case .storage:
            historySections
        }
    }

    /// A page where something is missing or broken.
    private func needsAttention(_ item: SettingsPane) -> Bool {
        switch item {
        case .general:
            return !engine.isInstalled || microphone != .authorized || !accessibility
        case .engines:
            if case .failed = engine.state { return true }
            return false
        default:
            return false
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        Section {
            PermissionRow(
                title: "Microphone",
                detail: "Navo listens only while you hold the dictation key or the Flow Bar is recording.",
                granted: microphone == .authorized
            ) {
                if microphone == .notDetermined {
                    Task { @MainActor in
                        _ = await MicrophonePermission.request()
                        microphone = MicrophonePermission.status
                    }
                } else {
                    openSystemSettings("Privacy_Microphone")
                }
            }
            PermissionRow(
                title: "Accessibility",
                detail: "Needed for the global dictation key and to paste text into the app you are using.",
                granted: accessibility
            ) {
                TextInjector.requestTrust()
                openSystemSettings("Privacy_Accessibility")
            }
        } header: {
            SectionTitle("Permissions", "lock.shield")
        } footer: {
            Text("After you rebuild Navo, macOS may ask for Accessibility again: remove Navo from the list and add it back.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Shortcut

    private var shortcutSection: some View {
        Section {
            Picker("Push-to-talk key", selection: $settings.pushToTalkKey) {
                ForEach(PushToTalkKey.allCases) { key in
                    Text(key.title).tag(key)
                }
            }
            SettingToggle(
                "Show the text while you talk",
                detail: "The words appear in a small card above the Flow Bar as you speak, and long dictations are written as you go, so they are in almost as soon as you let go.",
                isOn: $settings.liveDictation
            )
            SettingToggle(
                "Keep talking while Navo writes",
                detail: "Had another thought? Press the key again while the last part is still being written. Navo keeps writing in the background, listens again, and pastes everything together, in order, once it is all done.",
                isOn: $settings.keepTalkingWhileProcessing
            )
            SettingToggle(
                "Play sounds",
                detail: "A short sound when recording starts and stops.",
                isOn: $settings.playSounds
            )
        } header: {
            SectionTitle("Dictation key", "keyboard")
        } footer: {
            Text(shortcutFooter)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Language

    private var languageSection: some View {
        Section {
            Picker("Dictation language", selection: $settings.language) {
                ForEach(settings.dictationEngine.languages) { language in
                    Text(language.title).tag(language)
                }
            }
            LabeledContent("Keyboard shortcut to switch it") {
                VStack(alignment: .trailing, spacing: 4) {
                    ShortcutRecorder(shortcut: $settings.languageShortcut, fallback: .languageDefault, taken: settings.clipboardShortcut)
                    LanguageShortcutProblem()
                }
            }
        } header: {
            SectionTitle("Language", "globe")
        } footer: {
            Text(languageFooter)
                .foregroundStyle(.secondary)
        }
    }

    private var languageFooter: String {
        let names = settings.dictationEngine.languages.map(\.name).joined(separator: ", then ")
        let switcher = settings.languageShortcut.map {
            "Press \($0.spelled) in any app, even while you talk, to go to the next language: \(names). "
        } ?? ""
        let chip = "The AR / EN button on the Flow Bar and the menu bar icon switch it too."
        switch settings.dictationEngine {
        case .cohere:
            return switcher + chip + " Cohere takes Arabic (any dialect, with English mixed in) or English."
        case .audar:
            return switcher + chip + " With Auto, Audar detects the language itself. It always picks up the dialect (Gulf, Egyptian, Levantine, Maghrebi, MSA) from the audio."
        case .whisper:
            return switcher + chip + " With Auto, Whisper detects the language itself, in any of its 100 languages. It is at its best in English."
        case .qwen3:
            return switcher + chip + " With Auto, Qwen3 detects the language itself, in any of its 30 languages. It is at its best in English and Chinese."
        }
    }

    private var shortcutFooter: String {
        keyFooter
    }

    private var keyFooter: String {
        switch settings.pushToTalkKey {
        case .off:
            return "Use the Flow Bar or the menu bar icon to start dictating."
        case .fn:
            return "Hold fn to talk, double-tap for hands-free, Esc to cancel. Set System Settings > Keyboard > \"Press 🌐 key to\" to \"Do Nothing\" so macOS does not react to it."
        default:
            return "Hold \(settings.pushToTalkKey.shortName) to talk and release to insert. Double-tap it for hands-free mode, tap again to finish. Esc cancels."
        }
    }

    // MARK: Engines

    private var engineSection: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(engine.state.label)
                }
            }
            if case .failed(let message) = engine.state {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let problem = engine.details?.workerError {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            ForEach(SpeechEngine.allCases) { speech in
                SpeechEngineRow(speech: speech, token: $hfToken)
            }

            Picker("Free memory when idle", selection: Binding(
                get: { settings.idleMinutes },
                set: { engine.setIdleMinutes($0) }
            )) {
                ForEach(Self.idleChoices, id: \.self) { minutes in
                    Text(idleLabel(minutes)).tag(minutes)
                }
            }
            LabeledContent("Memory now") {
                HStack(spacing: 10) {
                    Text(memorySummary)
                        .foregroundStyle(.secondary)
                    FreeMemoryButton()
                }
            }

            if engine.state == .installing {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: engine.installProgress)
                    Text(engine.installStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                SecureField("Hugging Face token", text: $hfToken, prompt: Text("Only for Cohere: hf_… The other models need no token."))
                HStack {
                    Button(engine.isInstalled ? "Reinstall / update" : "Install local engine") {
                        engine.install(huggingFaceToken: hfToken)
                        showLog = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.isBusy)
                    if engine.isInstalled {
                        if engine.state == .stopped {
                            Button("Start") { engine.start() }
                        } else {
                            Button(engine.state.canDictate ? "Restart" : "Start again") { engine.restart() }
                        }
                        Button("Stop") { engine.stop() }
                            .disabled(engine.state == .stopped)
                    }
                    Spacer()
                    Button("Compare on a file…") { pickAudio = true }
                        .disabled(!engine.isRunning)
                        .help("Run an audio file through the engines that are on and see their transcripts side by side")
                    Button("Engine log") { engine.openLog() }
                        .buttonStyle(.link)
                }
            }

            if !engine.installLog.isEmpty {
                DisclosureGroup("Installer output", isExpanded: $showLog) {
                    InstallLogView(lines: engine.installLog)
                }
            }

            DisclosureGroup("Advanced") {
                ModelIDField(title: "Cohere model", value: $settings.asrModel, fallback: AppSettings.defaultASRModel)
                ModelIDField(title: "Audar model", value: $settings.audarModel, fallback: SpeechEngine.audar.defaultModel)
                ModelIDField(title: "Whisper model", value: $settings.whisperModel, fallback: SpeechEngine.whisper.defaultModel)
                ModelIDField(title: "Qwen3 model", value: $settings.qwen3Model, fallback: SpeechEngine.qwen3.defaultModel)
                TextField("Engine port", value: $settings.enginePort, format: .number.grouping(.never))
                Text("Changes apply after Restart. Models load from the local Hugging Face cache; a new model needs Download or Reinstall.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionTitle("Speech engines, on this Mac", "waveform")
        } footer: {
            Text("Two engines can be on at once: the one marked Dictation, which is always on, and one more. Turn one off to turn another on. Models load only when they are needed: when you start talking, compare, or another app sends audio to \(settings.engineBaseURL.absoluteString)/cohere/v1, /audar/v1, /whisper/v1 or /qwen3/v1. After the idle time they leave memory and the engine sleeps at a few dozen MB. The first dictation after a sleep takes a few seconds longer.")
                .foregroundStyle(.secondary)
        }
    }

    private var memorySummary: String {
        guard let details = engine.details else { return "Engine not running" }
        let amount = ProcessMemory.format(details.memoryBytes)
        return details.sleeping ? "\(amount), models asleep" : "\(amount), models loaded"
    }

    private func idleLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Never, keep models loaded"
        case 60: return "After 1 hour"
        default: return "After \(minutes) minutes"
        }
    }

    private var statusColor: Color {
        switch engine.state {
        case .ready: return .green
        case .sleeping: return .blue
        case .failed: return .red
        case .notInstalled: return .gray
        default: return .orange
        }
    }

    // MARK: Cleanup

    private var cleanupSection: some View {
        Section {
            Picker("Cleanup", selection: $settings.cleanupMode) {
                ForEach(CleanupMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            switch settings.cleanupMode {
            case .local:
                ModelIDField(title: "Local model", value: $settings.localLLMModel, fallback: AppSettings.defaultLLMModel)
                LabeledContent("Model status") {
                    Text(engine.llmLoaded != nil ? "Loaded" : (engine.llmAvailable ? "Downloaded" : "Not downloaded, run Reinstall"))
                        .foregroundStyle(.secondary)
                }
            case .custom:
                TextField("Server URL", text: $settings.customBaseURL, prompt: Text("http://localhost:11434/v1"))
                TextField("Model", text: $settings.customModel, prompt: Text("qwen3:8b"))
            case .off:
                EmptyView()
            }
        } header: {
            SectionTitle("Cleanup after each dictation", "wand.and.stars")
        } footer: {
            Text("Removes fillers and self-corrections and fixes punctuation, without translating or changing your dialect. If cleanup fails, Navo inserts the raw transcript instead.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Flow Bar

    private var flowBarSection: some View {
        Section {
            Picker("Show the Flow Bar", selection: $settings.flowBarAlwaysVisible) {
                Text("Always").tag(true)
                Text("Only while you dictate").tag(false)
            }
            if settings.flowBarAlwaysVisible {
                if let until = settings.flowBarHiddenUntil, until > Date() {
                    HStack {
                        Text("Hidden until \(until.formatted(date: .omitted, time: .shortened))")
                        Spacer()
                        Button("Show now") { settings.flowBarHiddenUntil = nil }
                    }
                } else {
                    HStack {
                        Text("Hide it for a while")
                        Spacer()
                        Menu("Hide for") {
                            ForEach(FlowBarPause.allCases) { pause in
                                Button(pause.title) { settings.flowBarHiddenUntil = pause.until() }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            Picker("Position", selection: $settings.flowBarEdge) {
                ForEach(FlowBarEdge.allCases) { edge in
                    Text(edge.title).tag(edge)
                }
            }
        } header: {
            SectionTitle("Flow Bar", "capsule.bottomhalf.filled")
        } footer: {
            Text("Move the pointer close to the bubble to open it. Drag its handle to the bottom, left or right edge of any screen. When it is hidden it still appears while you dictate, and hides again when the text is in.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Output

    private var outputSection: some View {
        Section {
            SettingToggle(
                "Paste into the app you are using",
                detail: "The text goes where your cursor is. Off: it is only copied, and you paste it with ⌘V.",
                isOn: $settings.autoPaste
            )
            SettingToggle(
                "Put my clipboard back after pasting",
                detail: "Navo pastes through the clipboard; this restores what you had copied before.",
                isOn: $settings.restoreClipboard
            )
            .disabled(!settings.autoPaste)
            SettingToggle(
                "Open Navo at login",
                detail: "So the dictation key works as soon as you log in.",
                isOn: $launchAtLogin
            )
                .onChange(of: launchAtLogin) { _, enabled in
                    setLaunchAtLogin(enabled)
                }
            if let launchError {
                Text(launchError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            SectionTitle("Text and startup", "text.cursor")
        }
    }

    // MARK: AI writing

    private var aiSection: some View {
        Section {
            ForEach(WritingModel.allCases) { model in
                WritingModelRow(model: model)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use a model you already have")
                    Text("From LM Studio or any folder, MLX or GGUF. Navo uses it where it is: nothing is downloaded twice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add a model…") { addingModel = true }
                    .disabled(!engine.isInstalled)
                    .help(engine.isInstalled ? "Pick one from LM Studio or choose a folder" : "Install the local engine first")
            }
            WritingTestRow()
            DisclosureGroup("Advanced") {
                ModelIDField(title: "Gemma model", value: $settings.gemmaModel, fallback: WritingModel.gemma.defaultModel)
                ModelIDField(title: "Llama model", value: $settings.llamaModel, fallback: WritingModel.llama.defaultModel)
                Text("Hugging Face ids or folders of MLX builds. Changes apply after Restart under Speech engines; a new model needs Download. A larger model can need more than 6 GB of memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionTitle("AI writing, on this Mac", "sparkles")
        } footer: {
            Text("The AI button in Home, Notetaker and Transcribe summarizes a text or rewrites it as an email, a text message or a clean rewrite, in English or Arabic whatever the text is in. An open language model on this Mac writes it: the text never leaves the Mac, and it works with no internet.\n\nMemory: a language model and a speech model are never loaded together. When you ask for a summary the speech models step out of memory, the language model loads, writes and leaves again when you close the AI panel (or a minute after an answer); the speech model comes back the next time you dictate. A recording that is running keeps recording, and its live text waits until the summary is done. Gemma and Llama stay under 6 GB; a model you add uses what its size needs.\n\nModels you add run where they are: an MLX folder on MLX, a GGUF file on llama.cpp (added to Navo's engine the first time). Removing one only takes it out of Navo; its files stay.\n\nOther apps can use them through the local API: \(settings.engineBaseURL.absoluteString)/gemma/v1, /llama/v1 and /custom-…/v1 for the ones you add (docs/API-LLM.md).")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Clipboard

    private var clipboardSection: some View {
        Section {
            Toggle("Keep the text I copy in any app", isOn: $settings.clipboardHistory)
            Picker("Keep it for", selection: $settings.clipboardDays) {
                ForEach(AppSettings.clipboardDayChoices, id: \.self) { days in
                    Text(ClipboardView.dayLabel(days)).tag(days)
                }
            }
            .disabled(!settings.clipboardHistory)
            LabeledContent("Quick list of recent copies, in any app") {
                VStack(alignment: .trailing, spacing: 4) {
                    ShortcutRecorder(shortcut: $settings.clipboardShortcut, fallback: .clipboardDefault, taken: settings.languageShortcut)
                    QuickPasteShortcutProblem()
                }
            }
        } header: {
            SectionTitle("Clipboard history", "doc.on.clipboard")
        } footer: {
            Text("The shortcut opens the last 10 copies over the app you are in, like Spotlight: type to search them all, then Return, a click or ⌘1 to ⌘0 pastes. Shown in the Clipboard tab too. Plain text only, stored on this Mac. Starred items stay until you delete them. Copies from password managers are never kept, nor copies over \(ClipboardStore.maxCharacters.formatted()) characters; the newest \(ClipboardStore.maxItems.formatted()) items are kept. Turning this off keeps what is there; the Clipboard tab can clear it.")
                .foregroundStyle(.secondary)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
    }

    // MARK: Private mode

    private var privateModeSection: some View {
        Section {
            SettingToggle(
                "Hide Navo from screen sharing and recordings",
                detail: "When you share your screen or record it, the others do not see Navo: not this window, not the Flow Bar, not the text while you talk, not the clipboard list. You still see everything as usual.",
                isOn: $settings.privateMode
            )
            if settings.privateMode {
                Label("On. Navo's windows are left out of screen shares, screenshots and screen recordings.", systemImage: "eye.slash.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        } header: {
            SectionTitle("Private mode", "eye.slash")
        } footer: {
            Text("Works in apps that share or record the screen through macOS (Zoom, Google Meet, Microsoft Teams, Slack, QuickTime, the screenshot tool). The menu bar icon belongs to macOS's menu bar and still shows when the whole screen is shared. Also in the menu bar menu: Hide Navo from Screen Sharing.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Notetaker and Transcribe

    private var notetakerSection: some View {
        Section {
            Picker("Record", selection: $settings.meetingSource) {
                ForEach(MeetingSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            Picker("Turn it into text", selection: $settings.meetingTranscription) {
                ForEach(MeetingTranscription.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if settings.meetingTranscription == .live {
                LabeledContent("How fast the text comes") {
                    PieceLengthPicker()
                }
            }
            Picker("Save the audio to disk every", selection: $settings.meetingPartMinutes) {
                Text("3 minutes").tag(3)
                Text("5 minutes").tag(5)
            }
        } header: {
            SectionTitle("Notetaker", "record.circle")
        } footer: {
            Text("Live, as you speak: each sentence appears a moment after it is said, and the one being said shows in grey as it comes, so you can follow the meeting as it happens. The longer choices write bigger parts at once. Saving the audio in parts means a crash or a full disk loses at most a few minutes.")
                .foregroundStyle(.secondary)
        }
    }

    private var transcribeSection: some View {
        Section {
            LabeledContent("Engine and language") {
                TranscriptionOptions(pieceLabel: nil)
            }
            LabeledContent("Show the text") {
                PieceLengthPicker()
            }
            SettingToggle(
                "Transcribe files as soon as they are added",
                detail: "Files you add, paste or share to Navo are turned into text right away. Off: press Transcribe on each one.",
                isOn: $settings.autoTranscribeImports
            )
        } header: {
            SectionTitle("Transcribe and long recordings", "tray.and.arrow.down")
        } footer: {
            Text("Notetaker and Transcribe share the engine, the language and how fast the text comes. Live on a file shows new text every few seconds while it is written.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Proof it runs locally

    private var localProofSection: some View {
        Section {
            if let details = engine.details {
                LabeledContent("Runs on") {
                    Text("This Mac, \(details.device ?? "Apple Silicon")")
                }
                LabeledContent("Network address") {
                    Text(details.isLoopbackOnly
                        ? "\(details.host):\(details.port), reachable only from this Mac"
                        : "\(details.host):\(details.port)")
                }
                LabeledContent("Internet") {
                    Text(details.offline ? "Not used, models load in offline mode" : "Allowed")
                }
                LabeledContent("Engine memory") {
                    Text(engineMemoryDetail(details))
                }
                LabeledContent("Navo app memory") {
                    NavoMemoryText()
                }
                LabeledContent("\(settings.dictationEngine.shortName) model on disk") {
                    HStack(spacing: 8) {
                        Text(ProcessMemory.formatFile(details.modelBytes))
                        if let path = details.modelPath {
                            Button("Show") { reveal(path) }
                                .buttonStyle(.link)
                        }
                    }
                }
                LabeledContent("Cleanup model on disk") {
                    HStack(spacing: 8) {
                        Text(details.llmBytes == nil ? "Not downloaded" : ProcessMemory.formatFile(details.llmBytes))
                        if let path = details.llmPath {
                            Button("Show") { reveal(path) }
                                .buttonStyle(.link)
                        }
                    }
                }
                LabeledContent("This session") {
                    Text("\(details.transcriptions) transcriptions"
                        + (details.lastProcessingMs.map { String(format: ", the last took %.1f s", Double($0) / 1000) } ?? ""))
                }
                Button("Open Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
            } else {
                Text("Start the local engine to see where it runs and how much memory it uses.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionTitle("Proof it runs on this Mac", "checkmark.shield")
        } footer: {
            Text("Quickest test: turn Wi-Fi off and dictate. In Activity Monitor the engine is two Python processes with the numbers shown above: a small gateway that is always there, and the models process, which exists only while models are in memory. Their Memory columns add up to Engine memory.")
                .foregroundStyle(.secondary)
        }
    }

    private func engineMemoryDetail(_ details: LocalEngineManager.Details) -> String {
        var text = ProcessMemory.format(details.memoryBytes)
        if let pid = details.pid {
            text += ", gateway process \(pid)"
        }
        if let worker = details.workerPid {
            text += ", models in process \(worker)"
        } else {
            text += ", models asleep"
        }
        return text
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: History, recordings and deletion

    @ViewBuilder
    private var historySections: some View {
        Section {
            LabeledContent("History") {
                Text("\(store.stats.totalDictations) dictations, \(TextTools.compactNumber(store.stats.totalWords)) words")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Recordings") {
                Text("\(store.audioFileCount) files, \(ProcessMemory.formatFile(store.audioBytes))")
                    .foregroundStyle(.secondary)
            }
            SettingToggle(
                "Keep the recordings",
                detail: "To play a dictation back or transcribe it again later. Off: each recording is erased as soon as it is transcribed.",
                isOn: $settings.keepAudio
            )
            Picker("Keep recordings for", selection: retentionBinding(isText: false)) {
                ForEach(Self.retentionChoices, id: \.self) { days in
                    Text(retentionLabel(days)).tag(days)
                }
            }
            Picker("Keep text for", selection: retentionBinding(isText: true)) {
                ForEach(Self.retentionChoices, id: \.self) { days in
                    Text(retentionLabel(days)).tag(days)
                }
            }
        } header: {
            SectionTitle("History and recordings", "clock.arrow.circlepath")
        } footer: {
            Text("Recordings are WAV files in ~/Library/Application Support/Navo/Audio. With Keep recordings off, each recording is erased right after it is transcribed. Automatic cleanup runs at launch and every hour.")
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Delete now?",
            isPresented: Binding(get: { retentionChange != nil }, set: { if !$0 { retentionChange = nil } }),
            presenting: retentionChange
        ) { change in
            Button("Delete \(change.count) \(change.isText ? "dictations" : "recordings") permanently", role: .destructive) {
                applyRetention(isText: change.isText, days: change.days)
            }
            Button("Cancel", role: .cancel) {}
        } message: { change in
            Text("Keeping only the last \(dayLabel(change.days)) permanently erases \(change.count) older \(change.isText ? "dictations and their recordings" : "recordings") from this Mac. This cannot be undone.")
        }

        Section {
            Picker("Delete", selection: $purgeMode) {
                ForEach(PurgeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if purgeMode != .deleteAll {
                Picker("Days", selection: $purgeDays) {
                    ForEach(Self.dayChoices, id: \.self) { days in
                        Text(dayLabel(days)).tag(days)
                    }
                }
            }
            Picker("What", selection: $purgeScope) {
                ForEach(PurgeScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(purgeSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete…", role: .destructive) {
                    purgeCount = store.purgeCount(mode: purgeMode, days: purgeDays, scope: purgeScope)
                    if purgeCount == 0 {
                        purgeResult = "Nothing matches, nothing was deleted."
                    } else {
                        confirmPurge = true
                    }
                }
            }
            if let purgeResult {
                Text(purgeResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionTitle("Delete history", "trash")
        } footer: {
            Text("Deletion is permanent: recordings are erased from disk (not moved to the Trash) and deleted text is overwritten inside the database file, which is then compacted.")
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Permanently delete \(purgeCount) \(purgeScope == .audioOnly ? "recordings" : "dictations")?", isPresented: $confirmPurge) {
            Button("Delete permanently", role: .destructive) {
                let deleted = store.purge(mode: purgeMode, days: purgeDays, scope: purgeScope)
                purgeResult = "Deleted \(deleted) \(purgeScope == .audioOnly ? "recordings" : "dictations") permanently."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(purgeSummary) This cannot be undone.")
        }

        Section {
            HStack {
                Button("Show data folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.database])
                }
                Spacer()
                Text("Version " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(Paths.isDemo
                ? "Demo: this is sample data, kept apart from your own. Quit and open Navo again to see your history."
                : "Everything stays on this Mac: ~/Library/Application Support/Navo")
                .foregroundStyle(.secondary)
        }
    }

    private var purgeSummary: String {
        let cutoff = HistoryStore.cutoff(days: purgeDays)
        let date = cutoff.formatted(date: .abbreviated, time: .omitted)
        let what = purgeScope == .audioOnly ? "recordings" : "dictations and their recordings"
        switch purgeMode {
        case .keepRecent:
            return "Deletes \(what) from before \(date) and keeps the last \(dayLabel(purgeDays))."
        case .deleteRecent:
            return "Deletes \(what) from the last \(dayLabel(purgeDays)), since \(date)."
        case .deleteAll:
            return "Deletes all \(what)."
        }
    }

    private func dayLabel(_ days: Int) -> String {
        switch days {
        case 1: return "day (today)"
        case 7: return "week"
        case 14: return "2 weeks"
        default: return "\(days) days"
        }
    }

    private func retentionLabel(_ days: Int) -> String {
        switch days {
        case 0: return "Forever"
        case 1: return "1 day"
        case 7: return "1 week"
        case 14: return "2 weeks"
        default: return "\(days) days"
        }
    }

    private func retentionBinding(isText: Bool) -> Binding<Int> {
        Binding(
            get: { isText ? settings.autoDeleteTextDays : settings.autoDeleteAudioDays },
            set: { days in requestRetention(isText: isText, days: days) }
        )
    }

    /// Asks before a new retention setting erases existing items.
    private func requestRetention(isText: Bool, days: Int) {
        let current = isText ? settings.autoDeleteTextDays : settings.autoDeleteAudioDays
        guard days != current else { return }
        let count = days == 0 ? 0 : store.purgeCount(mode: .keepRecent, days: days, scope: isText ? .textAndAudio : .audioOnly)
        if count == 0 {
            applyRetention(isText: isText, days: days)
        } else {
            retentionChange = RetentionChange(isText: isText, days: days, count: count)
        }
    }

    private func applyRetention(isText: Bool, days: Int) {
        if isText {
            settings.autoDeleteTextDays = days
        } else {
            settings.autoDeleteAudioDays = days
        }
        store.applyRetention(textDays: settings.autoDeleteTextDays, audioDays: settings.autoDeleteAudioDays)
    }

    private func openSystemSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct SpeechEngineRow: View {
    let speech: SpeechEngine
    @Binding var token: String

    @EnvironmentObject private var engine: LocalEngineManager
    @EnvironmentObject private var settings: AppSettings

    private var info: LocalEngineManager.EngineInfo? { engine.engines[speech] }
    private var isDictation: Bool { settings.dictationEngine == speech }
    /// Off, and two others are on: it can't be turned on until one of them is off.
    private var noRoom: Bool { !settings.canEnable(speech) }
    private var noRoomText: String {
        "\(settings.enabledEnginesText) are on. Turn one of them off to use \(speech.shortName) (\(AppSettings.maxEnabledEngines) engines at most)."
    }

    /// A gated model that is not on this Mac: its token goes right here.
    private var needsToken: Bool {
        speech.isGated && info.map { !$0.downloaded } == true
    }

    private var color: Color {
        guard let info else { return .gray }
        switch info.status {
        case "ready": return .green
        case "loading": return .orange
        case "asleep": return info.downloaded ? .blue : .gray
        case "error": return info.downloaded ? .red : .gray
        default: return .gray
        }
    }

    private var statusLine: String {
        guard let info else {
            return engine.isInstalled ? "Start the local engine to see this engine." : "Install the local engine first."
        }
        var parts = [info.label]
        if info.isReady, let bytes = info.modelBytes {
            parts.append("\(ProcessMemory.formatFile(bytes)) model in memory")
        }
        if info.transcriptions > 0 {
            parts.append("\(info.transcriptions) \(info.transcriptions == 1 ? "transcription" : "transcriptions") this session")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(speech.title)
                    .fontWeight(.medium)
                if isDictation {
                    Text("Dictation")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Spacer()
                controls
            }
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(speech.summary)
                .font(.caption)
                .foregroundStyle(.tertiary)
            if needsToken {
                HStack(spacing: 8) {
                    SecureField("Hugging Face token", text: $token, prompt: Text("hf_… a Read token, needed once to download"))
                        .textFieldStyle(.roundedBorder)
                    Link("Get a token", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                        .font(.caption)
                    Link("Accept the terms", destination: speech.modelPage)
                        .font(.caption)
                }
            }
            if engine.downloading == speech {
                ProgressView(value: engine.installProgress)
                Text(engine.installStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let failure = engine.downloadErrors[speech] {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let info, info.downloaded, noRoom {
                Text(noRoomText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let info, info.status == "error", info.downloaded, let failure = info.error {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var controls: some View {
        if let info {
            if !info.downloaded {
                Button(engine.downloading == speech ? "Downloading…" : "Download, \(SetupSection.gb(speech.downloadGB))") {
                    engine.download(speech, huggingFaceToken: token)
                }
                .disabled(engine.isBusy)
                .help(speech.isGated ? "Paste your Hugging Face token in the field under it first" : "Public model, no account or token needed")
            } else {
                if !isDictation {
                    Button("Use for dictation") { engine.useForDictation(speech) }
                        .disabled(!settings.canUseForDictation(speech))
                        .help(settings.canUseForDictation(speech) ? "Transcribe dictation with \(speech.shortName)" : noRoomText)
                }
                Toggle("On", isOn: Binding(
                    get: { settings.isEnabled(speech) },
                    set: { engine.setEnabled(speech, $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(isDictation || noRoom)
                .help(isDictation
                    ? "The dictation engine always stays on"
                    : (noRoom ? noRoomText : "Off frees its memory; the API answers 503 for it"))
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Allowed")
                    .foregroundStyle(.secondary)
            } else {
                Button("Allow", action: action)
            }
        }
    }
}

private struct InstallLogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("ERROR") ? Color.red : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .frame(height: 180)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            .onChange(of: lines.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}

// MARK: Parts that follow dictation

// Small views of their own: the dictation controller publishes the microphone level many times a
// second while you talk, and only these need to be drawn again for it, not the whole page.

private struct LanguageShortcutProblem: View {
    @EnvironmentObject private var dictation: DictationController

    var body: some View {
        if let problem = dictation.languageShortcutProblem {
            Text(problem)
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct FreeMemoryButton: View {
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var engine: LocalEngineManager

    var body: some View {
        Button("Free memory now") { engine.freeMemoryNow() }
            .disabled(!engine.isRunning || engine.details?.sleeping == true || dictation.phase.isBusy)
            .help("Unload every model now. They load again when you dictate or an app sends audio.")
    }
}

/// Navo's own memory use, updated every two seconds without redrawing the rest of Settings.
private struct NavoMemoryText: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            Text(ProcessMemory.format(ProcessMemory.navo))
        }
    }
}

private struct QuickPasteShortcutProblem: View {
    @EnvironmentObject private var quickPaste: QuickPasteController

    var body: some View {
        if let problem = quickPaste.shortcutProblem {
            Text(problem)
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: AI writing

/// One language model: whether it is downloaded and in memory, and the buttons to get or pick it.
private struct WritingModelRow: View {
    let model: WritingModel

    @EnvironmentObject private var engine: LocalEngineManager
    @EnvironmentObject private var settings: AppSettings

    private var info: LocalEngineManager.LLMInfo? { engine.llms[model] }
    private var downloaded: Bool { engine.isDownloaded(model) }
    private var chosen: Bool { settings.writingModel == model }

    private var color: Color {
        guard downloaded else { return .gray }
        switch info?.status {
        case "ready": return .green
        case "writing", "loading": return .orange
        case "error": return .red
        default: return .blue
        }
    }

    private var statusLine: String {
        guard engine.isInstalled else { return "Install the local engine first." }
        if model.isCustom && !downloaded {
            return "Not found where it was added. Was it moved or deleted?"
        }
        guard downloaded else { return "Not downloaded, \(SetupSection.gb(model.downloadGB))" }
        var parts = [info?.label ?? "Downloaded"]
        if let bytes = info?.modelBytes {
            parts.append("\(ProcessMemory.formatFile(bytes)) on disk")
        }
        if let peak = info?.peakMemoryBytes, peak > 0 {
            parts.append("most memory used \(ProcessMemory.format(UInt64(peak)))")
        }
        if let speed = info?.tokensPerSecond, speed > 0 {
            parts.append("\(Int(speed.rounded())) tokens a second")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(model.title)
                    .fontWeight(.medium)
                Text(model.maker)
                    .foregroundStyle(.secondary)
                if chosen {
                    Text("AI writing")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                if let custom = model.custom {
                    FormatBadge(format: custom.format)
                }
                Spacer()
                if model.isCustom {
                    if downloaded && !chosen {
                        Button("Use for AI writing") { settings.writingModel = model }
                    }
                    Button("Remove") {
                        settings.removeCustomModel(model.rawValue)
                        engine.customModelsChanged()
                    }
                    .help("Navo stops using it. Its files stay where they are, in LM Studio or your folder.")
                } else if !downloaded {
                    WritingDownloadButton(model: model)
                } else if !chosen {
                    Button("Use for AI writing") { settings.writingModel = model }
                }
            }
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.summary)
                .font(.caption)
                .foregroundStyle(.tertiary)
            if engine.downloadingModel == model {
                Text(engine.installStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model == .gemma && engine.gemmaNeedsEngineUpdate {
                Text("Gemma 4 needs a newer engine than the one installed. Click Reinstall / update under Speech engines: the models you have are kept.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let failure = engine.modelDownloadErrors[model] {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let info, info.status == "error", let failure = info.error {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Loads the chosen model, asks it for one sentence and shows how fast it was and how much
/// memory the engine used: the proof that it runs here and stays within its limit.
private struct WritingTestRow: View {
    @EnvironmentObject private var ai: AIWriter
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: LocalEngineManager
    @State private var testing = false
    @State private var passed: Bool?
    @State private var message = ""

    var body: some View {
        LabeledContent("Check that it works") {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    if testing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Test \(settings.writingModel.shortName)") { test() }
                        .disabled(testing || !engine.isDownloaded(settings.writingModel))
                        .help("Loads the model, asks for one sentence, and frees it again")
                }
                if let passed {
                    Label(message, systemImage: passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(passed ? Color.green : Color.orange)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func test() {
        testing = true
        passed = nil
        let model = settings.writingModel
        Task { @MainActor in
            do {
                let result = try await ai.test(model)
                passed = true
                message = "\(model.shortName) answered in \(String(format: "%.1f", result.seconds)) s"
                    + (result.stats.map { ", \($0)" } ?? "")
                    + ": \"\(result.reply)\""
            } catch {
                passed = false
                message = error.localizedDescription
            }
            testing = false
        }
    }
}

/// A model id field that says when what is typed can't be a model (for example text dictated into
/// it while it had the focus), and puts the default back.
private struct ModelIDField: View {
    let title: String
    @Binding var value: String
    let fallback: String

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(title, text: $value, prompt: Text(fallback))
                if value != fallback {
                    Button("Reset") { value = fallback }
                        .buttonStyle(.link)
                        .help("Back to \(fallback)")
                }
            }
            if let problem = settings.modelIDProblem(value) {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
