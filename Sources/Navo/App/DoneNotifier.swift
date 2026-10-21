import AppKit
import Combine
import UserNotifications

/// A notification when transcriptions are done: one for each recording or file, or one when
/// everything in line is done (Settings > Notetaker and Transcribe). Clicking it opens the
/// recording or file. macOS keeps notifications off the screen while you share it.
@MainActor
final class DoneNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Opens a recording or file by its id, when its notification is clicked.
    var open: ((String) -> Void)?
    /// The one Navo uses, for Settings (permission and a test notification).
    static weak var current: DoneNotifier?

    private let sessions: SessionStore
    private let settings: AppSettings
    /// Done since the line was last empty: what the notification for a batch sums up.
    private var run: [Session] = []
    private var asked = false
    private var cancellables = Set<AnyCancellable>()

    /// Notifications need Navo to run as an app (not in a test or from a script).
    static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    private var center: UNUserNotificationCenter? {
        Self.available ? UNUserNotificationCenter.current() : nil
    }

    init(sessions: SessionStore, settings: AppSettings) {
        self.sessions = sessions
        self.settings = settings
        super.init()
        center?.delegate = self
        sessions.whenTranscriptionEnds { [weak self] session in
            self?.ended(session)
        }
        sessions.$jobs
            .sink { [weak self] _ in
                // After the store is done changing: a batch that was stopped by hand starts afresh.
                Task { @MainActor [weak self] in self?.lineChanged() }
            }
            .store(in: &cancellables)
    }

    // MARK: Following the transcriptions

    private func lineChanged() {
        if sessions.hasQueuedWork {
            askOnce()
        } else {
            run = []
        }
    }

    private func ended(_ session: Session) {
        run.removeAll { $0.id == session.id }
        run.append(session)
        // The ones still in line have not started yet: none left means this was the last.
        let last = !sessions.hasQueuedWork
        defer { if last { run = [] } }
        switch settings.doneNotifications {
        case .off:
            return
        case .each:
            if last && run.count > 1 { send(summary: run) } else { send(one: session) }
        case .allDone:
            guard last else { return }
            if run.count > 1 { send(summary: run) } else { send(one: session) }
        }
    }

    // MARK: Wording

    private func send(one session: Session) {
        let content = UNMutableNotificationContent()
        let noun = session.kind == .meeting ? "Recording" : "File"
        switch session.status {
        case .done:
            content.title = "Transcribed: \(session.title)"
            content.body = "\(noun), \(Self.facts(session)). Click to read it."
        case .partial:
            content.title = "Partly transcribed: \(session.title)"
            content.body = (session.error ?? "Some parts could not be transcribed.") + " Continue tries them again."
        default:
            content.title = "Could not transcribe: \(session.title)"
            content.body = session.error ?? "Open it to see why, and try again."
        }
        content.userInfo = ["session": session.id]
        deliver(content)
    }

    private func send(summary done: [Session]) {
        let content = UNMutableNotificationContent()
        let good = done.filter { $0.status == .done }
        let problems = done.filter { $0.status != .done }
        let noun: String
        if done.allSatisfy({ $0.kind == .meeting }) {
            noun = "recordings"
        } else if done.allSatisfy({ $0.kind == .file }) {
            noun = "files"
        } else {
            noun = "transcriptions"
        }
        content.title = problems.isEmpty
            ? "All \(done.count) \(noun) are transcribed"
            : "\(good.count) of \(done.count) \(noun) transcribed"
        let audio = done.reduce(0) { $0 + $1.duration }
        var body = "\(SessionStore.clock(audio)) of audio in all."
        if problems.isEmpty {
            body += " The last: \(done.last?.title ?? "")."
        } else {
            body += " Not all done: " + problems.prefix(3).map(\.title).joined(separator: ", ")
                + (problems.count > 3 ? " and \(problems.count - 3) more." : ".")
        }
        content.body = body + " Click to see."
        // Opens the first one with a problem, or the last one done.
        if let id = (problems.first ?? done.last)?.id {
            content.userInfo = ["session": id]
        }
        deliver(content)
    }

    /// "18:48 of audio, Whisper, English"
    private static func facts(_ session: Session) -> String {
        var parts = ["\(SessionStore.clock(session.duration)) of audio"]
        if let engine = session.engine {
            parts.append(SpeechEngine.from(historyName: engine).shortName)
        }
        parts.append((DictationLanguage(rawValue: session.language) ?? .ar).name)
        return parts.joined(separator: ", ")
    }

    private func deliver(_ content: UNMutableNotificationContent) {
        guard let center else { return }
        content.sound = .default
        content.threadIdentifier = "navo-transcriptions"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                ProblemLog.note("Notifications", "Could not show a notification: \(error.localizedDescription)", once: true)
            }
        }
    }

    // MARK: Permission

    /// macOS asks once whether Navo may show notifications: when the first transcription starts,
    /// while you are there to answer.
    private func askOnce() {
        guard settings.doneNotifications != .off, !asked, let center else { return }
        asked = true
        center.getNotificationSettings { current in
            guard current.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Whether Navo may show notifications, asking first if macOS never asked. Nil: not available.
    func permission() async -> Bool? {
        guard let center else { return nil }
        let current = await center.notificationSettings()
        if current.authorizationStatus == .notDetermined {
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        return current.authorizationStatus == .authorized || current.authorizationStatus == .provisional
    }

    /// Whether Navo may show notifications, without asking. Nil: macOS has not asked yet, or not available.
    func isAllowed() async -> Bool? {
        guard let center else { return nil }
        let current = await center.notificationSettings()
        switch current.authorizationStatus {
        case .notDetermined: return nil
        case .authorized, .provisional: return true
        default: return false
        }
    }

    /// A notification now, to see how they look and that they arrive.
    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "Transcribed: Weekly planning"
        content.body = "Recording, 18:48 of audio, Whisper, English. Click to read it. (A test: this one opens nothing.)"
        deliver(content)
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Shown even while Navo is in front: the transcription may be in another tab.
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["session"] as? String
        Task { @MainActor [weak self] in
            if let id { self?.open?(id) }
            completionHandler()
        }
    }
}
