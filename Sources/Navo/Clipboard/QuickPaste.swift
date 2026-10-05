import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// The quick clipboard list. A shortcut in any app (Control + Option + V unless you pick
/// another) opens a small floating panel in the middle of the screen, like Spotlight, with the
/// last ten things you copied. Type to search everything Navo kept. Return, a click or ⌘1 to ⌘0
/// pastes the item into the app you were in, and it stays on the clipboard. The panel never
/// takes the app you work in out of focus.
@MainActor
final class QuickPasteController: NSObject, ObservableObject, NSWindowDelegate {
    static let recentCount = 10
    static let searchLimit = 40

    /// Set when the shortcut could not be registered.
    @Published private(set) var shortcutProblem: String?
    /// Called when the shortcut is pressed (dictation drops a push-to-talk recording its keys started).
    var onShortcut: (() -> Void)?

    private let clipboard: ClipboardStore
    private let settings: AppSettings
    private let model: QuickPasteModel
    private var panel: QuickPastePanel?
    private var shortcut: GlobalShortcut?
    private var monitor: Any?
    /// The app you were in: the item is pasted there.
    private var previousApp: NSRunningApplication?
    private var closing = false
    private var cancellables = Set<AnyCancellable>()

    init(clipboard: ClipboardStore, settings: AppSettings) {
        self.clipboard = clipboard
        self.settings = settings
        self.model = QuickPasteModel(clipboard: clipboard)
        super.init()
        model.onChoose = { [weak self] item, paste in
            self?.choose(item, paste: paste)
        }
        // The language shortcut matters too: the two may not be the same keys.
        Publishers.CombineLatest(settings.$clipboardShortcut, settings.$languageShortcut)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.registerShortcut() }
            .store(in: &cancellables)
    }

    // MARK: Shortcut

    func registerShortcut() {
        shortcut?.unregister()
        shortcut = nil
        shortcutProblem = nil
        guard let keys = settings.clipboardShortcut else { return }
        if keys == settings.languageShortcut {
            shortcutProblem = "\(keys.spelled) also switches the dictation language. Pick another one."
            return
        }
        shortcut = GlobalShortcut(keyCode: keys.keyCode, modifiers: keys.modifiers) { [weak self] in
            self?.onShortcut?()
            self?.toggle()
        }
        let taken = "\(keys.spelled) is already used by another app. Pick another one."
        if shortcut == nil {
            shortcutProblem = taken
        }
        shortcut?.onLost = { [weak self] in
            self?.shortcutProblem = taken
        }
    }

    // MARK: Panel

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() {
        isOpen ? close() : show()
    }

    func show() {
        guard !isOpen else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        let panel = self.panel ?? QuickPastePanel()
        panel.delegate = self
        self.panel = panel
        model.open()
        // A new view each time: the search field takes the keyboard right away.
        panel.setContent(QuickPasteView(
            model: model,
            canPaste: TextInjector.isTrusted,
            keepingCopies: settings.clipboardHistory
        ))
        place(panel)
        panel.alphaValue = 0
        // Above other apps' windows, and taking the keyboard without making Navo the active app.
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        startKeys()
    }

    func close() {
        stopKeys()
        guard !closing, let panel, panel.isVisible else { return }
        closing = true
        panel.orderOut(nil)
        closing = false
    }

    /// Clicking anywhere else closes it.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// Centered on the screen with the pointer, in its upper part, where Spotlight opens.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = max(visible.minY + 20, visible.maxY - visible.height * 0.16 - size.height)
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    // MARK: Keys

    /// ⌘1 to ⌘9, then ⌘0 for the tenth. Key positions, so they work with an Arabic layout too.
    private static let numberKeys = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0,
    ]

    private func startKeys() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.handle(event) ?? false
            }
            return handled ? nil : event
        }
    }

    private func stopKeys() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// The list's keys; everything else goes to the search field.
    private func handle(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel else { return false }
        // An input method still composing a word gets its keys.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() {
            return false
        }
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
            return true
        case kVK_DownArrow:
            model.move(by: 1)
            return true
        case kVK_UpArrow:
            model.move(by: -1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.chooseSelected(paste: !command)
            return true
        default:
            break
        }
        if command, let index = Self.numberKeys.firstIndex(of: Int(event.keyCode)) {
            model.choose(at: index, paste: true)
            return true
        }
        return false
    }

    // MARK: Pasting

    private func choose(_ item: ClipItem, paste: Bool) {
        let target = previousApp
        close()
        guard clipboard.use(item.id), paste else { return }
        Task { @MainActor in
            // The app below takes the keyboard back once the panel is gone.
            try? await Task.sleep(nanoseconds: 90_000_000)
            if let target, !target.isTerminated, !target.isActive {
                _ = target.activate(options: [])
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            // Without Accessibility it stays copied, ready for ⌘V.
            TextInjector.pasteNow()
        }
    }
}

