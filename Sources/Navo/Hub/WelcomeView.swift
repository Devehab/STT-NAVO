import AVFoundation
import SwiftUI

/// The first thing a new user sees: three steps, one button each, and nothing else to decide.
/// It covers the whole window until Navo can dictate (the engine is on this Mac and the two
/// permissions are allowed) or the user chooses to finish later in Settings.
@MainActor
struct WelcomeView: View {
    @EnvironmentObject private var engine: LocalEngineManager
    @EnvironmentObject private var settings: AppSettings
    let onDone: () -> Void

    @State private var microphone = MicrophonePermission.status
    @State private var accessibility = TextInjector.isTrusted
    @State private var installed = false
    @State private var showDetails = false
    @State private var freeDisk: Int64?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Whether Navo still needs something before the first dictation.
    static func isNeeded(_ engine: LocalEngineManager) -> Bool {
        !engine.isInstalled || !TextInjector.isTrusted || MicrophonePermission.status != .authorized
    }

    private var ready: Bool { installed && microphone == .authorized && accessibility }

    private var failure: String? {
        guard !installed, case .failed(let message) = engine.state else { return nil }
        return message
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(navoBrandGradient)
                    Text(ready ? "Navo is ready" : "Welcome to Navo")
                        .font(.system(size: 28, weight: .semibold))
                    Text(ready
                        ? "Click into any text field, hold \(keyName), talk, and let go."
                        : "Three steps and you can talk instead of typing. Everything stays on this Mac.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                VStack(spacing: 12) {
                    engineStep
                    WelcomeStep(
                        number: 2,
                        done: microphone == .authorized,
                        title: "Allow the microphone",
                        detail: "Navo listens only while you hold the dictation key."
                    ) {
                        Button(microphone == .notDetermined ? "Allow" : "Open Settings") { allowMicrophone() }
                    }
                    WelcomeStep(
                        number: 3,
                        done: accessibility,
                        title: "Allow Accessibility",
                        detail: "So Navo can see the dictation key and paste the text for you. In the list that opens, turn on Navo."
                    ) {
                        Button("Open Settings") { allowAccessibility() }
                    }
                }

                if ready {
                    Button("Start using Navo") { onDone() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Finish later in Settings") { onDone() }
                        .buttonStyle(.link)
                }
            }
            .frame(maxWidth: 580)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }

    // MARK: Step 1

    @ViewBuilder
    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            WelcomeStep(
                number: 1,
                done: installed,
                title: installed ? "Navo's engine is on this Mac" : "Download Navo's engine",
                detail: engineDetail,
                framed: false
            ) {
                if engine.state == .installing {
                    Text("\(Int((engine.installProgress * 100).rounded()))%")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if !installed {
                    Button(failure == nil ? "Download and set up" : "Try again") {
                        showDetails = false
                        // No token: Navo sets up the model that needs no account.
                        engine.install(huggingFaceToken: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.isBusy)
                }
            }
            if engine.state == .installing {
                ProgressView(value: engine.installProgress)
                Text(engine.installStatus.isEmpty ? "Starting" : engine.installStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    ScrollView {
                        Text(engine.installLog.suffix(40).joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 130)
                }
                .font(.callout)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var engineDetail: String {
        if installed {
            return "The speech model works offline from now on."
        }
        if engine.state == .installing {
            return "You can keep using your Mac. Leave Navo open until this finishes."
        }
        var text = "About 7 GB, one time, then Navo works with no internet. No account and nothing else to install."
        if let free = freeDisk, free < 9_000_000_000 {
            text += " This Mac has only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free: make room first."
        }
        return text
    }

    // MARK: Actions

    private var keyName: String {
        let name = settings.pushToTalkKey.shortName
        return name.isEmpty ? "the dictation key" : name
    }

    private func refresh() {
        let mic = MicrophonePermission.status
        if mic != microphone { microphone = mic }
        let trusted = TextInjector.isTrusted
        if trusted != accessibility { accessibility = trusted }
        let present = engine.isInstalled
        if present != installed { installed = present }
        if freeDisk == nil { freeDisk = SetupSection.freeDiskBytes }
    }

    private func allowMicrophone() {
        if microphone == .notDetermined {
            Task { @MainActor in
                _ = await MicrophonePermission.request()
                microphone = MicrophonePermission.status
            }
        } else {
            openSystemSettings("Privacy_Microphone")
        }
    }

    private func allowAccessibility() {
        TextInjector.requestTrust()
        openSystemSettings("Privacy_Accessibility")
    }

    private func openSystemSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// One step: its number or a check mark, what it is for, and the one thing to click.
private struct WelcomeStep<Action: View>: View {
    let number: Int
    let done: Bool
    let title: String
    let detail: String
    var framed = true
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.primary.opacity(0.1))
                    .frame(width: 30, height: 30)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if !done {
                action()
            }
        }
        .padding(framed ? 16 : 0)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(framed ? 0.05 : 0))
        )
    }
}
