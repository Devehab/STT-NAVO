import AppKit
import AVFoundation
import SwiftUI

// MARK: Player

/// Plays one session's audio with a position slider.
@MainActor
final class SessionPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var loadedID: String?
    @Published private(set) var isPlaying = false
    @Published var position: TimeInterval = 0
    @Published private(set) var length: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ session: Session) {
        if loadedID == session.id, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                stopTimer()
            } else {
                player.play()
                isPlaying = true
                startTimer()
            }
            return
        }
        stop()
        guard let path = session.audioPath, let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return }
        player.delegate = self
        player.prepareToPlay()
        player.play()
        self.player = player
        loadedID = session.id
        length = player.duration
        position = 0
        isPlaying = true
        startTimer()
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(seconds, player.duration))
        position = player.currentTime
    }

    func stop() {
        player?.stop()
        player = nil
        loadedID = nil
        isPlaying = false
        position = 0
        length = 0
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                if let player = self.player {
                    self.position = player.currentTime
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.position = 0
            self.stopTimer()
        }
    }
}

// MARK: Options

/// Engine, language and piece length for long transcriptions, as compact menus
/// (Record and Files tabs share them).
struct TranscriptionOptions: View {
    /// The label for the piece length, or nil to leave it out.
    var pieceLabel: String? = "Text every"

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: LocalEngineManager

