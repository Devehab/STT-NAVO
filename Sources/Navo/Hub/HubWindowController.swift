import AppKit
import AVFoundation
import SwiftUI

enum HubSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case record
    case files
    case clipboard
    case dictionary
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .record: return "Record"
        case .files: return "Files"
        case .clipboard: return "Clipboard"
        case .dictionary: return "Dictionary"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "waveform"
        case .record: return "record.circle"
        case .files: return "tray.and.arrow.down"
        case .clipboard: return "doc.on.clipboard"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
}

/// The Hub's current tab, kept across closing the window and relaunching Navo.
@MainActor
final class HubRouter: ObservableObject {
    private static let key = "hubSection"

    @Published var section: HubSection? {
        didSet {
            if let section { UserDefaults.standard.set(section.rawValue, forKey: Self.key) }
        }
    }
    /// A recording or file to select once its tab shows (asked for from the menu bar).
    @Published var focusedSession: String?

    init() {
        section = HubSection(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .home
    }
}

/// Plays saved recordings from the history.
@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: String?
    private var player: AVAudioPlayer?

    func toggle(_ item: Dictation) {
        if playingID == item.id {
            stop()
            return
        }
        stop()
        guard let path = item.audioPath, FileManager.default.fileExists(atPath: path) else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player.delegate = self
            player.play()
            self.player = player
            playingID = item.id
        } catch {
            playingID = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }
}

/// The main window: history, stats, dictionary and settings.
@MainActor
final class HubWindowController: NSObject, NSWindowDelegate {
    let router = HubRouter()
    let playback = AudioPlayback()

    private var window: NSWindow?
    private let settings: AppSettings
    private let store: HistoryStore
    private let engine: LocalEngineManager
    private let dictation: DictationController
    private let sessions: SessionStore
    private let clipboard: ClipboardStore
    private let quickPaste: QuickPasteController
    private let aiWriter: AIWriter

    init(
        settings: AppSettings,
        store: HistoryStore,
        engine: LocalEngineManager,
        dictation: DictationController,
        sessions: SessionStore,
        clipboard: ClipboardStore,
        quickPaste: QuickPasteController,
        aiWriter: AIWriter
    ) {
        self.settings = settings
        self.store = store
        self.engine = engine
        self.dictation = dictation
        self.sessions = sessions
        self.clipboard = clipboard
        self.quickPaste = quickPaste
        self.aiWriter = aiWriter
        super.init()
    }

    func show(section: HubSection? = nil, session: String? = nil) {
        if let section { router.section = section }
        if let session { router.focusedSession = session }
        if window == nil { window = makeWindow() }
        store.reload()
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Navo"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = HubView.minimumSize
        window.delegate = self

        let root = HubView()
            .environmentObject(router)
            .environmentObject(settings)
            .environmentObject(store)
            .environmentObject(engine)
            .environmentObject(dictation)
            .environmentObject(playback)
            .environmentObject(sessions)
            .environmentObject(sessions.recorder)
            .environmentObject(clipboard)
            .environmentObject(quickPaste)
            .environmentObject(aiWriter)
            .environment(\.hubControllers, HubControllers(dictation: dictation, engine: engine))
        // HubView fixes its own minimum and ideal size, so no page can make the window grow or
        // stop it from shrinking. The standard sizing stays on: the sidebar and lists need it.
        window.contentView = NSHostingView(rootView: root)
        window.setFrameAutosaveName("NavoHub2")
        if !window.setFrameUsingName("NavoHub2") {
            window.center()
        }
        // A frame saved on a bigger display, or while the old sizing forced it tall, still fits.
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            window.setFrame(frame, display: false)
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        playback.stop()
        // Back to a menu bar app: no Dock icon while the Hub is closed.
        NSApp.setActivationPolicy(.accessory)
    }
}
