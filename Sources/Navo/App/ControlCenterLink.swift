import AppKit
import Combine
import WidgetKit

/// Navo's side of its Control Center controls (Extensions/NavoControls, macOS 26). A control
/// posts "com.ehab-kahwati.navo.control.<command>", or opens navo://control/<command> when Navo
/// is not running; Navo acts on it in the background, so nothing comes to the front. What the
/// toggles show (recording, language, private mode, Flow Bar) Navo writes to
/// Navo/Controls/state.json, and asks Control Center to draw the controls again.
@MainActor
final class ControlCenterLink {
    enum Command: String, CaseIterable {
        case dictate
        case recordStart = "record.start"
        case recordStop = "record.stop"
        case languageNext = "language.next"
        case privateOn = "private.on"
        case privateOff = "private.off"
        case clipboard
        case flowBarShow = "flowbar.show"
        case flowBarHide = "flowbar.hide"
    }

    /// What the controls show. The extension reads the same fields.
    struct State: Codable, Equatable {
        var recording: Bool
        var language: String
        var languageName: String
        var privateMode: Bool
        var flowBarShown: Bool
    }

    private static let notificationPrefix = "com.ehab-kahwati.navo.control."
    /// The controls that show something from Navo, drawn again when it changes.
    private static let kindsWithState = ["record", "language", "private", "flowbar"].map { notificationPrefix + $0 }

    private let settings: AppSettings
    private let sessions: SessionStore
    private let dictation: DictationController
    private let quickPaste: QuickPasteController
    private var written: State?
    private var cancellables = Set<AnyCancellable>()

    static var stateFile: URL {
        Paths.supportDir.appendingPathComponent("Controls/state.json")
    }

    init(settings: AppSettings, sessions: SessionStore, dictation: DictationController, quickPaste: QuickPasteController) {
        self.settings = settings
        self.sessions = sessions
        self.dictation = dictation
        self.quickPaste = quickPaste
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        for command in Command.allCases {
            center.addObserver(forName: Notification.Name(Self.notificationPrefix + command.rawValue), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.perform(command) }
            }
        }
        // Whatever changes what a control shows, wherever it changed (menu, Settings, shortcut).
        Publishers.MergeMany(
            sessions.recorder.$phase.map { _ in () }.eraseToAnyPublisher(),
            settings.$language.map { _ in () }.eraseToAnyPublisher(),
            settings.$privateMode.map { _ in () }.eraseToAnyPublisher(),
            settings.$flowBarAlwaysVisible.map { _ in () }.eraseToAnyPublisher(),
            settings.$flowBarHiddenUntil.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main) // after the change, with the new values
        .sink { [weak self] in self?.writeState() }
        .store(in: &cancellables)
        writeState()
    }

    /// navo://dictate (the first Dictate control) or navo://control/<command>, from a control
    /// pressed while Navo was not running. True when it was one.
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "navo" else { return false }
        let host = url.host?.lowercased()
        if host == "dictate" {
            perform(.dictate)
            return true
        }
        guard host == "control", let command = Command(rawValue: url.lastPathComponent.lowercased()) else { return false }
        perform(command)
        return true
    }

    func perform(_ command: Command) {
        switch command {
        case .dictate:
            dictation.toggleHandsFree()
        case .recordStart:
            if sessions.recorder.phase == .idle {
                sessions.startRecording(source: settings.meetingSource)
            }
        case .recordStop:
            if sessions.recorder.phase == .recording || sessions.recorder.phase == .paused {
                sessions.recorder.stop()
            }
        case .languageNext:
            dictation.setLanguage(settings.language == .ar ? .en : .ar)
        case .privateOn:
            settings.privateMode = true
        case .privateOff:
            settings.privateMode = false
        case .clipboard:
            quickPaste.show()
        case .flowBarShow:
            settings.flowBarHiddenUntil = nil
            settings.flowBarAlwaysVisible = true
        case .flowBarHide:
            settings.flowBarHiddenUntil = nil
            settings.flowBarAlwaysVisible = false
        }
        // A toggle shows what was asked at once; this makes it show what really happened.
        writeState(force: true)
    }

    private var current: State {
        let phase = sessions.recorder.phase
        let hiddenUntil = settings.flowBarHiddenUntil.map { $0 > Date() } ?? false
        return State(
            recording: phase == .recording || phase == .paused,
            language: settings.language.rawValue,
            languageName: settings.language.name,
            privateMode: settings.privateMode,
            flowBarShown: settings.flowBarAlwaysVisible && !hiddenUntil
        )
    }

    private func writeState(force: Bool = false) {
        let state = current
        guard force || state != written else { return }
        written = state
        let url = Self.stateFile
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            ProblemLog.shared.report("Control Center", "Could not save what the controls show: \(error.localizedDescription)", once: true)
        }
        if #available(macOS 26.0, *) {
            for kind in Self.kindsWithState {
                ControlCenter.shared.reloadControls(ofKind: kind)
            }
        }
    }
}
