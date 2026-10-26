import AppIntents
import AppKit
import SwiftUI
import WidgetKit

/// Navo's controls for Control Center and the menu bar (macOS 26): add them in Control Center >
/// Edit Controls. A control only asks Navo to act, with a distributed notification, so Navo stays
/// in the background and dictation pastes into the app you were typing in. What a toggle shows
/// comes from a small file Navo writes (Navo/Controls/state.json), read through the sandbox
/// exception in NavoControls.entitlements.
@main
struct NavoControls: WidgetBundle {
    var body: some Widget {
        DictateControl()
        RecordControl()
        LanguageControl()
        PrivateModeControl()
        ClipboardControl()
        FlowBarControl()
    }
}

// MARK: Talking to Navo

enum Navo {
    static let bundleID = "com.ehab-kahwati.navo"

    /// "dictate", "record.start", "language.next"…: Navo's ControlCenterLink acts on them.
    @MainActor
    static func send(_ command: String) async {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
        if running {
            // A sandboxed extension may post a notification by its name, with no user info.
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.ehab-kahwati.navo.control." + command),
                object: nil, userInfo: nil, deliverImmediately: true
            )
        } else if let url = URL(string: "navo://control/" + command) {
            // Navo is not running: open it with the same request, kept in the background.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.open(url, configuration: configuration)
        }
    }

    /// What Navo last said about itself. Missing (Navo never ran with controls): nil.
    struct State: Decodable {
        var recording = false
        var language = "ar"
        var languageName = "Arabic"
        var privateMode = false
        var flowBarShown = true
    }

    static func state() -> State? {
        // The real home folder, not the sandbox container.
        var home = NSHomeDirectory()
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            home = String(cString: directory)
        }
        let url = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Navo/Controls/state.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }
}

// MARK: Dictate

/// Starts dictation, or stops it and pastes the text: the same as Start Dictation in Navo's menu.
struct DictateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.ehab-kahwati.navo.control.dictate") {
            ControlWidgetButton(action: DictateIntent()) {
                Label("Dictate", systemImage: "waveform")
            }
        }
        .displayName("Dictate")
        .description("Start dictating, or stop and paste the text into the app you are typing in.")
    }
}

struct DictateIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate with Navo"
    static let description = IntentDescription("Starts dictation in Navo, or stops it and pastes the text.")

    @MainActor
    func perform() async throws -> some IntentResult {
        await Navo.send("dictate")
        return .result()
    }
}

// MARK: Record a meeting

struct RecordingValue: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        Navo.state()?.recording ?? false
    }
}

/// On while a meeting is being recorded. Turning it on records what Notetaker is set to record.
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.ehab-kahwati.navo.control.record", provider: RecordingValue()) { recording in
            ControlWidgetToggle("Record meeting", isOn: recording, action: RecordIntent()) { isOn in
                Label(isOn ? "Recording" : "Off", systemImage: isOn ? "record.circle.fill" : "record.circle")
            }
        }
        .displayName("Record meeting")
        .description("Start or stop recording a meeting in Navo's Notetaker, with its live text.")
    }
}

struct RecordIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Record a meeting with Navo"

    @Parameter(title: "Recording")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        await Navo.send(value ? "record.start" : "record.stop")
        return .result()
    }
}

// MARK: Dictation language

struct LanguageValue: ControlValueProvider {
    var previewValue: String { "Arabic" }

    func currentValue() async throws -> String {
        Navo.state()?.languageName ?? "Arabic"
    }
}

/// Shows the dictation language, and switches between Arabic and English.
struct LanguageControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.ehab-kahwati.navo.control.language", provider: LanguageValue()) { name in
            ControlWidgetButton(action: NextLanguageIntent()) {
                Label(name, systemImage: "character.bubble")
            }
        }
        .displayName("Dictation language")
        .description("Shows the language Navo dictates in, and switches between Arabic and English.")
    }
}

struct NextLanguageIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Navo's dictation language"

    @MainActor
    func perform() async throws -> some IntentResult {
        await Navo.send("language.next")
        return .result()
    }
}

// MARK: Hide from screen sharing

struct PrivateModeValue: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        Navo.state()?.privateMode ?? false
    }
}

struct PrivateModeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.ehab-kahwati.navo.control.private", provider: PrivateModeValue()) { hidden in
            ControlWidgetToggle("Hide from sharing", isOn: hidden, action: PrivateModeIntent()) { isOn in
                Label(isOn ? "Hidden" : "Visible", systemImage: isOn ? "eye.slash.fill" : "eye")
            }
        }
        .displayName("Hide Navo from screen sharing")
        .description("Private mode: Navo's windows stay out of screen sharing and recordings.")
    }
}

struct PrivateModeIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Hide Navo from screen sharing"

    @Parameter(title: "Hidden")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        await Navo.send(value ? "private.on" : "private.off")
        return .result()
    }
}

// MARK: Clipboard history

struct ClipboardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.ehab-kahwati.navo.control.clipboard") {
            ControlWidgetButton(action: ClipboardIntent()) {
                Label("Clipboard", systemImage: "doc.on.clipboard")
            }
        }
        .displayName("Clipboard history")
        .description("Opens Navo's Quick Paste: everything you copied, to paste again.")
    }
}

struct ClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Navo's clipboard history"

    @MainActor
    func perform() async throws -> some IntentResult {
        await Navo.send("clipboard")
        return .result()
    }
}

// MARK: Flow Bar

struct FlowBarValue: ControlValueProvider {
    var previewValue: Bool { true }

    func currentValue() async throws -> Bool {
        Navo.state()?.flowBarShown ?? true
    }
}

/// On: the Flow Bar is always there. Off: it shows only while you dictate.
struct FlowBarControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.ehab-kahwati.navo.control.flowbar", provider: FlowBarValue()) { shown in
            ControlWidgetToggle("Flow Bar", isOn: shown, action: FlowBarIntent()) { isOn in
                Label(isOn ? "Shown" : "Hidden", systemImage: isOn ? "capsule.bottomhalf.filled" : "capsule")
            }
        }
        .displayName("Flow Bar")
        .description("Show Navo's Flow Bar all the time, or only while you dictate.")
    }
}

struct FlowBarIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Show Navo's Flow Bar"

    @Parameter(title: "Shown")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        await Navo.send(value ? "flowbar.show" : "flowbar.hide")
        return .result()
    }
}
