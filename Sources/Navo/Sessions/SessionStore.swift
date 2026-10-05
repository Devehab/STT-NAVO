import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Meeting recordings and imported audio files, and their long-form transcription.
@MainActor
final class SessionStore: ObservableObject {
    struct Progress: Equatable {
        var partsDone = 0
        var partsTotal = 0
        var secondsDone: TimeInterval = 0
        var secondsTotal: TimeInterval = 0
        /// Transcribing a meeting while it is being recorded.
        var live = false
        /// In line behind another transcription (one runs at a time, so each finishes sooner).
        var waiting = false

        /// How much is done, from 0 to 1. Nil while the length is not known yet.
        var fraction: Double? {
            if secondsTotal > 0 { return min(1, max(0, secondsDone / secondsTotal)) }
            if partsTotal > 0 { return min(1, Double(partsDone) / Double(partsTotal)) }
            return nil
        }
    }

    /// A transcription waiting for the one before it.
    private struct QueuedJob {
        let id: String
        let engine: SpeechEngine
        let language: String
        let onlyMissing: Bool
        let previousStatus: SessionStatus
        let previousError: String?
    }

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var jobs: [String: Progress] = [:]
    @Published private(set) var lastError: String?
    /// Files being copied in right now.
    @Published private(set) var importing = 0
    /// Called with the saved session when a transcription ends by itself (done or failed), not
    /// when it is stopped by hand.
    var onTranscriptionEnded: ((Session) -> Void)?
    /// Inbox files handed to an import that has not finished, so a second look does not take them again.
    private var inboxPending: Set<URL> = []

    let recorder = MeetingRecorder()

    private let db: Database?
    private let engine: LocalEngineManager
    private let settings: AppSettings
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Live transcriptions: the recorder hands pieces in here while the meeting records.
    private var liveFeeds: [String: AsyncStream<LivePiece>.Continuation] = [:]
    /// The file or recording being transcribed now. Live meeting text runs beside it.
    private var activeJob: String?
    private var queue: [QueuedJob] = []

    init(db: Database?, engine: LocalEngineManager, settings: AppSettings) {
        self.db = db
        self.engine = engine
        self.settings = settings
        recorder.onFinished = { [weak self] finished in
            self?.recordingFinished(finished)
        }
        reload()
        recoverInterruptedRecordings()
        recoverInterruptedTranscriptions()
    }

    func sessions(of kind: SessionKind) -> [Session] {
        sessions.filter { $0.kind == kind }
    }

