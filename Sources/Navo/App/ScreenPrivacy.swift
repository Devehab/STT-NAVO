import AppKit
import Combine

/// Private mode: keeps Navo's windows (the Hub, the Flow Bar, the live text, the clipboard list,
/// sheets and alerts) out of screen sharing, screenshots and screen recordings, in Zoom, Meet,
/// Teams, QuickTime or the screenshot tool, while you still see them on your screen.
///
/// macOS leaves a window out of every capture when its sharing type is none. This sets it on each
/// window Navo has, and on new ones as they appear. The menu bar icon belongs to macOS's menu bar
/// and stays in a capture of the whole screen.
@MainActor
final class ScreenPrivacy {
    /// Read by the panels as they are made, so they are never captured before the first check.
    private(set) static var isOn = false

    static var sharingType: NSWindow.SharingType { isOn ? .none : .readOnly }

    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        Self.isOn = settings.privateMode
        settings.$privateMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                Self.isOn = on
                self?.applyToAll()
            }
            .store(in: &cancellables)
        // A window that appears (a sheet, an alert, the clipboard list) or changes, and every pass
        // of the event loop: cheap, Navo has a handful of windows.
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
            center.publisher(for: name)
                .sink { note in
                    MainActor.assumeIsolated {
                        if let window = note.object as? NSWindow { Self.apply(to: window) }
                    }
                }
                .store(in: &cancellables)
        }
        center.publisher(for: NSApplication.didUpdateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applyToAll() }
            }
            .store(in: &cancellables)
        applyToAll()
    }

    func applyToAll() {
        for window in NSApp.windows {
            Self.apply(to: window)
        }
    }

    static func apply(to window: NSWindow) {
        let wanted = sharingType
        if window.sharingType != wanted {
            window.sharingType = wanted
        }
    }
}
