import SwiftUI

/// Record tab: record a meeting (the Mac's sound, the microphone, or both) and read its text
/// while it goes on.
struct RecordView: View {
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var recorder: MeetingRecorder
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Record")
                    .font(.system(size: 28, weight: .semibold))
                Text("Meetings on Google Meet, Zoom or any app, turned into text while they go on.")
                    .foregroundStyle(.secondary)
            }

            if let error = sessions.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if recorder.phase == .idle {
                startCard
                SessionBrowser(
                    kind: .meeting,
                    emptyTitle: "No recordings yet",
                    emptyHint: "Pick what to record above and press Start. The text appears here while the meeting goes on."
                )
            } else {
                RecordingPanel()
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Picker("Record", selection: $settings.meetingSource) {
                    ForEach(MeetingSource.allCases) { source in
                        Text(source.shortTitle).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Mac audio is everything your Mac plays, so the other people in a call.")
                Spacer()
                Button {
                    sessions.startRecording(source: settings.meetingSource)
                } label: {
                    Label("Start recording", systemImage: "record.circle.fill")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
            // One row when the window is wide enough, two when it is not.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    textMode
                    TranscriptionOptions(pieceLabel: pieceLabel)
                    Spacer(minLength: 0)
                    moreMenu
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 20) {
                        TranscriptionOptions(pieceLabel: nil)
                        Spacer(minLength: 0)
                        moreMenu
                    }
                    HStack(spacing: 20) {
                        textMode
                        if let pieceLabel {
                            OptionField(pieceLabel) { PieceLengthPicker() }
                        }
                    }
                }
            }
            if settings.meetingSource != .mic {
                Text("The first time, macOS asks to allow Navo under System Audio Recording. In calls, use headphones so the microphone does not hear the speakers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }

    private var pieceLabel: String? {
        settings.meetingTranscription == .live ? "every" : nil
    }

    private var textMode: some View {
        OptionField("Text") {
            Picker("Text", selection: $settings.meetingTranscription) {
                ForEach(MeetingTranscription.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var moreMenu: some View {
        Menu {
            Picker("Save the audio to disk every", selection: $settings.meetingPartMinutes) {
                Text("3 minutes").tag(3)
                Text("5 minutes").tag(5)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More options")
    }
}

/// What shows while recording: the controls, the levels, and the text as it arrives.
private struct RecordingPanel: View {
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var recorder: MeetingRecorder

    private var session: Session? { recorder.sessionID.flatMap { sessions.session($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Circle()
                    .fill(recorder.phase == .recording ? Color.red : Color.orange)
                    .frame(width: 12, height: 12)
                Text(stateLabel)
                    .font(.headline)
                Text(SessionStore.clock(recorder.elapsed))
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                Spacer()
                switch recorder.phase {
                case .recording:
                    Button {
                        recorder.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .controlSize(.large)
                case .paused:
                    Button {
                        recorder.resume()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .controlSize(.large)
                default:
                    EmptyView()
                }
                Button {
                    recorder.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(recorder.phase == .finishing)
            }

            HStack(spacing: 22) {
                if recorder.source.tracks.contains(.mic) {
                    LevelMeter(title: "Microphone", level: recorder.micLevel)
                }
                if recorder.source.tracks.contains(.system) {
                    LevelMeter(title: "Mac audio", level: recorder.systemLevel)
                }
                Spacer()
            }

            if recorder.source.tracks.contains(.system) && recorder.systemSilentSeconds >= 15 {
                Text("No sound from the Mac yet. If the meeting is playing, allow Navo in System Settings > Privacy & Security > Screen & System Audio Recording, under System Audio Recording Only, then stop and start again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = recorder.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Divider()

            if let session, recorder.isLive || !session.chunks.isEmpty {
                HStack {
                    Text(liveLabel(session))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if recorder.isLive {
                        Button("Stop live text") { sessions.cancel(session.id) }
                            .help("The recording goes on. Continue transcribes the rest after it stops.")
                    }
                }
                TranscriptView(
                    chunks: session.chunks,
                    showTimes: true,
                    following: true,
                    placeholder: "The first text appears after the first minute or so, cut at a pause.",
                    footer: recorder.isLive && !session.chunks.isEmpty ? "The next part is on its way." : nil
                )
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "waveform")
                        .font(.system(size: 28))
                        .foregroundStyle(navoBrandGradient)
                    Text("Recording. The text comes when you stop.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }

    private var stateLabel: String {
        switch recorder.phase {
        case .recording: return "Recording \(recorder.source.shortTitle)"
        case .paused: return "Paused"
        case .finishing: return "Saving"
        case .idle: return ""
        }
    }

    private func liveLabel(_ session: Session) -> String {
        guard recorder.isLive else { return "Live text stopped. Continue transcribes the rest after you stop." }
        let engine = session.engine.map { SpeechEngine.from(historyName: $0).shortName } ?? ""
        let language = (DictationLanguage(rawValue: session.language) ?? .ar).name
        let every = PieceLengthPicker.title(Int(recorder.livePieceSeconds))
        return "Live text with \(engine), \(language), a new part about every \(every)."
    }
}

private struct LevelMeter: View {
    let title: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(navoBrandGradient)
                        .frame(width: max(4, geometry.size.width * CGFloat(level)))
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(width: 140, height: 6)
        }
    }
}
