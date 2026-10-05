import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Shows a keyboard shortcut in words and lets you set a new one by pressing it.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?
    /// What Reset sets.
    let fallback: KeyShortcut
    /// Navo's other shortcut: the same keys can't do two things.
    var taken: KeyShortcut?

    @StateObject private var capture = ShortcutCapture()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if capture.recording {
                        capture.stop()
                    } else {
                        capture.start(taken: taken) { shortcut = $0 }
                    }
                } label: {
                    Text(capture.recording ? "Press the keys now…" : (shortcut?.spelled ?? "Off"))
                        .frame(minWidth: 190)
                }
                .help(capture.recording ? "Hold Control or Command, then press a letter. Esc cancels." : "Click, then press the keys you want")
                if !capture.recording {
                    if shortcut != nil {
                        Button("Turn off") { shortcut = nil }
                    }
                    if shortcut != fallback && fallback != taken {
                        Button("Reset") { shortcut = fallback }
                            .help("Back to \(fallback.spelled)")
                    }
                }
            }
            if let hint = capture.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
            }
        }
        .onDisappear { capture.stop() }
    }
}

/// Listens for the new shortcut in the window it is recorded in, and only while that window has
/// the keyboard: keys pressed anywhere else (the quick paste panel, another window) are left alone.
/// Navo's shortcuts are set aside meanwhile, so their current keys can be pressed again too.
@MainActor
final class ShortcutCapture: NSObject, ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var hint: String?

    private var monitor: Any?
    private weak var window: NSWindow?

    func start(taken: KeyShortcut?, onPick: @escaping (KeyShortcut) -> Void) {
        stop()
        guard let window = NSApp.keyWindow else { return }
        self.window = window
        recording = true
        GlobalShortcut.suspendAll(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.handle(event, taken: taken, onPick: onPick) ?? false
            }
            return handled ? nil : event
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResignedKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    /// Another window or app took the keyboard: recording ends.
    @objc private func windowResignedKey(_ notification: Notification) {
        stop()
    }

    private func handle(_ event: NSEvent, taken: KeyShortcut?, onPick: (KeyShortcut) -> Void) -> Bool {
        guard recording, event.window === window else { return false }
        if event.keyCode == UInt16(kVK_Escape) {
            stop()
            return true
        }
        guard let pressed = KeyShortcut(event: event) else {
            hint = "Hold Control or Command (Option and Shift can join them), then press a letter or number."
            return true
        }
        if let problem = pressed.problem {
            hint = problem
            return true
        }
        if pressed == taken {
            hint = "\(pressed.spelled) is already Navo's other shortcut. Pick another one."
            return true
        }
        onPick(pressed)
        stop()
        return true
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        window = nil
        hint = nil
        if recording {
            recording = false
            GlobalShortcut.suspendAll(false)
        }
    }
}
