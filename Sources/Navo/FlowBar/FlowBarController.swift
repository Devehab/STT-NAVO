import AppKit
import Combine
import SwiftUI

@MainActor
final class FlowBarState: ObservableObject {
    @Published var visual: FlowBarVisual = .orb
    @Published var edge: FlowBarEdge = .bottom
    @Published var isDragging = false
}

struct FlowBarActions {
    let speak: () -> Void
    let stop: () -> Void
    let cancel: () -> Void
    let openHistory: () -> Void
    let openSettings: () -> Void
    let cycleLanguage: () -> Void
    let messageTapped: () -> Void
    let dragChanged: () -> Void
    let dragEnded: () -> Void
}

/// Owns the floating edge bubble: placement, proximity expansion, click-through and drag-to-snap.
@MainActor
final class FlowBarController {
    let state = FlowBarState()

    private let dictation: DictationController
    private let settings: AppSettings
    private let openHub: (HubSection) -> Void
    private let panel: FlowBarPanel
    private var timer: Timer?
    private var isHovering = false
    private var dragOffset = CGPoint.zero
    private var screenNumber: NSNumber?
    private var cancellables = Set<AnyCancellable>()

    init(dictation: DictationController, settings: AppSettings, openHub: @escaping (HubSection) -> Void) {
        self.dictation = dictation
        self.settings = settings
        self.openHub = openHub
        self.panel = FlowBarPanel(size: FlowBarLayout.canvas(settings.flowBarEdge))
        state.edge = settings.flowBarEdge

        let actions = FlowBarActions(
            speak: { [weak self] in self?.dictation.toggleHandsFree() },
            stop: { [weak self] in self?.dictation.stopAndProcess() },
            cancel: { [weak self] in self?.dictation.cancelRecording() },
            openHistory: { [weak self] in self?.openHub(.home) },
            openSettings: { [weak self] in self?.openHub(.settings) },
            cycleLanguage: { [weak self] in self?.dictation.cycleLanguage(announce: false) },
            messageTapped: { [weak self] in self?.openHub(.home) },
            dragChanged: { [weak self] in self?.dragChanged() },
            dragEnded: { [weak self] in self?.dragEnded() }
        )
        let root = FlowBarView(state: state, dictation: dictation, settings: settings, actions: actions)
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        dictation.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                if phase.isRecording { self?.followMouseScreen() }
                self?.refresh()
            }
            .store(in: &cancellables)
        settings.$flowBarAlwaysVisible
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        settings.$flowBarEdge
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)
    }

    func show() {
        relayout()
        refresh()
    }

    // MARK: State

    private func computeVisual() -> FlowBarVisual {
        switch dictation.phase {
        case .recording:
            return .recording
        case .transcribing:
            return .processing("Transcribing…")
        case .polishing:
            return .processing("Polishing…")
        case .done(let message):
            return .message(message, isError: false)
        case .failed(let message):
            return .message(message, isError: true)
        case .idle:
            if isHovering || state.isDragging { return .menu }
            return settings.flowBarAlwaysVisible ? .orb : .hidden
        }
    }

    private func refresh() {
        let visual = computeVisual()
        if visual != state.visual {
            state.visual = visual
        }
        if visual == .hidden {
            if panel.isVisible { panel.orderOut(nil) }
            stopTimer()
        } else {
            if !panel.isVisible {
                position()
                panel.orderFrontRegardless()
            }
            startTimer()
        }
    }

    // MARK: Mouse tracking

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let origin = panel.frame.origin
        let rect = FlowBarLayout.contentRect(state.visual, edge: state.edge).offsetBy(dx: origin.x, dy: origin.y)

        if !state.isDragging {
            var hover = false
            if dictation.phase == .idle, state.visual != .hidden {
                // Expand when the pointer comes close; keep open while it stays near the menu.
                let margin: CGFloat = state.visual == .menu ? 20 : 44
                hover = rect.insetBy(dx: -margin, dy: -margin).contains(mouse)
            }
            if hover != isHovering {
                isHovering = hover
                refresh()
            }
        }

        // Clicks pass through the transparent parts of the panel.
        let interactive = state.isDragging || rect.contains(mouse)
        if panel.ignoresMouseEvents == interactive {
            panel.ignoresMouseEvents = !interactive
        }
    }

    // MARK: Placement

    private static func number(of screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private func targetScreen() -> NSScreen? {
        if let screenNumber, let match = NSScreen.screens.first(where: { Self.number(of: $0) == screenNumber }) {
            return match
        }
        return NSScreen.screens.first
    }

    private func position() {
        guard let screen = targetScreen() else { return }
        let frame = FlowBarLayout.panelFrame(edge: settings.flowBarEdge, position: settings.flowBarPosition, screen: screen)
        panel.setFrame(frame, display: true)
    }

    private func relayout() {
        if state.edge != settings.flowBarEdge {
            state.edge = settings.flowBarEdge
        }
        position()
    }

    /// The bar appears on the display you are working on.
    private func followMouseScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let number = Self.number(of: screen), number != screenNumber else { return }
        screenNumber = number
        position()
    }

    // MARK: Drag to move

    private func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if !state.isDragging {
            state.isDragging = true
            dragOffset = CGPoint(x: mouse.x - panel.frame.origin.x, y: mouse.y - panel.frame.origin.y)
        }
        panel.setFrameOrigin(NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y))
    }

    private func dragEnded() {
        let mouse = NSEvent.mouseLocation
        state.isDragging = false
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? targetScreen() else { return }
        let visible = screen.visibleFrame
        let toLeft = mouse.x - visible.minX
        let toRight = visible.maxX - mouse.x
        let toBottom = mouse.y - visible.minY

        // Snap to the nearest of bottom, left or right.
        let edge: FlowBarEdge
        if toBottom <= min(toLeft, toRight) {
            edge = .bottom
        } else if toLeft <= toRight {
            edge = .left
        } else {
            edge = .right
        }
        let raw = edge == .bottom
            ? (mouse.x - visible.minX) / max(visible.width, 1)
            : (mouse.y - visible.minY) / max(visible.height, 1)

        screenNumber = Self.number(of: screen)
        settings.flowBarPosition = Double(min(max(raw, 0.04), 0.96))
        settings.flowBarEdge = edge
        relayout()
        isHovering = false
        refresh()
    }
}
