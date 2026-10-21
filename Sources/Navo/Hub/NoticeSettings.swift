import AppKit
import SwiftUI

/// Settings > Notetaker and Transcribe: a notification when transcriptions are done.
struct DoneNotificationsSection: View {
    @EnvironmentObject private var settings: AppSettings
    /// Nil: macOS has not asked yet (it asks when the first transcription starts, or on Send a test).
    @State private var allowed: Bool?

    var body: some View {
        Section {
            Picker("Tell me when transcriptions are done", selection: $settings.doneNotifications) {
                ForEach(DoneNotifications.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.doneNotifications != .off {
                HStack {
                    if allowed == false {
                        Label("macOS has Navo's notifications turned off.", systemImage: "bell.slash")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") { DoneNotifier.openSystemSettings() }
                    } else {
                        Text("See how one looks")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Send a test") {
                            Task { @MainActor in
                                allowed = await DoneNotifier.current?.permission()
                                if allowed == true { DoneNotifier.current?.sendTest() }
                            }
                        }
                        .disabled(DoneNotifier.current == nil)
                    }
                }
            }
        } header: {
            SectionTitle("When transcriptions are done", "bell")
        } footer: {
            Text("Clicking a notification opens the recording or file. macOS keeps notifications off the screen while you share it, unless you allowed them in System Settings > Notifications. The menu bar icon shows the progress too.")
                .foregroundStyle(.secondary)
        }
        .task { allowed = await DoneNotifier.current?.isAllowed() }
    }

    private var explanation: String {
        switch settings.doneNotifications {
        case .each:
            return "A notification as each recording or file is done, or fails. When you sent several, the last one says how all of them went."
        case .allDone:
            return "One notification when everything in line is done: one recording or file, or ten you sent together (with how many worked)."
        case .off:
            return "No notifications. The menu bar icon still shows the progress and a check mark when it is done."
        }
    }
}

/// Settings > Privacy: how the menu bar icon looks, Navo's icons or emoji you pick.
struct MenuBarIconSection: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Section {
            Picker("Look", selection: $settings.menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            if settings.menuBarStyle == .emoji {
                EmojiField(title: "Recording a meeting", detail: "Instead of the red dot", value: emoji(\.recording))
                EmojiField(title: "Recording paused", detail: "Instead of the orange pause", value: emoji(\.paused))
                EmojiField(title: "Transcribing", detail: "Instead of the circle that fills up", value: emoji(\.working))
                EmojiField(title: "Done", detail: "Instead of the check mark", value: emoji(\.done))
                EmojiField(title: "Nothing going on", detail: "Empty: Navo's waveform", value: emoji(\.idle))
                HStack(alignment: .firstTextBaseline) {
                    Text("Type or paste one emoji in each, or click the face for the emoji picker. Empty uses Navo's own icon. Pick ones only you know the meaning of.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Suggested") { settings.menuBarEmoji = MenuBarEmoji() }
                        .help("Back to 🌿 recording, 🍂 paused, ⏳ transcribing and ☕️ done")
                }
            }
            SettingToggle(
                "Show the time and the percentage next to it",
                detail: "The recording's clock, and how far a transcription is. Off: only the icon, so nothing next to it reads like a recording.",
                isOn: $settings.menuBarShowsText
            )
            LabeledContent("While recording it shows") {
                Text(preview)
                    .font(.system(size: 14).monospacedDigit())
            }
        } header: {
            SectionTitle("Menu bar icon", "menubar.rectangle")
        } footer: {
            Text("The menu bar belongs to macOS, so it shows when you share the whole screen, even in private mode. With emoji, its tooltip only says Navo, and the menu still lists what is going on when you click it.")
                .foregroundStyle(.secondary)
        }
    }

    private func emoji(_ key: WritableKeyPath<MenuBarEmoji, String>) -> Binding<String> {
        Binding(
            get: { settings.menuBarEmoji[keyPath: key] },
            set: { settings.menuBarEmoji[keyPath: key] = MenuBarEmoji.clean($0) }
        )
    }

    private var preview: String {
        let clock = settings.menuBarShowsText ? " 18:48" : ""
        guard settings.menuBarStyle == .emoji, !settings.menuBarEmoji.recording.isEmpty else {
            return "🔴" + clock
        }
        return settings.menuBarEmoji.recording + clock
    }
}

/// One emoji, with a button for macOS's emoji picker.
private struct EmojiField: View {
    let title: String
    let detail: String
    @Binding var value: String
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField("", text: $value, prompt: Text("–"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 16))
                    .frame(width: 54)
                    .focused($focused)
                Button {
                    focused = true
                    DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                } label: {
                    Image(systemName: "face.smiling")
                }
                .buttonStyle(.borderless)
                .help("Pick an emoji (Control-Command-Space)")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
