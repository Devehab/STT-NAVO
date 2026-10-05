import SwiftUI

struct FlowBarView: View {
    @ObservedObject var state: FlowBarState
    @ObservedObject var dictation: DictationController
    @ObservedObject var settings: AppSettings
    let actions: FlowBarActions

    var body: some View {
        ZStack(alignment: FlowBarLayout.alignment(state.edge)) {
            Color.clear
            content
                .frame(
                    width: FlowBarLayout.size(state.visual, edge: state.edge).width,
                    height: FlowBarLayout.size(state.visual, edge: state.edge).height
                )
                .padding(FlowBarLayout.padding(state.edge), FlowBarLayout.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.visual)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.edge)
    }

    @ViewBuilder
    private var content: some View {
        switch state.visual {
        case .hidden:
            Color.clear
        case .orb:
            OrbView()
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        case .menu:
            MenuView(vertical: state.edge != .bottom, hint: settings.pushToTalkKey, language: settings.language,
                     shortcut: settings.languageShortcut, actions: actions)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
        case .recording:
            RecordingView(dictation: dictation, language: settings.language, shortcut: settings.languageShortcut, actions: actions)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        case .processing(let label):
            ProcessingView(label: label)
                .transition(.opacity)
        case .message(let text, let isError):
            MessageView(text: text, isError: isError, onTap: actions.messageTapped)
                .transition(.opacity)
        }
    }
}

// MARK: Pieces

private struct Pill<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.88))
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            )
    }
}

private let navoGradient = LinearGradient(
    colors: [Color(red: 0.55, green: 0.40, blue: 1.0), Color(red: 0.20, green: 0.72, blue: 1.0)],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

private struct OrbView: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.55))
            Circle().strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5).padding(2)
            Circle().fill(navoGradient).padding(6)
        }
    }
}

private struct DragHandle: View {
    let vertical: Bool
    let actions: FlowBarActions

    var body: some View {
        let dots = ForEach(0..<3, id: \.self) { _ in
            Circle().fill(Color.white.opacity(0.45)).frame(width: 3, height: 3)
        }
        Group {
            if vertical {
                HStack(spacing: 3) { dots }
            } else {
                VStack(spacing: 3) { dots }
            }
        }
        .frame(width: vertical ? 40 : 16, height: vertical ? 16 : 40)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { _ in actions.dragChanged() }
                .onEnded { _ in actions.dragEnded() }
        )
        .help("Drag to move")
    }
}

private struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The dictation language; a click switches to the next one the engine supports.
private struct LanguageChip: View {
    let language: DictationLanguage
    let shortcut: KeyShortcut?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(language.badge)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 7)
                .frame(minWidth: 30, minHeight: 22)
                .background(Capsule().fill(Color.white.opacity(0.16)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Dictation language: \(language.name). Click to switch" + (shortcut.map { ", or press \($0.spelled) in any app." } ?? "."))
    }
}

private struct MenuView: View {
    let vertical: Bool
    let hint: PushToTalkKey
    let language: DictationLanguage
    let shortcut: KeyShortcut?
    let actions: FlowBarActions

    private var speakButton: some View {
        Button(action: actions.speak) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(navoGradient))
                if !vertical {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Speak")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        if hint != .off {
                            Text("or hold \(hint.shortName)")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint == .off ? "Start dictation" : "Start dictation, or hold \(hint.shortName). Double-tap for hands-free.")
    }

    var body: some View {
        Pill {
            if vertical {
                VStack(spacing: 6) {
                    DragHandle(vertical: true, actions: actions)
                    speakButton
                    LanguageChip(language: language, shortcut: shortcut, action: actions.cycleLanguage)
                    IconButton(systemName: "clock.arrow.circlepath", help: "History", action: actions.openHistory)
                    IconButton(systemName: "gearshape", help: "Settings", action: actions.openSettings)
                }
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 8) {
                    DragHandle(vertical: false, actions: actions)
                    speakButton
                    Spacer(minLength: 0)
                    LanguageChip(language: language, shortcut: shortcut, action: actions.cycleLanguage)
                    IconButton(systemName: "clock.arrow.circlepath", help: "History", action: actions.openHistory)
                    IconButton(systemName: "gearshape", help: "Settings", action: actions.openSettings)
                }
                .padding(.leading, 6)
                .padding(.trailing, 8)
            }
        }
    }
}

private struct RecordingView: View {
    @ObservedObject var dictation: DictationController
    let language: DictationLanguage
    let shortcut: KeyShortcut?
    let actions: FlowBarActions
    @State private var pulse = false

    var body: some View {
        Pill {
            HStack(spacing: 10) {
                Button(action: actions.cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")

                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }

                Waveform(levels: dictation.levels)
                    .frame(maxWidth: .infinity)

                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Text(elapsed(at: context.date))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }

                LanguageChip(language: language, shortcut: shortcut, action: actions.cycleLanguage)

                Button(action: actions.stop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white))
                }
                .buttonStyle(.plain)
                .help("Finish and insert")
            }
            .padding(.horizontal, 10)
        }
    }

    private func elapsed(at date: Date) -> String {
        guard let start = dictation.recordingStartedAt else { return "0:00" }
        return TextTools.duration(date.timeIntervalSince(start).rounded(.down))
    }
}

private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2.5, height: 3 + CGFloat(level) * 22)
            }
        }
        .frame(height: 28)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

private struct ProcessingView: View {
    let label: String

    var body: some View {
        Pill {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 14)
        }
    }
}

private struct MessageView: View {
    let text: String
    let isError: Bool
    let onTap: () -> Void

    var body: some View {
        Pill {
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? Color.orange : Color.green)
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
        }
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
    }
}