// MARK: Model

@MainActor
final class QuickPasteModel: ObservableObject {
    /// The selected item's text shown in the preview, at most this much: enough to recognize it,
    /// and quick to draw while the pointer runs over the list.
    static let previewLimit = 6_000

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var selection = 0 {
        didSet {
            if selection != oldValue { loadPreview() }
        }
    }
    @Published private(set) var preview = ""
    @Published private(set) var previewRightToLeft = false
    @Published private(set) var previewCut = false
    /// The row the keyboard moved to, to scroll into view. Hovering never scrolls the list.
    @Published private(set) var scrollTarget: String?

    var onChoose: ((ClipItem, Bool) -> Void)?

    private let clipboard: ClipboardStore
    private var searchTask: Task<Void, Never>?
    /// Where the pointer was when the keyboard last moved the selection: rows passing under a
    /// pointer that did not move, while the list scrolls, do not take the selection.
    private var keyboardPointer: NSPoint?

    init(clipboard: ClipboardStore) {
        self.clipboard = clipboard
    }

    var selectedItem: ClipItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    func open() {
        query = ""
        searchTask?.cancel()
        // The row under a pointer that has not moved does not take the first selection.
        keyboardPointer = NSEvent.mouseLocation
        scrollTarget = nil
        refresh()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        let limit = query.isEmpty ? QuickPasteController.recentCount : QuickPasteController.searchLimit
        items = clipboard.recent(matching: query, limit: limit)
        scrollTarget = items.first?.id
        if selection != 0 {
            selection = 0
        } else {
            loadPreview()
        }
    }

    func move(by step: Int) {
        guard !items.isEmpty else { return }
        keyboardPointer = NSEvent.mouseLocation
        selection = min(max(0, selection + step), items.count - 1)
        scrollTarget = items[selection].id
    }

    func hover(_ index: Int) {
        if let keyboardPointer, keyboardPointer == NSEvent.mouseLocation { return }
        keyboardPointer = nil
        if selection != index, items.indices.contains(index) {
            selection = index
        }
    }

    func chooseSelected(paste: Bool) {
        guard let item = selectedItem else { return }
        onChoose?(item, paste)
    }

    func choose(at index: Int, paste: Bool) {
        guard items.indices.contains(index) else { return }
        onChoose?(items[index], paste)
    }

    private func loadPreview() {
        guard let item = selectedItem else {
            preview = ""
            previewCut = false
            return
        }
        let full = clipboard.fullText(item.id) ?? item.preview
        previewCut = full.count > Self.previewLimit
        preview = previewCut ? String(full.prefix(Self.previewLimit)) : full
        previewRightToLeft = TextTools.isRightToLeft(String(preview.prefix(2_000)))
    }
}

// MARK: Panel window

/// A floating panel that takes the keyboard without making Navo the active app, so the app you
/// work in stays in front and gets the paste.
final class QuickPastePanel: NSPanel {
    static let size = NSSize(width: 760, height: 540)
    static let cornerRadius: CGFloat = 16

