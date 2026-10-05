import AppKit
import ApplicationServices

/// What has keyboard focus when the transcript is ready.
enum FocusTarget: Equatable {
    /// A text field, text view or rich editor: paste.
    case editable
    /// Something readable that is not a text input (a button, a list, a web page with no field focused): copy instead.
    case notEditable
    /// The app does not expose its focus (many Chromium and Electron apps, games): paste and keep the text on the clipboard.
    case unknown
}

/// Reads the focused UI element through the Accessibility API, like other dictation apps do before pasting.
@MainActor
enum FocusInspector {
    private static var preparedPIDs = Set<pid_t>()

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// Containers that may wrap an editor without saying so (Slack's composer is an AXGroup).
    private static let ambiguousRoles: Set<String> = ["AXGroup", "AXScrollArea", "AXUnknown", "AXLayoutArea", ""]

    /// Call when recording starts: Electron apps build their accessibility tree only when asked,
    /// so by the time the transcript is ready their focus can be read.
    static func prepare(_ app: NSRunningApplication?) {
        guard let app, TextInjector.isTrusted else { return }
        let pid = app.processIdentifier
        guard !preparedPIDs.contains(pid) else { return }
        preparedPIDs.insert(pid)
        let element = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func currentTarget() -> FocusTarget {
        guard TextInjector.isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(appElement, 0.3)

        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return .unknown
        }
        return classify(value as! AXUIElement)
    }

    static func classify(_ element: AXUIElement) -> FocusTarget {
        if bool(element, kAXEnabledAttribute) == false {
            return .notEditable
        }
        let role = string(element, kAXRoleAttribute) ?? ""
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        if subrole == "AXSecureTextField" {
            return .editable // TextInjector copies instead of pasting into password fields
        }
        let writable = isSettable(element, kAXValueAttribute) || isSettable(element, kAXSelectedTextRangeAttribute)
        if textRoles.contains(role) {
            if writable { return .editable }
            // Terminal-like views are text areas that do not report writability but accept typing.
            return role == "AXTextArea" ? .unknown : .notEditable
        }
        if writable {
            return .editable // contenteditable and custom editors
        }
        if ambiguousRoles.contains(role) {
            return .unknown
        }
        return .notEditable // buttons, links, lists, tables, windows, a web page with no field focused
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }
}
