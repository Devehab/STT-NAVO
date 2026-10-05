import AppKit
import Foundation

enum DictationLanguage: String, CaseIterable, Identifiable {
    case ar
    case en
    /// The model names the language itself (Audar, Whisper and Qwen3; not Cohere).
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ar: return "Arabic, any dialect, with English mixed in"
        case .en: return "English"
        case .auto: return "Auto: the model detects the language"
        }
    }

    var name: String {
        switch self {
        case .ar: return "Arabic"
        case .en: return "English"
        case .auto: return "Auto"
        }
    }

    /// For the Flow Bar and the menu bar.
    var badge: String {
        switch self {
        case .ar: return "AR"
        case .en: return "EN"
        case .auto: return "AUTO"
        }
    }
}

/// When a meeting recording gets its text.
enum MeetingTranscription: String, CaseIterable, Identifiable {
    case live
    case afterStop
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "While recording"
        case .afterStop: return "When I stop"
        case .manual: return "Only when I ask"
        }
    }
}

enum CleanupMode: String, CaseIterable, Identifiable {
    case local
    case custom
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "Local LLM in the Navo engine"
        case .custom: return "Another local server (Ollama, LM Studio)"
        case .off: return "Off, light cleanup only"
        }
    }
}

enum PushToTalkKey: String, CaseIterable, Identifiable {
    case rightOption
    case rightCommand
    case rightControl
    case fn
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: return "Right Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        case .rightControl: return "Right Control ⌃"
        case .fn: return "Fn / Globe 🌐"
        case .off: return "Off"
        }
    }

    var shortName: String {
        switch self {
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        case .fn: return "fn"
        case .off: return ""
        }
    }

    /// Virtual key codes reported in flagsChanged events.
    var keyCodes: Set<UInt16> {
        switch self {
        case .rightOption: return [61]
        case .rightCommand: return [54]
        case .rightControl: return [62]
        case .fn: return [63, 179]
        case .off: return []
        }
    }

    /// Device-dependent modifier bit (NX_DEVICER*KEYMASK) so left and right keys are told apart.
    var deviceMask: UInt {
        switch self {
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        case .fn: return NSEvent.ModifierFlags.function.rawValue
        case .off: return 0
        }
    }
}

enum FlowBarEdge: String, CaseIterable, Identifiable {
    case bottom
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: return "Bottom"
        case .left: return "Left edge"
        case .right: return "Right edge"
        }
    }
}

