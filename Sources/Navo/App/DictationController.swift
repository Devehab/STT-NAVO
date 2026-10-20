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
    /// The text heard so far while you talk (live dictation), shown above the Flow Bar.
    @Published private(set) var liveText = LiveText()

    /// Asks the app to show the Hub on a section (used when permissions or the engine are missing).
    var onNeedsSetup: (() -> Void)?

    static let maxRecordingSeconds: Double = 600
    private static let tapThreshold: TimeInterval = 0.3
    private static let doubleTapWindow: UInt64 = 350_000_000
    private static let minimumSpeechRMS: Float = 0.003

    private let settings: AppSettings
    private let engine: LocalEngineManager
    private let store: HistoryStore
    private let metrics: MetricsStore?
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
    private var live: LiveDictation?
    private var cancellables = Set<AnyCancellable>()

    /// One dictation of a run. With "keep talking" on, the key can be pressed again while the last
    /// dictation is still being transcribed: each one is transcribed in the background, in order,
    /// and the run is pasted as one text when its last dictation is done.
    private final class Segment {
        let draft: Dictation
        let samples: [Float]
        /// The text written while it was spoken; dropped when the language changes afterwards.
        var live: LiveDictation?
        var outcome: Outcome?
        /// When the key was let go.
        let releasedAt = Date()
        var timing = Timing()

        init(draft: Dictation, samples: [Float], live: LiveDictation?) {
            self.draft = draft
            self.samples = samples
            self.live = live
        }
    }

    /// Where a dictation's time went after the key was let go (for the Performance page).
    private struct Timing {
        var transcribeMs = 0
        var computeMs: Int?
        var loadMs = 0
        var cleanupMs = 0
        /// Most of it was transcribed while it was spoken: only the end was left.
        var live = false
    }

    private enum Outcome {
        /// Transcribed and cleaned up; saved to the history when the run is pasted.
        case text(Dictation)
        /// No speech in it.
        case empty
        /// Kept in the history with its audio, to retry.
        case failed(Dictation, String)
    }

    /// The dictations waiting to be pasted together, oldest first.
    private var run: [Segment] = []
    private var runWorker: Task<Void, Never>?
    /// Goes up when the run starts over (the language changed): an older worker stops.
    private var runGeneration = 0
    /// The live text of the dictation being recorded (or just stopped), without the run before it.
    private var currentLive = LiveText()

    init(settings: AppSettings, engine: LocalEngineManager, store: HistoryStore, metrics: MetricsStore? = nil) {
        self.settings = settings
        self.engine = engine
        self.store = store
        self.metrics = metrics

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
        // From the shortcut, the Flow Bar, the menu bar or Settings alike.
        settings.$language
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.languageDidChange() }
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
        guard settings.dictationEngine.languages.contains(language), language != settings.language else { return }
        settings.language = language
        setLanguageAnnouncement(language)
    }

    /// The language changed. What you are saying now, and what you said that is not pasted yet,
    /// are transcribed again in the new language: no need to wait and dictate it again.
    private func languageDidChange() {
        if phase.isRecording {
            live?.restart()
        }
        redoRun()
    }

    /// Transcribes every dictation of the run again, from its recording (the text written while
    /// it was spoken was in the old language).
    private func redoRun() {
        guard !run.isEmpty else { return }
        runGeneration += 1
        runWorker?.cancel()
        runWorker = nil
        for segment in run {
            segment.live?.cancel()
            segment.live = nil
            segment.outcome = nil
        }
        currentLive = LiveText()
        publishLiveText()
        if !phase.isRecording { phase = .transcribing }
        startRunWorker()
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
            // The last dictation goes on in the background; this one is added to it.
            guard settings.keepTalkingWhileProcessing else { return }
            pressedAt = Date()
            beginRecording(handsFree: false)
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
            guard settings.keepTalkingWhileProcessing else { return }
            beginRecording(handsFree: true)
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
        startLive()
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
        endLive()
        recordingStartedAt = nil
        if !silently, settings.playSounds { Sounds.play(.cancel) }
        // Dictations from before this one are still on their way: they are pasted without it.
        guard run.isEmpty else {
            runContinues()
            return
        }
        if silently {
            phase = .idle
        } else {
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
        let live = self.live
        self.live = nil
        live?.cancel()
        recordingStartedAt = nil
        if settings.playSounds { Sounds.play(.stop) }

        guard recording.duration >= 0.4 else {
            currentLive = LiveText()
            if run.isEmpty {
                liveText = LiveText()
                phase = .idle
            } else {
                runContinues()
            }
            return
        }
        guard recording.peakRMS >= Self.minimumSpeechRMS else {
            currentLive = LiveText()
            if run.isEmpty {
                liveText = LiveText()
                show(.failed("No speech detected. Check your microphone."))
            } else {
                runContinues()
            }
            return
        }

        let id = UUID().uuidString
        let audioURL = Paths.audioDir.appendingPathComponent("\(id).wav")
        do {
            try WAVWriter.write(samples: recording.samples, sampleRate: Int(AudioRecorder.sampleRate), to: audioURL)
        } catch {
            if run.isEmpty {
                show(.failed("Could not save the recording: \(error.localizedDescription)"))
            } else {
                runContinues()
            }
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
        run.append(Segment(draft: draft, samples: recording.samples, live: live))
        phase = .transcribing
        startRunWorker()
    }

    // MARK: Runs of dictations

    /// Transcribes the dictations of the run one after the other, while new ones may be recorded.
    private func startRunWorker() {
        guard runWorker == nil else { return }
        let generation = runGeneration
        runWorker = Task { @MainActor [weak self] in
            while let self, generation == self.runGeneration, let segment = self.run.first(where: { $0.outcome == nil }) {
                // Most of a long dictation was transcribed while it was spoken: only the end is left.
                let finishing = Date()
                let early = await segment.live?.finish(samples: segment.samples)
                let finishMs = Int(Date().timeIntervalSince(finishing) * 1000)
                guard generation == self.runGeneration else { return }
                let (outcome, measured) = await self.transcribe(segment.draft, early: early)
                var timing = measured
                // The language changed meanwhile: a new worker transcribes it again.
                guard generation == self.runGeneration else { return }
                if let early, !early.text.isEmpty {
                    timing.transcribeMs = finishMs
                    timing.live = true
                }
                segment.outcome = outcome
                segment.timing = timing
                self.segmentFinished(segment)
            }
            guard let self, generation == self.runGeneration else { return }
            self.runWorker = nil
            self.deliverRunIfDone()
        }
    }

    private func segmentFinished(_ segment: Segment) {
        // The text of the dictations already done stays in view while you go on talking.
        if !phase.isRecording, run.last === segment {
            currentLive = LiveText()
        }
        publishLiveText()
    }

    /// A recording ended without adding to the run: wait for the run, or paste it if it is done.
    private func runContinues() {
        currentLive = LiveText()
        publishLiveText()
        if run.allSatisfy({ $0.outcome != nil }) {
            deliverRunIfDone()
        } else {
            phase = .transcribing
        }
    }

    /// Pastes the run once every dictation in it is done and none is being recorded.
    private func deliverRunIfDone() {
        guard !run.isEmpty, !phase.isRecording, runWorker == nil, run.allSatisfy({ $0.outcome != nil }) else { return }
        let segments = run
        run = []
        currentLive = LiveText()
        liveText = LiveText()

        var texts: [Dictation] = []
        var failures: [(Dictation, String)] = []
        for segment in segments {
            switch segment.outcome {
            case .text(let item): texts.append(item)
            case .failed(let item, let message): failures.append((item, message))
            case .empty, .none:
                if let path = segment.draft.audioPath {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
        }
        for (item, message) in failures {
            var failed = item
            failed.status = .failed
            failed.errorMessage = message
            store.save(failed) // keeps the audio so it can be retried from the history
        }
        guard !texts.isEmpty else {
            if failures.isEmpty {
                show(.failed("No speech detected"))
            } else {
                show(.failed("Transcription failed. Saved in History to retry."))
            }
            return
        }
        var item = texts.count == 1 ? texts[0] : merge(texts, segments: segments)
        if !settings.keepAudio, let path = item.audioPath {
            try? FileManager.default.removeItem(atPath: path)
            item.audioPath = nil
        }
        let measured = measure(item, segments: segments.filter { segment in texts.contains { $0.id == segment.draft.id } })
        item.latencyMs = measured.totalMs
        store.save(item)
        metrics?.record(measured)

        let words = "\(item.wordCount) \(item.wordCount == 1 ? "word" : "words")"
        let failedNote = failures.isEmpty ? "" : ", \(failures.count) part failed (in History)"
        switch TextInjector.insert(item.cleanText, autoPaste: settings.autoPaste, restoreClipboard: settings.restoreClipboard) {
        case .pasted:
            show(.done(words + failedNote), seconds: failures.isEmpty ? nil : 3)
        case .pastedAndCopied:
            show(.done("\(words), also on the clipboard" + failedNote), seconds: 2.5)
        case .copied(let message):
            if settings.playSounds { Sounds.play(.cancel) }
            show(.done(message), seconds: 5)
        }
    }

    /// How long the dictation took, from letting go of the key (the last one, in a run) to the text.
    private func measure(_ item: Dictation, segments: [Segment]) -> PerfRecord {
        let speech = SpeechEngine.from(historyName: item.engine ?? settings.dictationEngine.historyName)
        var record = PerfRecord(kind: .dictation, model: speech.rawValue, modelName: speech.title)
        record.refID = item.id
        record.audioSeconds = item.duration
        let released = segments.map(\.releasedAt).max() ?? Date()
        record.totalMs = Int(Date().timeIntervalSince(released) * 1000)
        record.transcribeMs = segments.reduce(0) { $0 + $1.timing.transcribeMs }
        let computes = segments.map(\.timing.computeMs)
        record.computeMs = computes.contains(where: { $0 == nil }) ? nil : computes.compactMap { $0 }.reduce(0, +)
        record.loadMs = segments.reduce(0) { $0 + $1.timing.loadMs }
        record.cleanupMs = segments.reduce(0) { $0 + $1.timing.cleanupMs }
        record.live = segments.contains { $0.timing.live }
        switch item.cleanup {
        case CleanupMode.local.rawValue: record.detail = "cleanup by the Navo engine"
        case CleanupMode.custom.rawValue: record.detail = "cleanup by your local server"
        default: break
        }
        if segments.count > 1 { record.detail = [record.detail, "\(segments.count) parts pasted together"].compactMap { $0 }.joined(separator: ", ") }
        return record
    }

    /// Several dictations of one run as one history item: their texts in order and, when the
    /// audio is kept, one recording of them all.
    private func merge(_ items: [Dictation], segments: [Segment]) -> Dictation {
        var merged = items[0]
        merged.duration = items.reduce(0) { $0 + $1.duration }
        merged.rawText = items.map(\.rawText).joined(separator: " ")
        merged.cleanText = items.map(\.cleanText).joined(separator: " ")
        merged.language = TextTools.detectLanguage(merged.cleanText)
        merged.wordCount = TextTools.wordCount(merged.cleanText)
        merged.latencyMs = items.last?.latencyMs
        let notes = Array(Set(items.compactMap(\.errorMessage)))
        merged.errorMessage = notes.isEmpty ? nil : notes.joined(separator: " ")
        let kept = Set(items.map(\.id))
        if let path = merged.audioPath {
            let samples = segments.filter { kept.contains($0.draft.id) }.flatMap(\.samples)
            if (try? WAVWriter.write(samples: samples, sampleRate: Int(AudioRecorder.sampleRate), to: URL(fileURLWithPath: path))) == nil {
                merged.audioPath = nil
            }
        }
        for item in items.dropFirst() {
            if let path = item.audioPath { try? FileManager.default.removeItem(atPath: path) }
        }
        return merged
    }

    /// Re-runs transcription on a saved recording from the history (for failed items or model changes).
    func retry(_ item: Dictation) {
        guard !phase.isRecording, !phase.isBusy, run.isEmpty, item.hasAudio else { return }
        var draft = item
        draft.status = .ok
        draft.errorMessage = nil
        phase = .transcribing
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.transcribe(draft, early: nil).0 {
            case .text(let done):
                var done = done
                if !self.settings.keepAudio, let path = done.audioPath {
                    try? FileManager.default.removeItem(atPath: path)
                    done.audioPath = nil
                }
                self.store.save(done)
                TextInjector.copy(done.cleanText)
                self.show(.done("Re-transcribed and copied"))
            case .empty:
                self.show(.failed("No speech detected"))
            case .failed(let failed, let message):
                self.fail(failed, message: message)
            }
        }
    }

    // MARK: Pipeline

    /// Transcribes one recording and cleans the text up. Nothing is saved or pasted here.
    private func transcribe(_ draft: Dictation, early: TranscriptionClient.Result?) async -> (Outcome, Timing) {
        var timing = Timing()
        var item = draft
        let started = Date()
        guard let audioPath = item.audioPath else {
            return (.failed(item, "The recording file is missing"), timing)
        }
        let audioURL = URL(fileURLWithPath: audioPath)

        guard await engine.waitUntilReady(timeout: 120) else {
            return (.failed(item, engine.state.userMessage.isEmpty ? "The local engine is not ready" : engine.state.userMessage), timing)
        }

        let speech = settings.dictationEngine
        do {
            let result: TranscriptionClient.Result
            if let early, !early.text.isEmpty {
                result = early
            } else {
                result = try await TranscriptionClient(baseURL: engine.baseURL(for: speech))
                    .transcribe(fileURL: audioURL, language: settings.language.rawValue)
                timing.transcribeMs = result.wallMs ?? 0
                timing.computeMs = result.computeMs
                timing.loadMs = result.loadMs ?? 0
            }
            guard !result.text.isEmpty else { return (.empty, timing) }
            item.rawText = result.text
            item.engine = speech.historyName + (result.backend.map { " (\($0))" } ?? "")

            if settings.cleanupMode != .off, !phase.isRecording { phase = .polishing }
            let cleaning = Date()
            let cleanup = await CleanupService().clean(raw: result.text, config: cleanupConfig(), vocabulary: store.vocabulary)
            timing.cleanupMs = Int(Date().timeIntervalSince(cleaning) * 1000)
            item.cleanText = cleanup.text
            item.cleanup = cleanup.mode
            item.errorMessage = cleanup.note // why cleanup was skipped, shown in History
            item.language = TextTools.detectLanguage(cleanup.text)
            item.wordCount = TextTools.wordCount(cleanup.text)
            item.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            item.status = .ok
            // The recording stays until the text is pasted: a change of language redoes it from there.
            return (.text(item), timing)
        } catch {
            return (.failed(item, error.localizedDescription), timing)
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
            return CleanupConfig(mode: .local, baseURL: engine.chatBaseURL, model: settings.cleanupModel)
        case .custom:
            return CleanupConfig(mode: .custom, baseURL: URL(string: settings.customBaseURL), model: settings.customModel)
        case .off:
            return CleanupConfig(mode: .off, baseURL: nil, model: "")
        }
    }

    // MARK: Live dictation

    private func startLive() {
        live?.cancel()
        live = nil
        currentLive = LiveText()
        publishLiveText()
        guard settings.liveDictation else { return }
        let session = LiveDictation(recorder: recorder) { [weak self] url in
            guard let self else { throw CancellationError() }
            let speech = self.settings.dictationEngine
            return try await TranscriptionClient(baseURL: self.engine.baseURL(for: speech))
                .transcribe(fileURL: url, language: self.settings.language.rawValue)
        }
        session.onChange = { [weak self, weak session] text in
            guard let self, let session, self.live === session else { return }
            self.currentLive = text
            self.publishLiveText()
        }
        live = session
        session.start()
    }

    private func endLive() {
        live?.cancel()
        live = nil
        currentLive = LiveText()
        publishLiveText()
    }

    /// The text above the Flow Bar: the dictations of the run that are done, then the one you are saying.
    private func publishLiveText() {
        let done = run.compactMap { segment -> String? in
            if case .text(let item) = segment.outcome { return item.cleanText }
            return nil
        }
        let settled = (done + [currentLive.settled]).filter { !$0.isEmpty }.joined(separator: " ")
        let next = LiveText(settled: settled, preview: currentLive.preview)
        if next != liveText { liveText = next }
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
