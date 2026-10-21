import AppKit
import AVFoundation
import Combine

@main
enum NavoMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var settings: AppSettings!
    private var store: HistoryStore!
    private var engine: LocalEngineManager!
    private var dictation: DictationController!
    private var flowBar: FlowBarController!
    private var hub: HubWindowController!
    private var sessions: SessionStore!
    private var clipboard: ClipboardStore!
    private var quickPaste: QuickPasteController!
    private var aiWriter: AIWriter!
    private var metrics: MetricsStore!
    private var activity: MenuBarActivity!
    private var notifier: DoneNotifier!
    private var screenPrivacy: ScreenPrivacy!
    private var statusItem: NSStatusItem!
    /// What the menu bar icon shows now, so it is only redrawn when that changes.
    private var drawnLook: MenuBarActivity.Look?
    /// The transcriptions the menu lists now, so it is only rebuilt when they change.
    private var shownActivity: [String] = []
    private var menuIsOpen = false
    private var cancellables = Set<AnyCancellable>()
    /// Files or links macOS handed over before launch finished.
    private var pendingOpen: [URL] = []
    private var trustTimer: Timer?
    private var retentionTimer: Timer?
    private var wasTrusted = false

    private var dictateItem: NSMenuItem!
    private var engineItem: NSMenuItem!
    private var recordItem: NSMenuItem!
    private var languageItem: NSMenuItem!
    private var quickPasteItem: NSMenuItem!
    private var flowBarItem: NSMenuItem!
    private var privateItem: NSMenuItem!
    private let flowBarMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings.shared
        // First, so no window is ever drawn into a screen share before it is hidden.
        screenPrivacy = ScreenPrivacy(settings: settings)
        buildMainMenu()

        var openError: String?
        let database: Database?
        if Paths.isDemo { DemoData.reset() }
        do {
            database = try Database(url: Paths.database)
            for problem in database?.problems ?? [] {
                ProblemLog.shared.report("Storage", problem)
            }
        } catch {
            database = nil
            openError = error.localizedDescription
            ProblemLog.shared.report("Storage", "Could not open the history: \(error.localizedDescription)")
        }
        if Paths.isDemo, let database { DemoData.fill(database) }

        store = HistoryStore(db: database, openError: openError)
        metrics = MetricsStore(db: database)
        engine = LocalEngineManager(settings: settings)
        dictation = DictationController(settings: settings, engine: engine, store: store, metrics: metrics)
        sessions = SessionStore(db: database, engine: engine, settings: settings, metrics: metrics)
        clipboard = ClipboardStore(db: database, settings: settings)
        quickPaste = QuickPasteController(clipboard: clipboard, settings: settings)
        aiWriter = AIWriter(settings: settings, engine: engine, metrics: metrics)
        quickPaste.onShortcut = { [weak self] in
            self?.dictation.shortcutPressed()
        }
        hub = HubWindowController(
            settings: settings,
            store: store,
            engine: engine,
            dictation: dictation,
            sessions: sessions,
            clipboard: clipboard,
            quickPaste: quickPaste,
            aiWriter: aiWriter,
            metrics: metrics
        )
        flowBar = FlowBarController(dictation: dictation, settings: settings) { [weak self] section in
            self?.showHub(section)
        }
        dictation.onNeedsSetup = { [weak self] in
            self?.hub.show(section: .settings, pane: .general)
        }

        activity = MenuBarActivity(sessions: sessions)
        activity.onChange = { [weak self] in
            self?.activityChanged()
        }
        notifier = DoneNotifier(sessions: sessions, settings: settings)
        DoneNotifier.current = notifier
        notifier.open = { [weak self] id in
            self?.open(sessionID: id)
        }
        setupStatusItem()
        // The menu bar icon's look changed in Settings: draw it again, with the new values.
        Publishers.Merge3(
            settings.$menuBarStyle.map { _ in () },
            settings.$menuBarEmoji.map { _ in () },
            settings.$menuBarShowsText.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            self?.drawnLook = nil
            self?.drawStatusItem()
        }
        .store(in: &cancellables)
        dictation.start()
        quickPaste.registerShortcut()
        engine.startIfInstalled()
        flowBar.show()
        watchAccessibility()
        registerShareExtension()
        startRetention()
        clipboard.start()
        settings.$clipboardHistory
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.clipboard.applySetting() }
            .store(in: &cancellables)
        settings.$clipboardDays
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.clipboard.prune() }
            .store(in: &cancellables)

        // Audio sent from the Share menu while Navo was not running, and anything opened with Navo.
        let opened = pendingOpen
        pendingOpen = []
        let fromInbox = sessions.importInbox()
        if !opened.isEmpty {
            handleOpen(opened)
            return
        } else if fromInbox {
            showHub(.files)
            return
        }

        let needsSetup = !engine.isInstalled
            || !TextInjector.isTrusted
            || MicrophonePermission.status != .authorized
        if !settings.hasOnboarded || needsSetup {
            settings.hasOnboarded = true
            hub.show(section: .settings, pane: .general)
        }
    }

    /// "Open With > Navo" on audio files, files dropped on Navo's icon, and navo://import from
    /// the Share extension.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard sessions != nil else {
            pendingOpen += urls
            return
        }
        handleOpen(urls)
    }

    private func handleOpen(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if urls.contains(where: { $0.scheme?.lowercased() == "navo" }) {
            sessions.importInbox()
        }
        if !files.isEmpty {
            sessions.importFiles(files)
        }
        showHub(.files)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHub(nil) // back to the tab that was open
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessions?.prepareForQuit()
        engine?.stop()
    }

    /// Opens the Hub on `section`, or on the tab it last showed.
    func showHub(_ section: HubSection?) {
        hub.show(section: section)
    }

    // MARK: Share menu

    /// Makes Share > Navo appear for people who installed Navo by dragging it to Applications
    /// (the build script registers it for a build from source). Once per version and place.
    private func registerShareExtension() {
        let bundle = Bundle.main
        guard let appex = bundle.builtInPlugInsURL?.appendingPathComponent("NavoShare.appex"),
              FileManager.default.fileExists(atPath: appex.path)
        else { return }
        // Not from the disk image, or from the temporary copy macOS runs a downloaded app from
        // before it has been moved: that place goes away.
        let path = bundle.bundlePath
        guard !path.hasPrefix("/Volumes/"), !path.contains("/AppTranslocation/") else { return }
        let version = bundle.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let marker = "\(version)|\(path)"
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "shareExtensionRegistered") != marker else { return }
        let firstTime = defaults.string(forKey: "shareExtensionRegistered") == nil
        defaults.set(marker, forKey: "shareExtensionRegistered")
        Task.detached(priority: .utility) {
            AppDelegate.runPluginKit(["-a", appex.path])
            // Turned on once; if you turn it off later in System Settings, it stays off.
            if firstTime {
                AppDelegate.runPluginKit(["-e", "use", "-i", "com.ehab-kahwati.navo.share"])
            }
        }
    }

    nonisolated private static func runPluginKit(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Share > Navo only; everything else works without it.
        }
    }

    // MARK: Automatic cleanup

    private func startRetention() {
        applyRetention()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.applyRetention()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer
    }

    func applyRetention() {
        store.applyRetention(textDays: settings.autoDeleteTextDays, audioDays: settings.autoDeleteAudioDays)
        clipboard?.prune()
        metrics?.prune()
    }

    // MARK: Accessibility

    /// Global key monitors only start receiving events once Accessibility is granted, so re-arm them then.
    private func watchAccessibility() {
        wasTrusted = TextInjector.isTrusted
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.checkAccessibility()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    private func checkAccessibility() {
        let trusted = TextInjector.isTrusted
        guard trusted != wasTrusted else { return }
        wasTrusted = trusted
        if trusted {
            dictation.restartHotkeys()
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        // Variable length: a percentage or a clock can show next to the icon.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let size = (NSFont.menuBarFont(ofSize: 0) as NSFont?)?.pointSize ?? NSFont.systemFontSize
            button.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        }
        drawStatusItem()

        let menu = NSMenu()
        menu.delegate = self
        dictateItem = item("Start Dictation", #selector(AppDelegate.toggleDictation), "")
        recordItem = item("Record a Meeting…", #selector(AppDelegate.toggleMeetingRecording), "")
        engineItem = NSMenuItem(title: "Local engine", action: nil, keyEquivalent: "")
        languageItem = NSMenuItem(title: "Dictation Language", action: nil, keyEquivalent: "")
        languageItem.submenu = NSMenu()
        menu.addItem(dictateItem)
        menu.addItem(languageItem)
        menu.addItem(recordItem)
        menu.addItem(.separator())
        quickPasteItem = item("Paste from Clipboard History…", #selector(openQuickPaste), "")
        menu.addItem(item("Open Navo", #selector(openHome), "o"))
        menu.addItem(quickPasteItem)
        menu.addItem(item("Clipboard", #selector(openClipboard), ""))
        menu.addItem(item("Dictionary", #selector(openDictionary), ""))
        menu.addItem(item("Settings…", #selector(openSettings), ","))
        flowBarItem = NSMenuItem(title: "Hide Flow Bar", action: nil, keyEquivalent: "")
        flowBarItem.submenu = flowBarMenu
        menu.addItem(flowBarItem)
        privateItem = item("Hide Navo from Screen Sharing", #selector(togglePrivateMode), "")
        privateItem.toolTip = "Private mode: Navo's windows stay out of screen sharing, screenshots and recordings. You still see them."
        menu.addItem(privateItem)
        menu.addItem(.separator())
        engineItem.isEnabled = false
        menu.addItem(engineItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit Navo", #selector(quit), "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildActivityItems()
        dictateItem.title = dictation.phase.isRecording ? "Stop Dictation" : "Start Dictation"
        let key = settings.pushToTalkKey
        if key != .off {
            dictateItem.title += "   (hold \(key.shortName))"
        }
        engineItem.title = "Local engine (\(settings.dictationEngine.shortName)): \(engine.state.label)"
        privateItem.state = settings.privateMode ? .on : .off
        languageItem.title = "Dictation Language: \(settings.language.name)"
        // Shows the shortcut on the right, as menus do.
        if quickPaste.shortcutProblem == nil, let keys = settings.clipboardShortcut?.menuKey {
            quickPasteItem.keyEquivalent = keys.key
            quickPasteItem.keyEquivalentModifierMask = keys.modifiers
        } else {
            quickPasteItem.keyEquivalent = ""
        }
        if let submenu = languageItem.submenu {
            submenu.removeAllItems()
            for language in settings.dictationEngine.languages {
                let entry = item(language.title, #selector(chooseLanguage(_:)), "")
                entry.representedObject = language.rawValue
                entry.state = language == settings.language ? .on : .off
                submenu.addItem(entry)
            }
            if let shortcut = settings.languageShortcut {
                submenu.addItem(.separator())
                let hint = NSMenuItem(title: "Switch anywhere with \(shortcut.spelled)", action: nil, keyEquivalent: "")
                hint.isEnabled = false
                submenu.addItem(hint)
            }
        }
        updateFlowBarItem()
        switch sessions.recorder.phase {
        case .recording, .paused:
            recordItem.title = "Stop Meeting Recording (\(SessionStore.clock(sessions.recorder.elapsed)))"
        case .finishing:
            recordItem.title = "Saving the Meeting Recording…"
        case .idle:
            recordItem.title = "Record a Meeting…"
        }
        recordItem.isEnabled = sessions.recorder.phase != .finishing
    }

    /// "Hide Flow Bar" with its lengths, or "Show Flow Bar" while it is hidden.
    private func updateFlowBarItem() {
        let submenu = flowBarMenu
        submenu.removeAllItems()
        if settings.flowBarShowsWhenIdle {
            flowBarItem.title = "Hide Flow Bar"
            flowBarItem.action = nil
            flowBarItem.submenu = submenu
            for pause in FlowBarPause.allCases {
                let entry = item("For \(pause.title)", #selector(hideFlowBar(_:)), "")
                entry.representedObject = pause.rawValue
                submenu.addItem(entry)
            }
            submenu.addItem(.separator())
            submenu.addItem(item("Until I Show It Again (shows while dictating)", #selector(hideFlowBarForGood), ""))
        } else {
            let until = settings.flowBarAlwaysVisible ? settings.flowBarHiddenUntil : nil
            flowBarItem.title = until.map { "Show Flow Bar (hidden until \($0.formatted(date: .omitted, time: .shortened)))" } ?? "Show Flow Bar"
            flowBarItem.submenu = nil
            flowBarItem.target = self
            flowBarItem.action = #selector(showFlowBar)
        }
    }

    @objc private func hideFlowBar(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int, let pause = FlowBarPause(rawValue: minutes) else { return }
        settings.flowBarHiddenUntil = pause.until()
    }

    @objc private func hideFlowBarForGood() {
        settings.flowBarHiddenUntil = nil
        settings.flowBarAlwaysVisible = false
    }

    @objc private func showFlowBar() {
        settings.flowBarHiddenUntil = nil
        settings.flowBarAlwaysVisible = true
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // What finished has been seen now.
        activity.acknowledge()
    }

    // MARK: Transcription progress in the menu bar

    private static let activityTag = 4_242

    private func activityChanged() {
        drawStatusItem()
        if menuIsOpen {
            rebuildActivityItems()
        }
    }

    /// The icon, and a percentage or clock beside it while something long is going on.
    private func drawStatusItem() {
        guard let button = statusItem?.button, let activity else { return }
        let look = activity.look
        guard look != drawnLook else { return }
        drawnLook = look
        // Emoji you picked instead of Navo's icons: nothing on it says recording to anyone who
        // sees your screen. Settings > Privacy > Menu bar icon.
        let emoji: MenuBarEmoji? = settings.menuBarStyle == .emoji ? settings.menuBarEmoji : nil
        let text = settings.menuBarShowsText
        switch look {
        case .idle:
            show(MenuBarImages.idle(), emoji: emoji?.idle, title: "", on: button)
            button.toolTip = "Navo"
        case .recording(let paused, let clock):
            show(MenuBarImages.recording(paused: paused), emoji: paused ? emoji?.paused : emoji?.recording, title: text ? clock : "", on: button)
            button.toolTip = emoji != nil ? "Navo" : paused ? "Meeting recording paused at \(clock)" : "Recording a meeting: \(clock)"
        case .working(let percent):
            show(MenuBarImages.progress(percent.map { Double($0) / 100 }), emoji: emoji?.working, title: text ? percent.map { "\($0)%" } ?? "…" : "", on: button)
            button.toolTip = emoji != nil ? "Navo" : percent.map { "Transcribing: \($0)% done. Click for details." } ?? "Transcribing. Click for details."
        case .finished(let ok):
            show(ok ? MenuBarImages.done() : MenuBarImages.problem(), emoji: emoji?.done, title: text && emoji == nil ? "Done" : "", on: button)
            button.toolTip = emoji != nil ? "Navo" : ok
                ? "Transcription done. Click to see it."
                : "Transcription done, but some of it could not be transcribed. Click to see it."
        }
    }

    /// The icon (or the emoji picked for this state, when there is one) and the text beside it.
    private func show(_ image: NSImage?, emoji: String?, title: String, on button: NSStatusBarButton) {
        if let emoji, !emoji.isEmpty {
            button.image = nil
            button.title = title.isEmpty ? emoji : "\(emoji) \(title)"
            button.imagePosition = .noImage
        } else {
            button.image = image
            button.title = title
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
    }

    /// The transcriptions at the top of the menu: running, in line, and just finished.
    private func rebuildActivityItems() {
        guard let menu = statusItem?.menu, let activity else { return }
        let entries = activity.entries
        // The clock of a recording ticks twice a second; the list only changes piece by piece.
        let signature = entries.map { "\($0.sessionID)|\($0.title)|\($0.detail)" }
        guard signature != shownActivity else { return }
        shownActivity = signature
        for item in menu.items where item.tag == Self.activityTag {
            menu.removeItem(item)
        }
        guard !entries.isEmpty else { return }
        let header = NSMenuItem(title: "Transcriptions", action: nil, keyEquivalent: "")
        header.isEnabled = false
        var items = [header]
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: #selector(openSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.sessionID
            item.image = entry.image
            item.toolTip = entry.detail
            if #available(macOS 14.4, *) {
                item.subtitle = entry.detail
            } else {
                item.title = "\(entry.title): \(entry.detail)"
            }
            items.append(item)
        }
        items.append(.separator())
        for (index, item) in items.enumerated() {
            item.tag = Self.activityTag
            menu.insertItem(item, at: index)
        }
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        open(sessionID: sender.representedObject as? String)
    }

    /// Shows a recording or file in its tab (from the menu bar or a notification).
    private func open(sessionID id: String?) {
        guard let id, let session = sessions.session(id) else {
            showHub(nil)
            return
        }
        if session.kind == .file {
            hub.show(section: .files, session: id)
        } else if sessions.recorder.sessionID == id {
            // The one being recorded: its panel.
            hub.show(section: .record)
        } else {
            // Another recording, even while one is being recorded: Notetaker opens the list for it.
            hub.show(section: .record, session: id)
        }
    }

    @objc private func toggleMeetingRecording() {
        if sessions.recorder.phase == .recording || sessions.recorder.phase == .paused {
            sessions.recorder.stop()
        } else {
            showHub(.record)
        }
    }

    @objc private func toggleDictation() {
        dictation.toggleHandsFree()
    }

    @objc private func openHome() {
        showHub(nil)
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = DictationLanguage(rawValue: raw) else { return }
        dictation.setLanguage(language)
    }

    @objc private func openQuickPaste() {
        // Once the menu has fully closed.
        Task { @MainActor [weak self] in
            self?.quickPaste.show()
        }
    }

    @objc private func openClipboard() {
        showHub(.clipboard)
    }

    @objc private func openDictionary() {
        showHub(.dictionary)
    }

    @objc private func togglePrivateMode() {
        settings.privateMode.toggle()
    }

    @objc private func openSettings() {
        showHub(.settings)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Main menu (needed for ⌘C / ⌘V / ⌘A in text fields of an accessory app)

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Navo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(openSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Navo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Navo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