    func session(_ id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    func reload() {
        guard let db else { return }
        do {
            sessions = try db.sessions()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func save(_ session: Session) {
        do {
            try db?.saveSession(session)
        } catch {
            lastError = error.localizedDescription
        }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }

    // MARK: Meetings

    func startRecording(source: MeetingSource) {
        guard !recorder.isActive else { return }
        if source.tracks.contains(.mic) {
            switch MicrophonePermission.status {
            case .authorized:
                break
            case .notDetermined:
                // Ask once, then start right away when allowed.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if await MicrophonePermission.request() {
                        self.startRecording(source: source)
                    } else {
                        self.lastError = "Microphone access was denied. Allow Navo in System Settings > Privacy & Security > Microphone, or record Mac audio only."
                    }
                }
                return
            default:
                lastError = "Allow microphone access for Navo in System Settings > Privacy & Security > Microphone, or record Mac audio only."
                return
            }
        }
        let id = UUID().uuidString
        let now = Date()
        let speech = settings.jobEngineInUse
        let language = settings.jobLanguage(for: speech).rawValue
        let live = settings.meetingTranscription == .live
        let (stream, feed) = AsyncStream<LivePiece>.makeStream()
        var onPiece: (@Sendable (LivePiece) -> Void)?
        if live {
            onPiece = { piece in feed.yield(piece) }
        }
        do {
            try recorder.start(
                sessionID: id,
                source: source,
                partMinutes: settings.meetingPartMinutes,
                livePieceSeconds: live ? Double(settings.pieceSeconds) : nil,
                onPiece: onPiece
            )
        } catch {
            feed.finish()
            lastError = error.localizedDescription
            return
        }
        lastError = nil
        save(Session(
            id: id,
            kind: .meeting,
            title: "Meeting, " + now.formatted(date: .abbreviated, time: .shortened),
            createdAt: now,
            duration: 0,
            source: source.rawValue,
            audioPath: nil,
            status: .recording,
            engine: live ? speech.historyName : nil,
            language: language,
            chunks: [],
            error: nil
        ))
        if live {
            startLive(id, stream: stream, feed: feed, engine: speech, language: language)
        } else {
            feed.finish()
        }
    }

    /// Transcribes the pieces the recorder hands out, one at a time, in order, while it records.
    private func startLive(
        _ id: String,
        stream: AsyncStream<LivePiece>,
        feed: AsyncStream<LivePiece>.Continuation,
        engine speech: SpeechEngine,
        language: String
    ) {
        if !settings.isEnabled(speech) {
            engine.setEnabled(speech, true)
        }
        // Loads the model now, so the first piece does not wait for it.
        engine.wake(speech)
        liveFeeds[id] = feed
        jobs[id] = Progress(live: true)
        let baseURL = engine.baseURL(for: speech)
        let store = self
        tasks[id] = Task.detached(priority: .userInitiated) {
            let client = TranscriptionClient(baseURL: baseURL)
            for await piece in stream {
                if Task.isCancelled { break }
                var chunk = SessionChunk(index: piece.index, start: piece.start, end: piece.end, text: nil, error: piece.problem)
                if piece.silent {
                    chunk.text = ""
                } else if let url = piece.url {
                    let result = await SessionStore.send(url, client: client, language: language)
                    if Task.isCancelled { break }
                    chunk.text = result.text
                    chunk.error = result.error
                }
                if let url = piece.url {
                    try? FileManager.default.removeItem(at: url)
                }
                await MainActor.run { [chunk] in
                    store.liveChunkFinished(id, chunk: chunk)
                }
            }
            let cancelled = Task.isCancelled
            try? FileManager.default.removeItem(at: SessionStore.liveFolder(id))
            await MainActor.run {
                store.jobFinished(id, outcome: cancelled ? .cancelled : .finished)
            }
        }
    }

    /// Where the recorder leaves live pieces until they are sent (never creates the session folder).
    nonisolated static func liveFolder(_ id: String) -> URL {
        Paths.sessionsDir
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("live", isDirectory: true)
    }

    private func liveChunkFinished(_ id: String, chunk: SessionChunk) {
        guard var current = session(id) else { return }
        current.chunks.removeAll { $0.index == chunk.index }
        current.chunks.append(chunk)
        current.chunks.sort { $0.index < $1.index }
        save(current)
        var progress = jobs[id] ?? Progress(live: true)
        progress.partsDone = current.chunks.count
        progress.secondsDone = max(progress.secondsDone, chunk.end)
        if !progress.live {
            progress.partsTotal = max(progress.partsTotal, progress.partsDone)
        }
        jobs[id] = progress
    }

    private func recordingFinished(_ finished: MeetingRecorder.Finished) {
        let id = finished.sessionID
        // Every piece is in the stream now: the live job finishes once it has sent them, then
        // removes their files. Finished first, so the job can never wait forever.
        let feed = liveFeeds.removeValue(forKey: id)
        feed?.finish()
        guard var session = session(id) else { return }
        session.duration = finished.duration
        session.audioPath = finished.audioURL?.path
        session.error = finished.error
        if feed != nil {
            session.status = .transcribing
            var progress = jobs[id] ?? Progress()
            progress.live = false
            progress.secondsTotal = finished.duration
            progress.partsTotal = max(progress.partsDone + 1, progress.partsTotal)
            jobs[id] = progress
            save(session)
        } else if !session.chunks.isEmpty {
            // Live text was stopped during the recording.
            try? FileManager.default.removeItem(at: Self.liveFolder(id))
            session.status = session.audioPath == nil ? .failed : .partial
            session.error = finished.error ?? "Live text was stopped. Use Continue to transcribe the rest."
            save(session)
        } else {
            try? FileManager.default.removeItem(at: Self.liveFolder(id))
            session.status = finished.audioURL == nil ? .failed : .ready
            save(session)
            if session.status == .ready && settings.meetingTranscription != .manual {
                let speech = settings.jobEngineInUse
                let language = settings.jobLanguage(for: speech).rawValue
                if let stopping = tasks[id] {
                    // Live text stopped a moment ago and its job is still winding down.
                    Task { @MainActor [weak self] in
                        await stopping.value
                        self?.transcribe(id, engine: speech, language: language)
                    }
                } else {
                    transcribe(id, engine: speech, language: language)
                }
            }
        }
    }

    /// Recordings that were still running when Navo quit or crashed: join their parts now.
    private func recoverInterruptedRecordings() {
        for session in sessions where session.status == .recording {
            let id = session.id
            let directory = Paths.sessionDir(id)
            try? FileManager.default.removeItem(at: Self.liveFolder(id))
            Task.detached(priority: .utility) { [weak self] in
                let finished = MeetingRecorder.combine(sessionID: id, directory: directory)
                guard let self else { return }
                await MainActor.run {
                    guard var session = self.session(id) else { return }
                    session.duration = finished.duration
                    session.audioPath = finished.audioURL?.path
                    let hasText = session.chunks.contains { $0.text != nil }
                    session.status = finished.audioURL == nil ? .failed : (hasText ? .partial : .ready)
                    session.error = finished.error ?? (hasText
                        ? "Recovered: Navo closed while this was recording. Use Continue to transcribe the rest."
                        : "Recovered: Navo closed while this was recording. Everything saved until then is here.")
                    self.save(session)
                }
            }
        }
    }

    /// Transcriptions that were running when Navo quit: keep the parts that finished.
    private func recoverInterruptedTranscriptions() {
        for var session in sessions where session.status == .transcribing {
            try? FileManager.default.removeItem(at: Self.liveFolder(session.id))
            let done = session.chunks.contains { $0.text != nil }
            session.status = done ? .partial : .ready
            session.error = done ? "Navo closed during the transcription. Use Continue to transcribe the rest." : nil
            save(session)
        }
    }

    // MARK: Imports

    /// Formats macOS cannot open but the engine can (WhatsApp voice notes and other OGG files).
    /// They are sent to the engine whole instead of in parts.
    nonisolated static let engineOnlyExtensions: Set<String> = ["ogg", "oga", "opus"]

    /// Copies audio files into Navo and adds them to Files, off the main thread so a large file
    /// never freezes the window. Files in `owned` were written by Navo itself (from the Share menu
    /// or a paste): they are moved instead, and removed if they are not audio.
    func importFiles(_ urls: [URL], owned: Set<URL> = []) {
        guard !urls.isEmpty else { return }
        importing += 1
        let language = settings.jobLanguage(for: settings.jobEngineInUse).rawValue
        Task.detached(priority: .userInitiated) { [weak self] in
            let (added, problems) = SessionStore.copyIn(urls, owned: owned, language: language)
            await self?.imported(added, problems: problems, from: urls)
        }
    }

    private func imported(_ added: [Session], problems: [String], from urls: [URL]) {
        importing -= 1
        inboxPending.subtract(urls)
        for session in added {
            save(session)
        }
        lastError = problems.isEmpty ? nil : problems.joined(separator: "\n")
        if settings.autoTranscribeImports {
            let speech = settings.jobEngineInUse
            for session in added {
                transcribe(session.id, engine: speech, language: settings.jobLanguage(for: speech).rawValue)
            }
        }
    }

    nonisolated private static func copyIn(_ urls: [URL], owned: Set<URL>, language: String) -> ([Session], [String]) {
        let fm = FileManager.default
        var added: [Session] = []
        var problems: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let isOwned = owned.contains(url)
            guard fm.fileExists(atPath: url.path) else { continue } // taken already
            let engineOnly = engineOnlyExtensions.contains(url.pathExtension.lowercased())
            guard let duration = AudioStream.duration(of: url) ?? (engineOnly ? 0 : nil) else {
                problems.append("\(url.lastPathComponent): macOS can't read this as audio. Convert it to M4A, MP3 or WAV first.")
                if isOwned { try? fm.removeItem(at: url) }
                continue
            }
            let id = UUID().uuidString
            let destination = Paths.sessionDir(id).appendingPathComponent(url.lastPathComponent)
            do {
                if isOwned {
                    try fm.moveItem(at: url, to: destination)
                } else {
                    try fm.copyItem(at: url, to: destination)
                }
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
                try? fm.removeItem(at: Paths.sessionsDir.appendingPathComponent(id, isDirectory: true))
                if isOwned { try? fm.removeItem(at: url) }
                continue
            }
            added.append(Session(
                id: id,
                kind: .file,
                title: url.deletingPathExtension().lastPathComponent,
                createdAt: Date(),
                duration: duration,
                source: url.lastPathComponent,
                audioPath: destination.path,
                status: .ready,
                engine: nil,
                language: language,
                chunks: [],
                error: nil
            ))
        }
        // The private folders pasted or dropped audio was received in are empty now.
        for folder in Set(owned.map { $0.deletingLastPathComponent() }) where folder.lastPathComponent.hasPrefix("navo-incoming-") {
            try? fm.removeItem(at: folder)
        }
        return (added, problems)
    }