    var body: some View {
        HStack(spacing: 20) {
            OptionField("Engine") {
                // Engines that are on, and the others while there is room to turn one on.
                Picker("Engine", selection: Binding(
                    get: { settings.jobEngineInUse },
                    set: { settings.jobEngine = $0 }
                )) {
                    ForEach(SpeechEngine.allCases.filter { settings.canEnable($0) }) { speech in
                        Text(label(speech)).tag(speech)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help(engineHelp)
            }
            OptionField("Language") {
                Picker("Language", selection: Binding(
                    get: { settings.jobLanguage(for: settings.jobEngineInUse) },
                    set: { settings.jobLanguage = $0 }
                )) {
                    ForEach(settings.jobEngineInUse.languages) { language in
                        Text(language.name).tag(language)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help(languageHelp)
            }
            if let pieceLabel {
                OptionField(pieceLabel) {
                    PieceLengthPicker()
                }
            }
        }
    }

    private func label(_ speech: SpeechEngine) -> String {
        engine.isDownloaded(speech) ? speech.shortName : "\(speech.shortName) (not downloaded)"
    }

    private var engineHelp: String {
        settings.enabledEngines.count < AppSettings.maxEnabledEngines
            ? "Picking an engine that is off turns it on"
            : "\(settings.enabledEnginesText) are on. To use another engine, turn one of them off in Settings > Speech engines (\(AppSettings.maxEnabledEngines) at most)."
    }

    private var languageHelp: String {
        switch settings.jobEngineInUse {
        case .cohere:
            return "Arabic covers every dialect, with English mixed in."
        case .audar:
            return "Auto lets Audar detect the language. The Arabic dialect always comes from the audio."
        case .whisper, .qwen3:
            return "Auto lets \(settings.jobEngineInUse.shortName) detect the language. Arabic covers every dialect."
        }
    }
}

/// How long each transcribed piece of a long recording is: how often new text appears.
struct PieceLengthPicker: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Picker("Piece length", selection: $settings.pieceSeconds) {
            ForEach(AppSettings.pieceChoices, id: \.self) { seconds in
                Text(Self.title(seconds)).tag(seconds)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("Each piece ends in a pause, up to 10 seconds before or after this point, so no word is cut in two.")
    }

    static func title(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: return "\(seconds) seconds"
        case 60: return "1 minute"
        default: return "\(seconds / 60) minutes"
        }
    }
}

// MARK: List and detail

/// Sessions of one kind on the left, with search and a date filter, the selected one on the right.
struct SessionBrowser: View {
    let kind: SessionKind
    var emptyTitle = "Nothing here yet"
    var emptyHint = ""

    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var router: HubRouter
    @StateObject private var player = SessionPlayer()
    @StateObject private var filter = SessionFilter()
    @State private var selection: String?

    private var items: [Session] { sessions.sessions(of: kind) }

    var body: some View {
        let all = self.items
        let shown = filter.apply(to: all)
        return HStack(spacing: 0) {
            listColumn(all: all, shown: shown)
                .frame(width: all.isEmpty ? nil : 290)
                .frame(maxWidth: all.isEmpty ? .infinity : nil)
            if !all.isEmpty {
                Divider()
                detailColumn
            }
        }
        .browserCard()
        .onAppear {
            if !showFocused(), selection == nil || !items.contains(where: { $0.id == selection }) {
                selection = items.first?.id
            }
        }
        .onChange(of: router.focusedSession) { _, _ in
            _ = showFocused()
        }
        .onChange(of: all.first?.id) { old, newest in
            // Something new arrived (an import, a recording): show it, unless you are
            // following a transcription that is still running.
            guard let newest, newest != old else { return }
            if let current = selection, sessions.isTranscribing(current), !sessions.isWaiting(current) { return }
            selection = newest
        }
        .onChange(of: filter.query) { _, _ in
            filter.search(in: items)
        }
        .onChange(of: all) { _, changed in
            // New text arrived while a search is on: it may match now.
            if filter.hits != nil { filter.search(in: changed) }
        }
        .onChange(of: shown.map(\.id)) { _, ids in
            // The search or the dates changed what is listed: keep something listed selected.
            guard filter.isActive, let first = ids.first else { return }
            if selection == nil || !ids.contains(selection ?? "") { selection = first }
        }
        .onDisappear { player.stop() }
    }

    /// The list with its search and dates, or the hint that shows while there is nothing yet.
    @ViewBuilder
    private func listColumn(all: [Session], shown: [Session]) -> some View {
        if all.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: kind == .meeting ? "record.circle" : "waveform.badge.plus")
                    .font(.system(size: 30))
                    .foregroundStyle(navoBrandGradient)
                Text(emptyTitle)
                    .font(.headline)
                Text(emptyHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                filterBar(shown: shown.count, of: all.count)
                Divider()
                if shown.isEmpty {
                    noMatches
                } else {
                    List(shown, selection: $selection) { session in
                        SessionRow(session: session, snippet: filter.hits?[session.id])
                            .tag(session.id)
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        Group {
            if let id = selection, let session = sessions.session(id) {
                SessionDetail(session: session, player: player)
                    .id(session.id)
            } else {
                Text("Select one to play it and read its text.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noun: String { kind == .meeting ? "recordings" : "files" }

    /// Search by words in the title or the text, and narrow to a day or a stretch of days.
    private func filterBar(shown: Int, of total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchField("Search \(noun) and their text", text: $filter.query)
            HStack(spacing: 6) {
                DateFilterMenu(period: $filter.period)
                Spacer(minLength: 4)
                Text(filter.isActive ? "\(shown) of \(total)" : "\(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if filter.isActive {
                    Button {
                        filter.reset()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show all \(noun)")
                }
            }
        }
        .padding(10)
    }

    private var noMatches: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No \(noun) match")
                .font(.headline)
            Text(noMatchHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Show all") { filter.reset() }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    private var noMatchHint: String {
        let words = filter.query.trimmingCharacters(in: .whitespaces)
        switch (words.isEmpty, filter.period == .any) {
        case (false, false): return "Nothing with \"\(words)\" from \(filter.period.title.lowercased())."
        case (false, true): return "Nothing with \"\(words)\" in a title or a text."
        default: return "Nothing from \(filter.period.title.lowercased())."
        }
    }

    /// Selects the recording or file picked in the menu bar, if it is one of these.
    private func showFocused() -> Bool {
        guard let id = router.focusedSession, items.contains(where: { $0.id == id }) else { return false }
        filter.reset() // it may be outside the dates or the search
        selection = id
        router.focusedSession = nil
        return true
    }
}

private extension View {
    /// The rounded card the browser sits in.
    func browserCard() -> some View {
        frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// "Any date", a stretch of days, or one day picked from a calendar.
private struct DateFilterMenu: View {
    @Binding var period: SessionPeriod

    @State private var picking = false
    @State private var day = Date()

    var body: some View {
        Menu {
            ForEach(SessionPeriod.presets, id: \.self) { preset in
                Toggle(preset.title, isOn: Binding(
                    get: { period == preset },
                    set: { _ in period = preset }
                ))
            }
            Divider()
            Button("Pick a day…") {
                if case .day(let chosen) = period { day = chosen }
                picking = true
            }
        } label: {
            Label(period.title, systemImage: "calendar")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .tint(period == .any ? Color.secondary : Color.accentColor)
        .help("Show only the ones from these dates")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                HStack {
                    Button("Cancel") { picking = false }
                    Spacer()
                    Button("Show this day") {
                        period = .day(day)
                        picking = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 280)
        }
    }
}

struct SessionStatusChip: View {
    let session: Session

    @EnvironmentObject private var sessions: SessionStore

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var job: SessionStore.Progress? { sessions.jobs[session.id] }

    private var label: String {
        switch session.status {
        case .recording: return job?.live == true ? "Live" : "Recording"
        case .ready: return "Not transcribed"
        case .transcribing:
            guard let job else { return "Transcribing" }
            if job.waiting { return "Waiting" }
            if job.partsTotal > 0 { return "\(min(job.partsDone, job.partsTotal))/\(job.partsTotal)" }
            return "Transcribing"
        case .done: return "Done"
        case .partial: return "Partly done"
        case .failed: return "Failed"
        }
    }

    private var color: Color {
        switch session.status {
        case .recording: return .red
        case .ready: return .secondary
        case .transcribing: return job?.waiting == true ? .secondary : .orange
        case .done: return .green
        case .partial: return .orange
        case .failed: return .red
        }
    }
}

private struct SessionRow: View {
    let session: Session
    /// While searching: the line of its text the words were found in.
    var snippet: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, TextTools.isRightToLeft(snippet) ? .rightToLeft : .leftToRight)
            }
            HStack(spacing: 6) {
                Text(session.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text(SessionStore.clock(session.duration))
                    .monospacedDigit()
                Spacer(minLength: 4)
                SessionStatusChip(session: session)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

private struct SessionDetail: View {
    let session: Session
    @ObservedObject var player: SessionPlayer

    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ai: AIWriter
    @EnvironmentObject private var router: HubRouter
    @State private var title = ""
    @State private var writing = false
    @State private var showTimes = false
    @State private var copied = false
    @State private var confirmDelete = false

    private var running: Bool { sessions.isTranscribing(session.id) }
    private var waiting: Bool { sessions.isWaiting(session.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if session.status == .recording {
                Label("Recording now. Its text shows in the recording panel above.", systemImage: "record.circle")
                    .foregroundStyle(.red)
                Spacer()
            } else {
                if session.hasAudio {
                    playerBar
                }
                actionBar
                if let error = session.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(session.status == .failed ? Color.red : Color.orange)
                        .textSelection(.enabled)
                }
                textHeader
                // Not scrolled along: you may be reading the start while the rest arrives.
                TranscriptView(chunks: session.chunks, showTimes: showTimes, placeholder: placeholder)
            }
        }
        .padding(18)
        .onAppear { title = session.title }
        .confirmationDialog("Delete \"\(session.title)\"?", isPresented: $confirmDelete) {
            Button("Delete permanently", role: .destructive) {
                if player.loadedID == session.id { player.stop() }
                sessions.delete(session.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The audio and the text are erased from this Mac. This cannot be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold))
                    .onSubmit { sessions.rename(session.id, to: title) }
                Menu {
                    if let path = session.audioPath {
                        Button("Show audio in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    if !session.chunks.isEmpty {
                        Button("Export text…") { sessions.exportTranscript(session.id, withTimes: false) }
                        Button("Export text with times…") { sessions.exportTranscript(session.id, withTimes: true) }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                        .disabled(session.status == .recording)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            HStack(spacing: 8) {
                Text(meta)
                    .lineLimit(1)
                    .truncationMode(.middle)
                SessionStatusChip(session: session)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var meta: String {
        var parts = [
            session.createdAt.formatted(date: .abbreviated, time: .shortened),
            SessionStore.clock(session.duration),
        ]
        if session.kind == .meeting {
            parts.append(MeetingSource(rawValue: session.source)?.shortTitle ?? session.source)
        }
        return parts.joined(separator: ", ")
    }

    private var playerBar: some View {
        let active = player.loadedID == session.id
        return HStack(spacing: 10) {
            Button {
                player.toggle(session)
            } label: {
                Image(systemName: active && player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.bordered)
            Text(SessionStore.clock(active ? player.position : 0))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { active ? player.position : 0 },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(1, active ? player.length : session.duration)
            )
            .disabled(!active)
            Text(SessionStore.clock(active ? player.length : session.duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        if waiting {
            HStack(spacing: 10) {
                Image(systemName: "hourglass")
                    .foregroundStyle(.secondary)
                Text("Waiting: another file is being transcribed. This one starts right after it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { sessions.cancel(session.id) }
            }
        } else if running {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(progressLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { sessions.cancel(session.id) }
                }
                if let job = sessions.jobs[session.id], job.secondsTotal > 0 {
                    ProgressView(value: min(1, job.secondsDone / job.secondsTotal))
                        .controlSize(.small)
                }
            }
        } else if session.hasAudio {
            HStack(spacing: 10) {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if session.failedChunks > 0 || session.status == .partial {
                    Button("Continue") {
                        // The engine and language of the text already there.
                        let speech = session.engine.map { SpeechEngine.from(historyName: $0) } ?? settings.jobEngineInUse
                        sessions.transcribe(session.id, engine: speech, language: session.language, onlyMissing: true)
                    }
                    .help("Transcribe only the parts that are missing, with the engine and language the rest was done with")
                }
                TranscribeButton(session: session)
            }
        }
    }

    private var summary: String {
        guard !session.chunks.isEmpty, let engine = session.engine else { return "Not transcribed yet" }
        let name = SpeechEngine.from(historyName: engine).shortName
        let language = (DictationLanguage(rawValue: session.language) ?? .ar).name
        return "\(name), \(language), \(session.chunks.count) \(session.chunks.count == 1 ? "part" : "parts")"
    }

    private var progressLine: String {
        guard let job = sessions.jobs[session.id], job.partsTotal > 0 else { return "Getting the audio ready" }
        let engine = session.engine.map { SpeechEngine.from(historyName: $0).shortName } ?? ""
        return "\(engine) is on part \(min(job.partsDone + 1, job.partsTotal)) of about \(job.partsTotal), "
            + "\(SessionStore.clock(job.secondsDone)) of \(SessionStore.clock(job.secondsTotal))"
    }

    private var textHeader: some View {
        HStack {
            Text("Text")
                .font(.headline)
            Spacer()
            Toggle("Times", isOn: $showTimes)
                .toggleStyle(.checkbox)
                .disabled(session.chunks.isEmpty)
            Button {
                writing = true
            } label: {
                Label("AI", systemImage: "sparkles")
            }
            .help("Summarize the text, or rewrite it as an email, a text message or a clean rewrite, in English or Arabic")
            .disabled(session.transcript.isEmpty)
            .sheet(isPresented: $writing) {
                AIWriterSheet(source: AISource(title: session.title, text: session.transcript))
                    .environmentObject(ai)
                    .environmentObject(settings)
                    .environmentObject(router)
            }
            Button(copied ? "Copied" : "Copy") {
                TextInjector.copy(showTimes ? SessionStore.timedTranscript(session) : session.transcript)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copied = false
                }
            }
            .disabled(session.chunks.allSatisfy { ($0.text ?? "").isEmpty })
        }
    }

    private var placeholder: String {
        if waiting { return "The text appears here once this one's turn comes." }
        if running { return "The text appears here part by part." }
        return session.hasAudio ? "Click Transcribe to get the text." : ""
    }
}

/// Transcribe with the engine and language chosen above, or pick others from its menu.
private struct TranscribeButton: View {
    let session: Session

    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Menu {
            ForEach(SpeechEngine.allCases.filter { settings.canEnable($0) }) { speech in
                Section(speech.title) {
                    ForEach(speech.languages) { language in
                        Button(language.name) {
                            sessions.transcribe(session.id, engine: speech, language: language.rawValue)
                        }
                    }
                }
            }
        } label: {
            Text(session.chunks.isEmpty ? "Transcribe" : "Transcribe again")
        } primaryAction: {
            let speech = settings.jobEngineInUse
            sessions.transcribe(session.id, engine: speech, language: settings.jobLanguage(for: speech).rawValue)
        }
        .fixedSize()
        .help("Click: \(settings.jobEngineInUse.shortName), \(settings.jobLanguage(for: settings.jobEngineInUse).name). The arrow: another engine or language.")
    }
}