    private let effect = NSVisualEffectView()
    private var host: NSView?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        contentView = effect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setContent<Content: View>(_ view: Content) {
        host?.removeFromSuperview()
        let host = FirstMouseHostingView(rootView: view)
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        self.host = host
        invalidateShadow()
    }

    /// Rounded corners for the blurred background (and so for the window's shadow).
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: View

struct QuickPasteView: View {
    @ObservedObject var model: QuickPasteModel
    /// Accessibility allowed: Navo can press ⌘V for you.
    let canPaste: Bool
    let keepingCopies: Bool

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.items.isEmpty {
                empty
            } else {
                HStack(spacing: 0) {
                    list
                        .frame(width: 340)
                    Divider()
                    previewPane
                }
            }
            Divider()
            footer
        }
        .frame(width: QuickPastePanel.size.width, height: QuickPastePanel.size.height)
        .overlay(
            // Circular corners, the same as the window's mask.
            RoundedRectangle(cornerRadius: QuickPastePanel.cornerRadius, style: .circular)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .onAppear {
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(navoBrandGradient)
            TextField("Search what you copied", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 21))
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        QuickPasteRow(
                            item: item,
                            number: index < QuickPasteController.recentCount ? index : nil,
                            selected: index == model.selection
                        )
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { model.hover(index) }
                        }
                        .onTapGesture {
                            model.choose(at: index, paste: true)
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target)
            }
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Text(model.preview)
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, model.previewRightToLeft ? .rightToLeft : .leftToRight)
                    .padding(16)
            }
            if let item = model.selectedItem {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.appName.map { "Copied in \($0)" } ?? "Copied")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(item.copiedAt.formatted(date: .abbreviated, time: .shortened)), \(item.characters.formatted()) characters")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if model.previewCut {
                        Text("Showing the start. Pasting takes all of it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(model.query.isEmpty ? "Nothing copied yet" : "Nothing matches \"\(model.query)\"")
                .font(.headline)
            Text(emptyHint)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyHint: String {
        if !model.query.isEmpty { return "Search looks through everything Navo kept." }
        if !keepingCopies { return "Keeping copies is off. Turn it on in Navo's Clipboard tab." }
        return "Text you copy in any app appears here."
    }

    private var footer: some View {
        HStack(spacing: 16) {
            KeyHint(keys: "↩", label: canPaste ? "Paste" : "Copy")
            if canPaste {
                KeyHint(keys: "⌘↩", label: "Copy only")
            }
            KeyHint(keys: "⌘1 to ⌘0", label: canPaste ? "Paste by number" : "Copy by number")
            KeyHint(keys: "esc", label: "Close")
            Spacer(minLength: 8)
            if !canPaste {
                Text("Allow Accessibility in Navo Settings and it pastes for you")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .frame(height: 34)
    }
}

private struct QuickPasteRow: View {
    let item: ClipItem
    /// 0 to 9, shown as ⌘1 to ⌘0; nil past the tenth.
    let number: Int?
    let selected: Bool

    /// The start of the text on one line.
    private var line: String {
        String(item.preview.prefix(300)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var details: String {
        var parts: [String] = []
        if let app = item.appName { parts.append(app) }
        parts.append(item.copiedAt.formatted(.relative(presentation: .named)))
        if item.characters > 200 { parts.append("\(item.characters.formatted()) characters") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let rightToLeft = TextTools.isRightToLeft(line)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(line)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: rightToLeft ? .trailing : .leading)
                HStack(spacing: 5) {
                    if item.starred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(selected ? Color.white : Color.yellow)
                    }
                    Text(details)
                }
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                .lineLimit(1)
            }
            if let number {
                Text("⌘\((number + 1) % 10)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected ? Color.white.opacity(0.2) : Color.primary.opacity(0.07))
                    )
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}
