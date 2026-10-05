import AppKit

/// Watches the push-to-talk modifier (Right ⌥ by default) and Escape, system-wide.
/// Global keyboard monitoring requires the Accessibility permission.
@MainActor
final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Another key was pressed while the push-to-talk key is held.
    var onOtherKey: (() -> Void)?
    var onEscape: (() -> Void)?

    private var monitors: [Any] = []
    private var key: PushToTalkKey = .off
    private var isDown = false

    func start(key: PushToTalkKey) {
        stop()
        self.key = key

        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated { self.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated { self.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        if isDown {
            isDown = false
            onRelease?()
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 {
                onEscape?()
            } else if isDown {
                onOtherKey?()
            }
        case .flagsChanged:
            guard key != .off else { return }
            if key.keyCodes.contains(event.keyCode) {
                let down = (event.modifierFlags.rawValue & key.deviceMask) != 0
                if down && !isDown {
                    isDown = true
                    onPress?()
                } else if !down && isDown {
                    isDown = false
                    onRelease?()
                }
            } else if isDown {
                onOtherKey?()
            }
        default:
            break
        }
    }
}
