import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts text into whatever text field has focus: clipboard + synthetic ⌘V, then restores the clipboard.
@MainActor
enum TextInjector {
    enum Outcome {
        case pasted
        /// Focus could not be read (many Chromium/Electron apps): pasted, and the text also stays on the clipboard.
        case pastedAndCopied
        case copied(String)
    }

    nonisolated static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security > Accessibility.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func insert(_ text: String, autoPaste: Bool, restoreClipboard: Bool) -> Outcome {
        let pasteboard = NSPasteboard.general

        guard autoPaste else {
            write(text, to: pasteboard, transient: false)
            return .copied("Copied to clipboard")
        }
        guard isTrusted else {
            write(text, to: pasteboard, transient: false)
            return .copied("Copied. Allow Accessibility to auto-paste")
        }
        if IsSecureEventInputEnabled() {
            write(text, to: pasteboard, transient: false)
            return .copied("Secure field: press ⌘V")
        }

        switch FocusInspector.currentTarget() {
        case .notEditable:
            // No text field has focus (for example you switched apps while Navo was working).
            write(text, to: pasteboard, transient: false)
            return .copied("No text field here. Copied, press ⌘V to paste")
        case .unknown:
            write(text, to: pasteboard, transient: false)
            postCommandV()
            return .pastedAndCopied
        case .editable:
            break
        }

        let saved = restoreClipboard ? snapshot(pasteboard) : nil
        write(text, to: pasteboard, transient: true)
        let ourChange = pasteboard.changeCount
        postCommandV()

        if let saved {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                // Only restore if nothing else touched the clipboard in the meantime.
                if pasteboard.changeCount == ourChange {
                    TextInjector.restore(saved, to: pasteboard)
                }
            }
        }
        return .pasted
    }

    /// Presses ⌘V in the app in front, for text Navo has just put on the clipboard. False when
    /// macOS does not allow it (no Accessibility permission, or a password field has the keyboard).
    @discardableResult
    static func pasteNow() -> Bool {
        guard isTrusted, !IsSecureEventInputEnabled() else { return false }
        postCommandV()
        return true
    }

    static func copy(_ text: String) {
        write(text, to: NSPasteboard.general, transient: false)
    }

    private static func write(_ text: String, to pasteboard: NSPasteboard, transient: Bool) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if transient {
            // Convention honored by clipboard managers: do not record this entry.
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            return entry
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        // Putting back what was there is not a new copy: clipboard histories (Navo's too) skip it.
        restored.first?.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects(restored)
    }
}
