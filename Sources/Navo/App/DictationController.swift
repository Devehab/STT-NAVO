import AppKit
import AVFoundation
import Combine
import Foundation

enum DictationPhase: Equatable {
    case idle
    case recording(handsFree: Bool)
    case transcribing
    case polishing
    case done(String)
    case failed(String)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .transcribing, .polishing: return true
        default: return false
        }
    }
}

/// The dictation pipeline: hotkey -> microphone -> local speech engine -> cleanup -> paste -> history.
@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 20)

    /// Asks the app to show the Hub on a section (used when permissions or the engine are missing).
    var onNeedsSetup: (() -> Void)?

    static let maxRecordingSeconds: Double = 600
    private static let tapThreshold: TimeInterval = 0.3
    private static let doubleTapWindow: UInt64 = 350_000_000
    private static let minimumSpeechRMS: Float = 0.003

    private let settings: AppSettings
    private let engine: LocalEngineManager
    private let store: HistoryStore
    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyManager()
    private var languageShortcut: GlobalShortcut?
    /// Set when the language shortcut could not be registered (another app uses it).
    @Published private(set) var languageShortcutProblem: String?

    private var pressedAt: Date?
    private var ignoreNextRelease = false
    private var pendingTap: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    private var targetApp: NSRunningApplication?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings, engine: LocalEngineManager, store: HistoryStore) {
        self.settings = settings
        self.engine = engine
        self.store = store

        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            Task { @MainActor in
                self.pushLevel(level)
            }
        }
        hotkeys.onPress = { [weak self] in self?.keyPressed() }
        hotkeys.onRelease = { [weak self] in self?.keyReleased() }
        hotkeys.onOtherKey = { [weak self] in self?.otherKeyPressed() }
        hotkeys.onEscape = { [weak self] in self?.escapePressed() }

        settings.$pushToTalkKey
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartHotkeys() }
            .store(in: &cancellables)
        settings.$languageShortcut
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shortcut in self?.registerLanguageShortcut(shortcut) }
            .store(in: &cancellables)
    }

    func start() {
        restartHotkeys()
        registerLanguageShortcut(settings.languageShortcut)
    }

    // MARK: Language

    private func registerLanguageShortcut(_ shortcut: KeyShortcut?) {
        languageShortcut?.unregister()
        languageShortcut = nil
        languageShortcutProblem = nil
        guard let shortcut else { return }
        languageShortcut = GlobalShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            // The shortcut may use the push-to-talk key (Right Option in Control + Option + L).
            // Its key press never reaches the key monitor, so drop a recording that key just started.
            self?.otherKeyPressed()
            self?.cycleLanguage()
        }
        let taken = "\(shortcut.spelled) is already used by another app. Pick another one."
        if languageShortcut == nil {
            languageShortcutProblem = taken
        }
        languageShortcut?.onLost = { [weak self] in
            self?.languageShortcutProblem = taken
        }
    }

    /// Switches dictation to the next language its engine supports (Flow Bar, menu, shortcut).
    /// Applies to the recording in progress too: the language is read when it is sent.
    /// `announce` shows the new language on the Flow Bar (not needed when its chip was clicked).
    func cycleLanguage(announce: Bool = true) {
        let language = settings.cycleDictationLanguage()
        guard announce else { return }
        setLanguageAnnouncement(language)
    }

    func setLanguage(_ language: DictationLanguage) {
        guard settings.dictationEngine.languages.contains(language) else { return }
        settings.language = language
        setLanguageAnnouncement(language)
    }

    private func setLanguageAnnouncement(_ language: DictationLanguage) {
        switch phase {
        case .idle, .done, .failed:
            show(.done("Dictation language: \(language.name)"), seconds: 1.4)
        case .recording, .transcribing, .polishing:
            break // the recording pill shows the language
        }
    }

    func restartHotkeys() {
        hotkeys.start(key: settings.pushToTalkKey)
    }

    // MARK: Keyboard

    private func keyPressed() {
        switch phase {
        case .recording(let handsFree):
            if handsFree {
                // Tap while hands-free: finish.
                ignoreNextRelease = true
                stopAndProcess()
            } else if let pending = pendingTap {
                // Second tap of a double-tap: lock into hands-free mode.
                pending.cancel()
                pendingTap = nil
                ignoreNextRelease = true
                phase = .recording(handsFree: true)
            }
        case .transcribing, .polishing:
            return
        case .idle, .done, .failed:
            pressedAt = Date()
            beginRecording(handsFree: false)
        }
    }

    private func keyReleased() {
        if ignoreNextRelease {
            ignoreNextRelease = false
            return
        }
        guard case .recording(handsFree: false) = phase else { return }
        let held = Date().timeIntervalSince(pressedAt ?? Date())
        if held < Self.tapThreshold {
            // A quick tap: wait briefly for a second tap, otherwise throw the recording away.
            pendingTap = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: DictationController.doubleTapWindow)
                guard let self, !Task.isCancelled else { return }
                self.pendingTap = nil
                if case .recording(handsFree: false) = self.phase {
                    self.cancelRecording(silently: true)
                }
            }
        } else {
            stopAndProcess()
        }
    }

    /// Another of Navo's shortcuts was pressed. It may use the push-to-talk key (Right Option in
    /// Control + Option + V) and its key press never reaches the key monitor.
    func shortcutPressed() {
        otherKeyPressed()
    }

    /// The push-to-talk key was used as a modifier for a shortcut: drop the recording.
    private func otherKeyPressed() {
        guard case .recording(handsFree: false) = phase, let pressedAt,
              Date().timeIntervalSince(pressedAt) < 1.0 else { return }
        cancelRecording(silently: true)
    }

    private func escapePressed() {
        if phase.isRecording {
            cancelRecording(silently: false)
        }
    }

    // MARK: Actions (Flow Bar, menu bar)

    func toggleHandsFree() {
        switch phase {
        case .recording:
            stopAndProcess()
        case .transcribing, .polishing:
            return
        default:
            beginRecording(handsFree: true)
        }
    }

    func beginRecording(handsFree: Bool) {
        resetTask?.cancel()

        switch MicrophonePermission.status {
        case .authorized:
            break
        case .notDetermined:
            Task { @MainActor [weak self] in
                let granted = await MicrophonePermission.request()
                self?.show(.failed(granted ? "Microphone allowed. Try again." : "Microphone access was denied"))
            }
            return
        default:
            show(.failed("Allow microphone access for Navo in System Settings"))
            onNeedsSetup?()
            return
        }

        switch engine.state {
        case .notInstalled, .installing, .failed:
            show(.failed(engine.state.userMessage))
            onNeedsSetup?()
            return
        default:
            break // still loading is fine: the model will be ready by the time we stop
        }

        targetApp = NSWorkspace.shared.frontmostApplication
        FocusInspector.prepare(targetApp)
        do {
            try recorder.start()
        } catch {
            show(.failed(error.localizedDescription))
            return
        }
        levels = Array(repeating: 0, count: levels.count)
        recordingStartedAt = Date()
        phase = .recording(handsFree: handsFree)
        if settings.playSounds { Sounds.play(.start) }
        // Sleeping models start loading now, while the user is still talking.
        engine.wake(cleanup: settings.cleanupMode == .local)

        limitTask?.cancel()
        limitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DictationController.maxRecordingSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.phase.isRecording else { return }
            self.stopAndProcess()
        }
    }

    func cancelRecording(silently: Bool = false) {
        guard phase.isRecording else { return }
        limitTask?.cancel()
        pendingTap?.cancel()
        pendingTap = nil
        _ = recorder.stop()
        recordingStartedAt = nil
        if silently {
            phase = .idle
        } else {
            if settings.playSounds { Sounds.play(.cancel) }
            show(.done("Cancelled"))
        }
    }

    func stopAndProcess() {
        guard phase.isRecording else { return }
        limitTask?.cancel()
        pendingTap?.cancel()
        pendingTap = nil
        let startedAt = recordingStartedAt ?? Date()
        let recording = recorder.stop()
        recordingStartedAt = nil
        if settings.playSounds { Sounds.play(.stop) }

        guard recording.duration >= 0.4 else {
            phase = .idle
            return
        }
        guard recording.peakRMS >= Self.minimumSpeechRMS else {
            show(.failed("No speech detected. Check your microphone."))
            return
        }

        let id = UUID().uuidString
        let audioURL = Paths.audioDir.appendingPathComponent("\(id).wav")
        do {
            try WAVWriter.write(samples: recording.samples, sampleRate: Int(AudioRecorder.sampleRate), to: audioURL)
        } catch {
            show(.failed("Could not save the recording: \(error.localizedDescription)"))
            return
        }

        let draft = Dictation(
            id: id,
            createdAt: startedAt,
            duration: recording.duration,
            language: settings.language.rawValue,
            rawText: "",
            cleanText: "",
            appName: targetApp?.localizedName,
            appBundleID: targetApp?.bundleIdentifier,
            wordCount: 0,
            audioPath: audioURL.path,
            engine: nil,
            cleanup: nil,
            latencyMs: nil,
            status: .ok,
            errorMessage: nil
        )
        phase = .transcribing
        Task { @MainActor [weak self] in
            await self?.process(draft, insertIntoApp: true)
        }
    }

    /// Re-runs transcription on a saved recording from the history (for failed items or model changes).
    func retry(_ item: Dictation) {
        guard !phase.isRecording, !phase.isBusy, item.hasAudio else { return }
        var draft = item
        draft.status = .ok
        draft.errorMessage = nil
        phase = .transcribing
        Task { @MainActor [weak self] in
            await self?.process(draft, insertIntoApp: false)
        }
    }

    // MARK: Pipeline

    private func process(_ draft: Dictation, insertIntoApp: Bool) async {
        var item = draft
        let started = Date()
        guard let audioPath = item.audioPath else {
            show(.failed("The recording file is missing"))
            return
        }
        let audioURL = URL(fileURLWithPath: audioPath)

        guard await engine.waitUntilReady(timeout: 120) else {
            fail(item, message: engine.state.userMessage.isEmpty ? "The local engine is not ready" : engine.state.userMessage)
            return
        }

        let speech = settings.dictationEngine
        do {
            let result = try await TranscriptionClient(baseURL: engine.baseURL(for: speech))
                .transcribe(fileURL: audioURL, language: settings.language.rawValue)
            guard !result.text.isEmpty else {
                if insertIntoApp { try? FileManager.default.removeItem(at: audioURL) }
                show(.failed("No speech detected"))
                return
            }
            item.rawText = result.text
            item.engine = speech.historyName + (result.backend.map { " (\($0))" } ?? "")

            if settings.cleanupMode != .off { phase = .polishing }
            let cleanup = await CleanupService().clean(raw: result.text, config: cleanupConfig(), vocabulary: store.vocabulary)
            item.cleanText = cleanup.text
            item.cleanup = cleanup.mode
            item.errorMessage = cleanup.note // why cleanup was skipped, shown in History
            item.language = TextTools.detectLanguage(cleanup.text)
            item.wordCount = TextTools.wordCount(cleanup.text)
            item.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            item.status = .ok

            if !settings.keepAudio {
                try? FileManager.default.removeItem(at: audioURL)
                item.audioPath = nil
            }
            store.save(item)

            if insertIntoApp {
                let words = "\(item.wordCount) \(item.wordCount == 1 ? "word" : "words")"
                switch TextInjector.insert(item.cleanText, autoPaste: settings.autoPaste, restoreClipboard: settings.restoreClipboard) {
                case .pasted:
                    show(.done(words))
                case .pastedAndCopied:
                    show(.done("\(words), also on the clipboard"), seconds: 2.5)
                case .copied(let message):
                    if settings.playSounds { Sounds.play(.cancel) }
                    show(.done(message), seconds: 5)
                }
            } else {
                TextInjector.copy(item.cleanText)
                show(.done("Re-transcribed and copied"))
            }
        } catch {
            fail(item, message: error.localizedDescription)
        }
    }

    private func fail(_ draft: Dictation, message: String) {
        var item = draft
        item.status = .failed
        item.errorMessage = message
        store.save(item) // keeps the audio so it can be retried from the history
        show(.failed("Transcription failed. Saved in History to retry."))
    }

    private func cleanupConfig() -> CleanupConfig {
        switch settings.cleanupMode {
        case .local:
            return CleanupConfig(mode: .local, baseURL: engine.chatBaseURL, model: settings.localLLMModel)
        case .custom:
            return CleanupConfig(mode: .custom, baseURL: URL(string: settings.customBaseURL), model: settings.customModel)
        case .off:
            return CleanupConfig(mode: .off, baseURL: nil, model: "")
        }
    }

    // MARK: Helpers

    private func pushLevel(_ level: Float) {
        guard phase.isRecording else { return }
        var next = levels
        next.removeFirst()
        next.append(level)
        levels = next
    }

    private func show(_ newPhase: DictationPhase, seconds customSeconds: Double? = nil) {
        phase = newPhase
        resetTask?.cancel()
        var seconds: Double
        if case .failed = newPhase { seconds = 4 } else { seconds = 1.6 }
        if let customSeconds { seconds = customSeconds }
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.phase == newPhase else { return }
            self.phase = .idle
        }
    }
}

enum Sounds {
    enum Cue {
        case start, stop, cancel

        var name: String {
            switch self {
            case .start: return "Tink"
            case .stop: return "Pop"
            case .cancel: return "Bottle"
            }
        }
    }

    static func play(_ cue: Cue) {
        guard let sound = NSSound(named: NSSound.Name(cue.name)) else { return }
        sound.volume = 0.25
        sound.stop()
        sound.play()
    }
}