    /// Audio waiting in the inbox (sent from the Share menu of Voice Memos and other apps).
    /// Returns whether there was any. Whatever is not audio is removed from the inbox too.
    @discardableResult
    func importInbox() -> Bool {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: Paths.inboxDir.path)) ?? []
        let files = names
            .filter { !$0.hasPrefix(".") }
            .map { Paths.inboxDir.appendingPathComponent($0) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            }
            .filter { !inboxPending.contains($0) }
        if !files.isEmpty {
            inboxPending.formUnion(files)
            importFiles(files, owned: Set(files))
        }
        return !files.isEmpty || !inboxPending.isEmpty
    }

    // MARK: Editing

    func rename(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var session = session(id), !trimmed.isEmpty, trimmed != session.title else { return }
        session.title = trimmed
        save(session)
    }

    /// Deletes the session, its transcript and its audio, permanently.
    func delete(_ id: String) {
        if recorder.sessionID == id { return }
        cancel(id)
        do {
            try db?.deleteSession(id: id)
        } catch {
            lastError = error.localizedDescription
            return
        }
        sessions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Paths.sessionsDir.appendingPathComponent(id, isDirectory: true))
        try? db?.compact()
    }

    // MARK: Transcription

    /// Running or waiting in line.
    func isTranscribing(_ id: String) -> Bool {
        tasks[id] != nil || queue.contains { $0.id == id }
    }

    func isWaiting(_ id: String) -> Bool {
        queue.contains { $0.id == id }
    }

    /// Transcriptions in the order they run: the ones running now, then the line.
    var jobsInOrder: [(id: String, progress: Progress)] {
        let waiting = queue.map(\.id)
        let running = jobs.keys
            .filter { !waiting.contains($0) }
            .sorted { a, b in
                let liveA = jobs[a]?.live == true
                let liveB = jobs[b]?.live == true
                return liveA == liveB ? a < b : !liveA
            }
        return (running + waiting).compactMap { id in jobs[id].map { (id, $0) } }
    }

    /// Stops a transcription, or takes it out of the line. For a meeting still recording, only
    /// the live text stops.
    func cancel(_ id: String) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            let job = queue.remove(at: index)
            jobs[id] = nil
            if var session = session(id) {
                session.status = job.previousStatus
                session.error = job.previousError
                save(session)
            }
            return
        }
        if let feed = liveFeeds.removeValue(forKey: id) {
            recorder.stopLive()
            feed.finish()
        }
        tasks[id]?.cancel()
    }

    /// Why `speech` can't transcribe now: it is off and two other engines are on.
    private func engineProblem(_ speech: SpeechEngine) -> String? {
        guard !settings.canEnable(speech) else { return nil }
        return "\(speech.shortName) is off, and \(settings.enabledEnginesText) are on: only \(AppSettings.maxEnabledEngines) engines can be on at once. "
            + "Turn one of them off in Settings > Speech engines, or transcribe with one of them."
    }

    /// Transcribes the whole recording with `engine`, piece by piece, now or after the
    /// transcription that is already running. With `onlyMissing` (and the same engine and
    /// language as before), keeps the text there is: the pieces that failed are redone by their
    /// time range, then the rest of the audio after the last piece.
    func transcribe(_ id: String, engine speech: SpeechEngine, language: String, onlyMissing: Bool = false) {
        guard !isTranscribing(id), var session = session(id), session.status != .recording,
              let path = session.audioPath, FileManager.default.fileExists(atPath: path)
        else { return }
        if let problem = engineProblem(speech) {
            session.error = problem
            save(session)
            return
        }
        if let running = activeJob, running != id {
            queue.append(QueuedJob(
                id: id,
                engine: speech,
                language: language,
                onlyMissing: onlyMissing,
                previousStatus: session.status,
                previousError: session.error
            ))
            session.status = .transcribing
            session.error = nil
            save(session)
            jobs[id] = Progress(waiting: true)
            return
        }
        start(&session, path: path, engine: speech, language: language, onlyMissing: onlyMissing)
    }

    private func startNextInLine() {
        while activeJob == nil, !queue.isEmpty {
            let job = queue.removeFirst()
            jobs[job.id] = nil
            guard var session = session(job.id) else { continue }
            guard let path = session.audioPath, FileManager.default.fileExists(atPath: path) else {
                session.status = job.previousStatus
                session.error = job.previousError
                save(session)
                continue
            }
            session.status = job.previousStatus // start() sets it again
            start(&session, path: path, engine: job.engine, language: job.language, onlyMissing: job.onlyMissing)
        }
    }

    private func start(_ session: inout Session, path: String, engine speech: SpeechEngine, language: String, onlyMissing: Bool) {
        if let problem = engineProblem(speech) {
            // Two other engines were turned on while this one waited in line.
            session.error = problem
            save(session)
            return
        }
        let id = session.id
        activeJob = id

        let keep = onlyMissing && session.engine == speech.historyName && session.language == language
        let retry = keep ? session.chunks.filter { $0.text == nil } : []
        let resumeAt = keep ? (session.chunks.map(\.end).max() ?? 0) : 0
        let firstIndex = keep ? ((session.chunks.map(\.index).max() ?? -1) + 1) : 0
        session.status = .transcribing
        session.engine = speech.historyName
        session.language = language
        session.error = nil
        if !keep {
            session.chunks = []
        }
        save(session)

        // The engine the user picked must be on; turning it on here does not load it yet.
        if !settings.isEnabled(speech) {
            engine.setEnabled(speech, true)
        }
        let baseURL = engine.baseURL(for: speech)
        let url = URL(fileURLWithPath: path)
        let pieceSeconds = Double(settings.pieceSeconds)
        let remaining = max(0, session.duration - resumeAt)
        // Done so far: the audio before resumeAt, except the pieces that are redone now.
        let redone = retry.reduce(0) { $0 + max(0, $1.end - $1.start) }
        jobs[id] = Progress(
            partsTotal: retry.count + max(1, Int((remaining / pieceSeconds).rounded(.up))),
            secondsDone: max(0, resumeAt - redone),
            secondsTotal: session.duration
        )

        // The store lives as long as the app, so the job can hold it.
        let store = self
        tasks[id] = Task.detached(priority: .userInitiated) {
            let outcome = await SessionStore.run(
                url: url,
                baseURL: baseURL,
                language: language,
                pieceSeconds: pieceSeconds,
                retry: retry,
                resumeAt: resumeAt,
                firstIndex: firstIndex
            ) { chunk in
                await MainActor.run {
                    store.partFinished(id, chunk: chunk)
                }
            }
            await MainActor.run {
                store.jobFinished(id, outcome: outcome)
            }
        }
    }

    private func partFinished(_ id: String, chunk: SessionChunk) {
        guard var current = session(id) else { return }
        if current.duration <= 0 {
            current.duration = chunk.end // an OGG file: its length is known once the engine has read it
        }
        current.chunks.removeAll { $0.index == chunk.index }
        current.chunks.append(chunk)
        current.chunks.sort { $0.index < $1.index }
        save(current)
        if var progress = jobs[id] {
            progress.partsDone += 1
            progress.partsTotal = max(progress.partsTotal, progress.partsDone)
            // Each piece adds its own length, so redone pieces early in the audio count too.
            progress.secondsDone = min(progress.secondsDone + max(0, chunk.end - chunk.start), current.duration)
            progress.secondsTotal = current.duration
            jobs[id] = progress
        }
    }

    private func jobFinished(_ id: String, outcome: Outcome) {
        tasks[id] = nil
        jobs[id] = nil
        let wasActive = activeJob == id
        if wasActive {
            activeJob = nil
        }
        // The next one in line starts once this one's status is saved.
        defer {
            if wasActive { startNextInLine() }
        }
        guard var current = session(id) else { return }
        // Live text stopped while the meeting still records: the recording decides the status later.
        guard current.status != .recording else { return }
        let hasText = current.chunks.contains { $0.text != nil }
        switch outcome {
        case .finished where current.audioPath == nil:
            // A live transcript of a recording whose audio could not be saved: keep both.
            current.status = hasText ? .partial : .failed
        case .finished:
            let failed = current.failedChunks
            current.status = failed == 0 ? .done : (hasText ? .partial : .failed)
            current.error = failed == 0 ? nil : "\(failed) of \(current.chunks.count) parts could not be transcribed. Use Continue to try them again."
        case .cancelled:
            current.status = current.chunks.isEmpty ? .ready : .partial
            current.error = current.chunks.isEmpty ? nil : "Stopped. Use Continue to transcribe the rest."
        case .failed(let message):
            current.status = hasText ? .partial : .failed
            current.error = message
        }
        save(current)
        if case .cancelled = outcome { return }
        onTranscriptionEnded?(current)
    }

    enum Outcome {
        case finished
        case cancelled
        case failed(String)
    }

    /// Redoes the pieces in `retry`, then cuts the audio after `resumeAt` into pieces and sends
    /// each to the engine, reporting every piece as it completes.
    nonisolated private static func run(
        url: URL,
        baseURL: URL,
        language: String,
        pieceSeconds: Double,
        retry: [SessionChunk],
        resumeAt: TimeInterval,
        firstIndex: Int,
        report: @escaping (SessionChunk) async -> Void
    ) async -> Outcome {
        guard AudioStream.duration(of: url) != nil else {
            guard engineOnlyExtensions.contains(url.pathExtension.lowercased()) else {
                return .failed("Navo can't read this audio file.")
            }
            return await runWhole(url: url, baseURL: baseURL, language: language, report: report)
        }
        let client = TranscriptionClient(baseURL: baseURL)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("navo-part-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: scratch) }

        // 1. The pieces that failed before, by their time range.
        for old in retry.sorted(by: { $0.index < $1.index }) {
            if Task.isCancelled { return .cancelled }
            let samples: [Float]
            do {
                samples = try AudioStream.samples(of: url, from: old.start, to: old.end)
            } catch {
                return .failed(error.localizedDescription)
            }
            guard let chunk = await transcribePiece(samples, index: old.index, start: old.start, client: client, language: language, scratch: scratch) else {
                return .cancelled
            }
            await report(chunk)
        }

        // 2. Everything after the last piece so far.
        let chunker: AudioChunker
        do {
            chunker = try AudioChunker(url: url, pieceSeconds: pieceSeconds, startAt: resumeAt, firstIndex: firstIndex)
        } catch {
            return .failed(error.localizedDescription)
        }
        var sawAudio = resumeAt > 0
        while true {
            if Task.isCancelled { return .cancelled }
            let next: AudioChunker.Chunk?
            do {
                next = try chunker.next()
            } catch {
                return .failed(error.localizedDescription)
            }
            guard let piece = next else { break }
            sawAudio = true
            guard let chunk = await transcribePiece(piece.samples, index: piece.index, start: piece.start, client: client, language: language, scratch: scratch) else {
                return .cancelled
            }
            await report(chunk)
        }
        return sawAudio ? .finished : .failed("The file contains no audio.")
    }

    /// One piece: skipped when it cannot hold speech, otherwise sent (with one retry).
    /// Nil when the job was cancelled meanwhile.
    nonisolated private static func transcribePiece(
        _ samples: [Float],
        index: Int,
        start: TimeInterval,
        client: TranscriptionClient,
        language: String,
        scratch: URL
    ) async -> SessionChunk? {
        let end = start + Double(samples.count) / Double(SpeechAudio.sampleRate)
        var chunk = SessionChunk(index: index, start: start, end: end, text: nil, error: nil)
        // Recognizers invent text for silence, so silent pieces are not sent.
        if samples.count < SpeechAudio.sampleRate / 2 || SmartCut.isSilent(samples) {
            chunk.text = ""
            return chunk
        }
        do {
            try WAVWriter.write(samples: samples, sampleRate: SpeechAudio.sampleRate, to: scratch)
        } catch {
            chunk.error = error.localizedDescription
            return chunk
        }
        let result = await send(scratch, client: client, language: language)
        if Task.isCancelled { return nil }
        chunk.text = result.text
        chunk.error = result.error
        return chunk
    }

    /// Sends one audio file; one retry covers a model that is still waking up or a worker that restarted.
    nonisolated private static func send(_ file: URL, client: TranscriptionClient, language: String) async -> (text: String?, error: String?) {
        var failure: String?
        for attempt in 0..<2 {
            if Task.isCancelled { break }
            do {
                let result = try await client.transcribe(fileURL: file, language: language)
                return (result.text, nil)
            } catch {
                failure = error.localizedDescription
                if attempt == 0 && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
        return (nil, failure ?? "Cancelled")
    }

    /// A file macOS cannot decode: the engine reads it and splits it itself, in one request.
    nonisolated private static func runWhole(
        url: URL,
        baseURL: URL,
        language: String,
        report: @escaping (SessionChunk) async -> Void
    ) async -> Outcome {
        var chunk = SessionChunk(index: 0, start: 0, end: 0, text: nil, error: nil)
        for attempt in 0..<2 {
            if Task.isCancelled { return .cancelled }
            do {
                let result = try await TranscriptionClient(baseURL: baseURL).transcribe(fileURL: url, language: language)
                chunk.text = result.text
                chunk.end = result.duration ?? 0
                chunk.error = nil
                break
            } catch {
                if Task.isCancelled { return .cancelled }
                chunk.error = error.localizedDescription
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
        await report(chunk)
        return .finished
    }

    // MARK: Export

    /// The transcript with a time before each part, for reading along with the audio.
    static func timedTranscript(_ session: Session) -> String {
        session.chunks.compactMap { chunk -> String? in
            if let text = chunk.text {
                return text.isEmpty ? nil : "[\(clock(chunk.start))]\n\(text)"
            }
            return "[\(clock(chunk.start))]\n(not transcribed: \(chunk.error ?? "unknown error"))"
        }.joined(separator: "\n\n")
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    func exportTranscript(_ id: String, withTimes: Bool) {
        guard let session = session(id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.title + ".txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = withTimes ? Self.timedTranscript(session) : session.transcript
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Navo is quitting: close any recording so its parts are complete for recovery.
    func prepareForQuit() {
        for feed in liveFeeds.values {
            feed.finish()
        }
        liveFeeds.removeAll()
        queue.removeAll() // they show as not transcribed (or partly) at the next launch
        recorder.closeForQuit()
        for task in tasks.values {
            task.cancel()
        }
    }
}