/// UserDefaults-backed preferences.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let defaultASRModel = "CohereLabs/cohere-transcribe-arabic-07-2026"
    static let defaultLLMModel = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

    private enum Key {
        static let language = "language"
        static let pushToTalkKey = "pushToTalkKey"
        static let cleanupMode = "cleanupMode"
        static let asrModel = "asrModel"
        static let localLLMModel = "localLLMModel"
        static let customBaseURL = "customBaseURL"
        static let customModel = "customModel"
        static let enginePort = "enginePort"
        static let autoPaste = "autoPaste"
        static let restoreClipboard = "restoreClipboard"
        static let keepAudio = "keepAudio"
        static let playSounds = "playSounds"
        static let flowBarAlwaysVisible = "flowBarAlwaysVisible"
        static let flowBarEdge = "flowBarEdge"
        static let flowBarPosition = "flowBarPosition"
        static let hasOnboarded = "hasOnboarded"
        static let autoDeleteTextDays = "autoDeleteTextDays"
        static let autoDeleteAudioDays = "autoDeleteAudioDays"
        static let dictationEngine = "dictationEngine"
        static let cohereEnabled = "cohereEnabled"
        static let audarEnabled = "audarEnabled"
        static let audarModel = "audarModel"
        static let whisperEnabled = "whisperEnabled"
        static let whisperModel = "whisperModel"
        static let qwen3Enabled = "qwen3Enabled"
        static let qwen3Model = "qwen3Model"
        static let idleMinutes = "engineIdleMinutes"
        static let meetingSource = "meetingSource"
        static let meetingPartMinutes = "meetingPartMinutes"
        static let jobEngine = "jobEngine"
        static let jobLanguage = "jobLanguage"
        static let autoTranscribeRecordings = "autoTranscribeRecordings" // replaced by meetingTranscription
        static let autoTranscribeImports = "autoTranscribeImports"
        static let meetingTranscription = "meetingTranscription"
        static let pieceSeconds = "transcriptionPieceSeconds"
        static let languageShortcut = "languageShortcut" // the old preset list, read once
        static let languageKeys = "languageShortcutKeys"
        static let clipboardHistory = "clipboardHistory"
        static let clipboardKeys = "clipboardShortcutKeys"
        static let writingModel = "writingModel"
        static let gemmaModel = "gemmaModel"
        static let llamaModel = "llamaModel"
        static let clipboardDays = "clipboardDays"
    }

    static let pieceChoices = [30, 60, 120, 180, 300]
    /// Speech engines that can be on at once (the dictation engine counts). More would crowd
    /// the Mac's memory; the engine refuses a third one too.
    static let maxEnabledEngines = 2
    static let clipboardDayChoices = [1, 3, 7, 14, 30, 60]

    private let defaults = UserDefaults.standard

    /// Dictation language. Kept to one the dictation engine supports (Cohere has no Auto).
    @Published var language: DictationLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    @Published var pushToTalkKey: PushToTalkKey { didSet { defaults.set(pushToTalkKey.rawValue, forKey: Key.pushToTalkKey) } }
    @Published var cleanupMode: CleanupMode { didSet { defaults.set(cleanupMode.rawValue, forKey: Key.cleanupMode) } }
    @Published var asrModel: String { didSet { defaults.set(asrModel, forKey: Key.asrModel) } }
    @Published var localLLMModel: String { didSet { defaults.set(localLLMModel, forKey: Key.localLLMModel) } }
    @Published var customBaseURL: String { didSet { defaults.set(customBaseURL, forKey: Key.customBaseURL) } }
    @Published var customModel: String { didSet { defaults.set(customModel, forKey: Key.customModel) } }
    @Published var enginePort: Int { didSet { defaults.set(enginePort, forKey: Key.enginePort) } }
    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: Key.autoPaste) } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: Key.restoreClipboard) } }
    @Published var keepAudio: Bool { didSet { defaults.set(keepAudio, forKey: Key.keepAudio) } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    @Published var flowBarAlwaysVisible: Bool { didSet { defaults.set(flowBarAlwaysVisible, forKey: Key.flowBarAlwaysVisible) } }
    @Published var flowBarEdge: FlowBarEdge { didSet { defaults.set(flowBarEdge.rawValue, forKey: Key.flowBarEdge) } }
    @Published var flowBarPosition: Double { didSet { defaults.set(flowBarPosition, forKey: Key.flowBarPosition) } }
    @Published var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: Key.hasOnboarded) } }
    /// Automatic cleanup: keep only the last N days (0 = keep forever).
    @Published var autoDeleteTextDays: Int { didSet { defaults.set(autoDeleteTextDays, forKey: Key.autoDeleteTextDays) } }
    @Published var autoDeleteAudioDays: Int { didSet { defaults.set(autoDeleteAudioDays, forKey: Key.autoDeleteAudioDays) } }
    /// The engine that transcribes dictation. It is always on.
    @Published var dictationEngine: SpeechEngine {
        didSet {
            defaults.set(dictationEngine.rawValue, forKey: Key.dictationEngine)
            if !dictationEngine.languages.contains(language) { language = .ar }
        }
    }
    /// Engines kept in memory for the API and comparisons. Turning one off frees its memory.
    @Published var cohereEnabled: Bool { didSet { defaults.set(cohereEnabled, forKey: Key.cohereEnabled) } }
    @Published var audarEnabled: Bool { didSet { defaults.set(audarEnabled, forKey: Key.audarEnabled) } }
    @Published var audarModel: String { didSet { defaults.set(audarModel, forKey: Key.audarModel) } }
    @Published var whisperEnabled: Bool { didSet { defaults.set(whisperEnabled, forKey: Key.whisperEnabled) } }
    @Published var whisperModel: String { didSet { defaults.set(whisperModel, forKey: Key.whisperModel) } }
    @Published var qwen3Enabled: Bool { didSet { defaults.set(qwen3Enabled, forKey: Key.qwen3Enabled) } }
    @Published var qwen3Model: String { didSet { defaults.set(qwen3Model, forKey: Key.qwen3Model) } }
    /// Free a model's memory after this many minutes without use (0 keeps models loaded).
    @Published var idleMinutes: Int { didSet { defaults.set(idleMinutes, forKey: Key.idleMinutes) } }
    /// Record tab: what a meeting recording captures, and how often a finished part is saved to disk.
    @Published var meetingSource: MeetingSource { didSet { defaults.set(meetingSource.rawValue, forKey: Key.meetingSource) } }
    @Published var meetingPartMinutes: Int { didSet { defaults.set(meetingPartMinutes, forKey: Key.meetingPartMinutes) } }
    /// Record and Files tabs: the engine and language for long transcriptions.
    @Published var jobEngine: SpeechEngine {
        didSet {
            defaults.set(jobEngine.rawValue, forKey: Key.jobEngine)
            if !jobEngine.languages.contains(jobLanguage) { jobLanguage = .ar }
        }
    }
    @Published var jobLanguage: DictationLanguage { didSet { defaults.set(jobLanguage.rawValue, forKey: Key.jobLanguage) } }
    @Published var meetingTranscription: MeetingTranscription { didSet { defaults.set(meetingTranscription.rawValue, forKey: Key.meetingTranscription) } }
    @Published var autoTranscribeImports: Bool { didSet { defaults.set(autoTranscribeImports, forKey: Key.autoTranscribeImports) } }
    /// Long audio is transcribed in pieces of about this many seconds, each cut at a pause:
    /// how often live meeting text appears, and how often a long file shows more text.
    @Published var pieceSeconds: Int { didSet { defaults.set(pieceSeconds, forKey: Key.pieceSeconds) } }
    /// Switches the dictation language from any app; nil turns it off.
    @Published var languageShortcut: KeyShortcut? {
        didSet {
            let data = languageShortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
            defaults.set(data, forKey: Key.languageKeys)
        }
    }
    /// Clipboard tab: keep the text you copy anywhere, for this many days (starred items stay).
    @Published var clipboardHistory: Bool { didSet { defaults.set(clipboardHistory, forKey: Key.clipboardHistory) } }
    @Published var clipboardDays: Int { didSet { defaults.set(clipboardDays, forKey: Key.clipboardDays) } }
    /// The language model on this Mac that writes summaries and rewrites, and each one's weights.
    @Published var writingModel: WritingModel { didSet { defaults.set(writingModel.rawValue, forKey: Key.writingModel) } }
    @Published var gemmaModel: String { didSet { defaults.set(gemmaModel, forKey: Key.gemmaModel) } }
    @Published var llamaModel: String { didSet { defaults.set(llamaModel, forKey: Key.llamaModel) } }
    /// Opens the quick list of recent copies from any app; nil turns it off.
    @Published var clipboardShortcut: KeyShortcut? {
        didSet {
            let data = clipboardShortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
            defaults.set(data, forKey: Key.clipboardKeys)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.language: DictationLanguage.ar.rawValue,
            Key.pushToTalkKey: PushToTalkKey.rightOption.rawValue,
            Key.cleanupMode: CleanupMode.local.rawValue,
            Key.asrModel: Self.defaultASRModel,
            Key.localLLMModel: Self.defaultLLMModel,
            Key.customBaseURL: "http://localhost:11434/v1",
            Key.customModel: "qwen3:8b",
            Key.enginePort: 7861,
            Key.autoPaste: true,
            Key.restoreClipboard: true,
            Key.keepAudio: true,
            Key.playSounds: true,
            Key.flowBarAlwaysVisible: true,
            Key.flowBarEdge: FlowBarEdge.bottom.rawValue,
            Key.flowBarPosition: 0.5,
            Key.hasOnboarded: false,
            Key.autoDeleteTextDays: 0,
            Key.autoDeleteAudioDays: 0,
            Key.dictationEngine: SpeechEngine.cohere.rawValue,
            Key.cohereEnabled: true,
            Key.audarEnabled: false,
            Key.audarModel: SpeechEngine.audar.defaultModel,
            Key.whisperEnabled: false,
            Key.whisperModel: SpeechEngine.whisper.defaultModel,
            Key.qwen3Enabled: false,
            Key.qwen3Model: SpeechEngine.qwen3.defaultModel,
            Key.idleMinutes: 10,
            Key.meetingSource: MeetingSource.both.rawValue,
            Key.meetingPartMinutes: 5,
            Key.autoTranscribeRecordings: true,
            Key.autoTranscribeImports: true,
            Key.pieceSeconds: 60,
            Key.clipboardHistory: true,
            Key.clipboardDays: 30,
            Key.writingModel: WritingModel.gemma.rawValue,
            Key.gemmaModel: WritingModel.gemma.defaultModel,
            Key.llamaModel: WritingModel.llama.defaultModel,
        ])
        language = DictationLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .ar
        pushToTalkKey = PushToTalkKey(rawValue: defaults.string(forKey: Key.pushToTalkKey) ?? "") ?? .rightOption
        cleanupMode = CleanupMode(rawValue: defaults.string(forKey: Key.cleanupMode) ?? "") ?? .local
        asrModel = defaults.string(forKey: Key.asrModel) ?? Self.defaultASRModel
        localLLMModel = defaults.string(forKey: Key.localLLMModel) ?? Self.defaultLLMModel
        customBaseURL = defaults.string(forKey: Key.customBaseURL) ?? "http://localhost:11434/v1"
        customModel = defaults.string(forKey: Key.customModel) ?? "qwen3:8b"
        enginePort = defaults.integer(forKey: Key.enginePort)
        autoPaste = defaults.bool(forKey: Key.autoPaste)
        restoreClipboard = defaults.bool(forKey: Key.restoreClipboard)
        keepAudio = defaults.bool(forKey: Key.keepAudio)
        playSounds = defaults.bool(forKey: Key.playSounds)
        flowBarAlwaysVisible = defaults.bool(forKey: Key.flowBarAlwaysVisible)
        flowBarEdge = FlowBarEdge(rawValue: defaults.string(forKey: Key.flowBarEdge) ?? "") ?? .bottom
        flowBarPosition = defaults.double(forKey: Key.flowBarPosition)
        hasOnboarded = defaults.bool(forKey: Key.hasOnboarded)
        autoDeleteTextDays = defaults.integer(forKey: Key.autoDeleteTextDays)
        autoDeleteAudioDays = defaults.integer(forKey: Key.autoDeleteAudioDays)
        dictationEngine = SpeechEngine(rawValue: defaults.string(forKey: Key.dictationEngine) ?? "") ?? .cohere
        cohereEnabled = defaults.bool(forKey: Key.cohereEnabled)
        audarEnabled = defaults.bool(forKey: Key.audarEnabled)
        audarModel = defaults.string(forKey: Key.audarModel) ?? SpeechEngine.audar.defaultModel
        whisperEnabled = defaults.bool(forKey: Key.whisperEnabled)
        whisperModel = defaults.string(forKey: Key.whisperModel) ?? SpeechEngine.whisper.defaultModel
        qwen3Enabled = defaults.bool(forKey: Key.qwen3Enabled)
        qwen3Model = defaults.string(forKey: Key.qwen3Model) ?? SpeechEngine.qwen3.defaultModel
        idleMinutes = max(0, defaults.integer(forKey: Key.idleMinutes))
        meetingSource = MeetingSource(rawValue: defaults.string(forKey: Key.meetingSource) ?? "") ?? .both
        meetingPartMinutes = [3, 5].contains(defaults.integer(forKey: Key.meetingPartMinutes)) ? defaults.integer(forKey: Key.meetingPartMinutes) : 5
        // Until chosen, long transcriptions use the dictation engine and language (read from defaults:
        // properties cannot be read before every one of them is set).
        jobEngine = SpeechEngine(rawValue: defaults.string(forKey: Key.jobEngine) ?? "")
            ?? SpeechEngine(rawValue: defaults.string(forKey: Key.dictationEngine) ?? "")
            ?? .cohere
        jobLanguage = DictationLanguage(rawValue: defaults.string(forKey: Key.jobLanguage) ?? "")
            ?? DictationLanguage(rawValue: defaults.string(forKey: Key.language) ?? "")
            ?? .ar
        // Before live text, recordings were transcribed when stopped or not at all.
        meetingTranscription = MeetingTranscription(rawValue: defaults.string(forKey: Key.meetingTranscription) ?? "")
            ?? (defaults.bool(forKey: Key.autoTranscribeRecordings) ? .live : .manual)
        autoTranscribeImports = defaults.bool(forKey: Key.autoTranscribeImports)
        pieceSeconds = Self.pieceChoices.contains(defaults.integer(forKey: Key.pieceSeconds)) ? defaults.integer(forKey: Key.pieceSeconds) : 60
        languageShortcut = Self.readLanguageShortcut(defaults)
        clipboardHistory = defaults.bool(forKey: Key.clipboardHistory)
        clipboardDays = Self.clipboardDayChoices.contains(defaults.integer(forKey: Key.clipboardDays)) ? defaults.integer(forKey: Key.clipboardDays) : 30
        writingModel = WritingModel(rawValue: defaults.string(forKey: Key.writingModel) ?? "") ?? .gemma
        gemmaModel = defaults.string(forKey: Key.gemmaModel) ?? WritingModel.gemma.defaultModel
        llamaModel = defaults.string(forKey: Key.llamaModel) ?? WritingModel.llama.defaultModel
        if let data = defaults.data(forKey: Key.clipboardKeys) {
            clipboardShortcut = data.isEmpty ? nil : (try? JSONDecoder().decode(KeyShortcut.self, from: data)) ?? .clipboardDefault
        } else {
            clipboardShortcut = .clipboardDefault
        }
        if !dictationEngine.languages.contains(language) { language = .ar }
        if !jobEngine.languages.contains(jobLanguage) { jobLanguage = .ar }
        keepWithinEngineLimit()
    }

    /// More engines on than allowed (saved by hand, for example): the dictation engine stays,
    /// with the first of the others.
    private func keepWithinEngineLimit() {
        var room = Self.maxEnabledEngines - 1
        for engine in SpeechEngine.allCases where engine != dictationEngine && flag(engine) {
            if room > 0 {
                room -= 1
            } else {
                setEnabled(engine, false)
            }
        }
    }

    /// The saved shortcut, the one picked from the old preset list, or Control + Option + L.
    private static func readLanguageShortcut(_ defaults: UserDefaults) -> KeyShortcut? {
        if let data = defaults.data(forKey: Key.languageKeys) {
            return data.isEmpty ? nil : (try? JSONDecoder().decode(KeyShortcut.self, from: data)) ?? .languageDefault
        }
        switch defaults.string(forKey: Key.languageShortcut) {
        case "off": return nil
        case "controlOptionCommandL": return KeyShortcut(keyCode: KeyShortcut.languageDefault.keyCode, modifiers: 4096 | 2048 | 256)
        case "optionShiftL": return KeyShortcut(keyCode: KeyShortcut.languageDefault.keyCode, modifiers: 2048 | 512)
        default: return .languageDefault
        }
    }

    /// The language for a long transcription with `engine`.
    func jobLanguage(for engine: SpeechEngine) -> DictationLanguage {
        engine.languages.contains(jobLanguage) ? jobLanguage : .ar
    }

    /// Moves dictation to the next language the dictation engine supports. Returns it.
    @discardableResult
    func cycleDictationLanguage() -> DictationLanguage {
        let choices = dictationEngine.languages
        let index = choices.firstIndex(of: language) ?? -1
        language = choices[(index + 1) % choices.count]
        return language
    }

    var engineBaseURL: URL {
        URL(string: "http://127.0.0.1:\(enginePort)")!
    }

    /// On means allowed to load (it loads when used). The dictation engine is always on.
    func isEnabled(_ engine: SpeechEngine) -> Bool {
        engine == dictationEngine || flag(engine)
    }

    /// The saved switch, without the dictation engine's exception.
    private func flag(_ engine: SpeechEngine) -> Bool {
        switch engine {
        case .cohere: return cohereEnabled
        case .audar: return audarEnabled
        case .whisper: return whisperEnabled
        case .qwen3: return qwen3Enabled
        }
    }

    func setEnabled(_ engine: SpeechEngine, _ enabled: Bool) {
        switch engine {
        case .cohere: cohereEnabled = enabled
        case .audar: audarEnabled = enabled
        case .whisper: whisperEnabled = enabled
        case .qwen3: qwen3Enabled = enabled
        }
    }

    var enabledEngines: [SpeechEngine] {
        SpeechEngine.allCases.filter { isEnabled($0) }
    }

    /// Turning `engine` on stays within the limit (an engine that is on already always does).
    func canEnable(_ engine: SpeechEngine) -> Bool {
        isEnabled(engine) || enabledEngines.count < Self.maxEnabledEngines
    }

    /// Making `engine` the dictation engine stays within the limit. The old dictation engine
    /// stays on only when its own switch is on, so this can fit where `canEnable` does not.
    func canUseForDictation(_ engine: SpeechEngine) -> Bool {
        let after = SpeechEngine.allCases.filter { $0 == engine || flag($0) }
        return after.count <= Self.maxEnabledEngines
    }

    /// The engines that are on, in words: "Cohere and Audar".
    var enabledEnginesText: String {
        enabledEngines.map(\.shortName).joined(separator: " and ")
    }

    /// The engine for long transcriptions: the one chosen (turned on when it is used, if there
    /// is room), or the dictation engine when two others are on already.
    var jobEngineInUse: SpeechEngine {
        canEnable(jobEngine) ? jobEngine : dictationEngine
    }

    func model(for model: WritingModel) -> String {
        switch model {
        case .gemma: return gemmaModel
        case .llama: return llamaModel
        }
    }

    func model(for engine: SpeechEngine) -> String {
        switch engine {
        case .cohere: return asrModel
        case .audar: return audarModel
        case .whisper: return whisperModel
        case .qwen3: return qwen3Model
        }
    }
}
