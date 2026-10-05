import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (Carbon hot key): works in every app, needs no permission,
/// and the key press does not reach the app in front.
@MainActor
final class GlobalShortcut {
    private static var actions: [UInt32: () -> Void] = [:]
    /// Every shortcut in use, so they can all be set aside while a new one is recorded.
    private static var live: [UInt32: GlobalShortcut] = [:]
    /// Recorders open right now; the shortcuts are back once the last one closes.
    private static var suspensions = 0
    private static var suspended: Bool { suspensions > 0 }
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private let id: UInt32
    private let keyCode: Int
    private let modifiers: Int
    private var reference: EventHotKeyRef?
    /// Called when the shortcut could not be taken back after a recording (another app took it).
    var onLost: (() -> Void)?

    /// Nil when macOS refuses the combination (another app already holds it exclusively).
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        self.keyCode = keyCode
        self.modifiers = modifiers
        // While a shortcut is being recorded it waits, and takes the keys when recording ends.
        guard Self.suspended || register() else { return nil }
        Self.actions[id] = action
        Self.live[id] = self
    }

    private func register() -> Bool {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E41_564F), id: id) // "NAVO"
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetEventDispatcherTarget(),
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        guard status == noErr, let reference else { return false }
        self.reference = reference
        return true
    }

    private func releaseKeys() {
        if let reference {
            UnregisterEventHotKey(reference)
        }
        reference = nil
    }

    func unregister() {
        releaseKeys()
        Self.actions[id] = nil
        Self.live[id] = nil
    }

    /// While a new shortcut is recorded none of Navo's shortcuts may take the key press, or the
    /// current combination could never be recorded again.
    static func suspendAll(_ value: Bool) {
        let before = suspended
        suspensions = max(0, suspensions + (value ? 1 : -1))
        guard suspended != before else { return }
        for shortcut in live.values {
            if suspended {
                shortcut.releaseKeys()
            } else if !shortcut.register() {
                shortcut.onLost?()
            }
        }
    }

    /// Carbon calls this on the main thread for every registered hot key.
    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            MainActor.assumeIsolated {
                GlobalShortcut.actions[id]?()
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// A key with modifiers, as the user pressed it, for a system-wide shortcut.
struct KeyShortcut: Codable, Equatable {
    /// Virtual key code (a key's position, the same whatever the keyboard language).
    var keyCode: Int
    /// Carbon modifier bits (cmdKey, optionKey, controlKey, shiftKey).
    var modifiers: Int

    /// Control + Option + L.
    static let languageDefault = KeyShortcut(keyCode: kVK_ANSI_L, modifiers: controlKey | optionKey)
    /// Control + Option + V: the quick clipboard list.
    static let clipboardDefault = KeyShortcut(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey)

    /// Why this combination can't be a shortcut, or nil when it can.
    var problem: String? {
        let command = modifiers & cmdKey != 0
        let control = modifiers & controlKey != 0
        if !command && !control {
            return "Include Control or Command: macOS does not allow shortcuts with only Option or Shift."
        }
        if command && modifiers & (controlKey | optionKey | shiftKey) == 0 {
            return "Command with one key belongs to the apps you use. Add Control, Option or Shift."
        }
        return nil
    }

    /// The modifiers held with a key press, or nil when there are none a shortcut can use
    /// (Shift alone would clash with typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else { return nil }
        guard Self.keyNames[Int(event.keyCode)] != nil, event.keyCode != UInt16(kVK_Escape) else { return nil }
        var bits = 0
        if flags.contains(.control) { bits |= controlKey }
        if flags.contains(.option) { bits |= optionKey }
        if flags.contains(.shift) { bits |= shiftKey }
        if flags.contains(.command) { bits |= cmdKey }
        self.init(keyCode: Int(event.keyCode), modifiers: bits)
    }

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    private var parts: [(symbol: String, name: String)] {
        var parts: [(symbol: String, name: String)] = []
        if modifiers & controlKey != 0 { parts.append(("⌃", "Control")) }
        if modifiers & optionKey != 0 { parts.append(("⌥", "Option")) }
        if modifiers & shiftKey != 0 { parts.append(("⇧", "Shift")) }
        if modifiers & cmdKey != 0 { parts.append(("⌘", "Command")) }
        return parts
    }

    var key: String { Self.keyNames[keyCode] ?? "Key \(keyCode)" }

    /// For showing the shortcut in a menu: the key as a menu key equivalent (letters and digits
    /// only) and its modifiers.
    var menuKey: (key: String, modifiers: NSEvent.ModifierFlags)? {
        let name = key
        guard name.count == 1, let character = name.first, character.isLetter || character.isNumber else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { flags.insert(.control) }
        if modifiers & optionKey != 0 { flags.insert(.option) }
        if modifiers & shiftKey != 0 { flags.insert(.shift) }
        if modifiers & cmdKey != 0 { flags.insert(.command) }
        return (name.lowercased(), flags)
    }

    /// "⌃⌥L"
    var symbols: String { parts.map(\.symbol).joined() + key }

    /// "Control + Option + L", readable without knowing the Mac's key symbols.
    var spelled: String { (parts.map(\.name) + [key]).joined(separator: " + ") }

    /// Names of the keys a shortcut can end with, by key code (US layout positions).
    private static let keyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (number, code) in functionKeys.enumerated() {
            names[code] = "F\(number + 1)"
        }
        return names
    }()
}
