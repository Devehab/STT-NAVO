import AppKit
import Combine

/// Long transcriptions in the menu bar: the icon fills up as the one running goes along and turns
/// into a check mark when everything is done, so you can tell from across the room. The menu
/// lists each transcription; clicking one opens it.
@MainActor
final class MenuBarActivity {
    /// What the menu bar icon shows.
    enum Look: Equatable {
        case idle
        /// A meeting is being recorded.
        case recording(paused: Bool, clock: String)
        /// Nil percent while the length is not known yet.
        case working(percent: Int?)
        /// Done since the menu was last opened; not ok when something could not be transcribed.
        case finished(ok: Bool)
    }

    /// One line of the menu.
    struct Entry {
        let sessionID: String
        let title: String
        let detail: String
        let image: NSImage?
    }

    private struct Finished {
        let sessionID: String
        let ok: Bool
        let detail: String
    }

    private(set) var look: Look = .idle
    /// Called when what the menu bar shows may have changed.
    var onChange: (() -> Void)?

    private let sessions: SessionStore
    private var finished: [Finished] = []
    private var cancellables = Set<AnyCancellable>()
    private var refreshQueued = false

    init(sessions: SessionStore) {
        self.sessions = sessions
        let recorder = sessions.recorder
        Publishers.Merge4(
            sessions.$jobs.map { _ in () },
            sessions.$sessions.map { _ in () },
            recorder.$phase.map { _ in () },
            recorder.$elapsed.map { _ in () }
        )
        .sink { [weak self] in self?.setNeedsRefresh() }
        .store(in: &cancellables)
        sessions.onTranscriptionEnded = { [weak self] session in
            self?.ended(session)
        }
        look = currentLook()
    }

    /// The menu was open, so what finished has been seen: the icon goes back to normal.
    func acknowledge() {
        guard !finished.isEmpty else { return }
        finished.removeAll()
        refresh()
    }

    /// Running and waiting transcriptions, then the ones that finished since the menu was last opened.
    var entries: [Entry] {
        var list: [Entry] = []
        for (id, progress) in sessions.jobsInOrder {
            guard let session = sessions.session(id) else { continue }
            list.append(Entry(
                sessionID: id,
                title: Self.short(session.title),
                detail: Self.detail(progress),
                image: Self.image(progress)
            ))
        }
        for done in finished where !list.contains(where: { $0.sessionID == done.sessionID }) {
            // Deleted since: nothing to show. Renamed since: the new name.
            guard let session = sessions.session(done.sessionID) else { continue }
            list.append(Entry(
                sessionID: done.sessionID,
                title: Self.short(session.title),
                detail: done.detail,
                image: done.ok ? MenuBarImages.done(pointSize: 14) : MenuBarImages.problem(pointSize: 14)
            ))
        }
        return list
    }

    // MARK: Following the store

    private func ended(_ session: Session) {
        let ok = session.status == .done
        let detail: String
        switch session.status {
        case .done:
            detail = session.duration > 0 ? "Done: \(SessionStore.clock(session.duration)) of audio transcribed" : "Done"
        case .partial:
            detail = session.error ?? "Partly transcribed"
        default:
            detail = session.error ?? "Could not be transcribed"
        }
        finished.removeAll { $0.sessionID == session.id }
        finished.insert(Finished(sessionID: session.id, ok: ok, detail: detail), at: 0)
        if finished.count > 5 {
            finished.removeLast(finished.count - 5)
        }
        setNeedsRefresh()
    }

    /// Several changes in a row (a piece saved, then its progress) are shown once, after the
    /// store has finished changing.
    private func setNeedsRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    private func refresh() {
        look = currentLook()
        onChange?()
    }

    private func currentLook() -> Look {
        let recorder = sessions.recorder
        switch recorder.phase {
        case .recording, .paused:
            return .recording(paused: recorder.phase == .paused, clock: SessionStore.clock(recorder.elapsed))
        case .finishing:
            // The parts are being joined into one recording.
            return .working(percent: nil)
        case .idle:
            break
        }
        let jobs = Array(sessions.jobs.values)
        let running = jobs.filter { !$0.waiting && !$0.live }
        if !running.isEmpty {
            return .working(percent: Self.percent(of: running))
        }
        if !jobs.isEmpty {
            // Live text still catching up while the recording is saved, or a job about to start.
            return .working(percent: nil)
        }
        let unseen = finished.filter { sessions.session($0.sessionID) != nil }
        if !unseen.isEmpty {
            return .finished(ok: unseen.allSatisfy(\.ok))
        }
        return .idle
    }

    // MARK: Wording

    /// All running transcriptions together, weighted by their length.
    private static func percent(of jobs: [SessionStore.Progress]) -> Int? {
        let fraction: Double
        if jobs.allSatisfy({ $0.secondsTotal > 0 }) {
            let done = jobs.reduce(0) { $0 + min($1.secondsDone, $1.secondsTotal) }
            let total = jobs.reduce(0) { $0 + $1.secondsTotal }
            fraction = done / total
        } else {
            let fractions = jobs.compactMap(\.fraction)
            guard !fractions.isEmpty, fractions.count == jobs.count else { return nil }
            fraction = fractions.reduce(0, +) / Double(fractions.count)
        }
        return percent(fraction)
    }

    /// 100% only shows once it is really over, as the check mark.
    private static func percent(_ fraction: Double) -> Int {
        min(99, max(0, Int((fraction * 100).rounded(.down))))
    }

    private static func detail(_ progress: SessionStore.Progress) -> String {
        if progress.waiting {
            return "In line: starts when the one before it is done"
        }
        if progress.live {
            return progress.partsDone == 0
                ? "Live text while recording"
                : "Live text while recording: \(progress.partsDone) \(progress.partsDone == 1 ? "part" : "parts") so far"
        }
        guard let fraction = progress.fraction else {
            return "Transcribing…"
        }
        if progress.secondsTotal > 0 {
            return "\(percent(fraction))% done: \(SessionStore.clock(progress.secondsDone)) of \(SessionStore.clock(progress.secondsTotal))"
        }
        return "\(percent(fraction))% done: part \(progress.partsDone) of \(progress.partsTotal)"
    }

    private static func image(_ progress: SessionStore.Progress) -> NSImage? {
        if progress.waiting {
            return MenuBarImages.symbol("clock", color: nil, pointSize: 14, description: "In line")
        }
        if progress.live {
            return MenuBarImages.symbol("record.circle.fill", color: .systemRed, pointSize: 14, description: "Recording")
        }
        // The same rounding as the percentage, so a pie never looks full before it is done.
        return MenuBarImages.progress(progress.fraction.map { Double(percent($0)) / 100 })
    }

    private static func short(_ title: String) -> String {
        title.count > 48 ? String(title.prefix(47)) + "…" : title
    }
}

/// The small pictures of the menu bar icon and menu.
enum MenuBarImages {
    static func idle() -> NSImage? {
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Navo")
        image?.isTemplate = true
        return image
    }

    static func done(pointSize: CGFloat = 14) -> NSImage? {
        symbol("checkmark.circle.fill", color: .systemGreen, pointSize: pointSize, description: "Transcription done")
    }

    static func problem(pointSize: CGFloat = 14) -> NSImage? {
        symbol("exclamationmark.circle.fill", color: .systemOrange, pointSize: pointSize, description: "Transcription done, with problems")
    }

    static func recording(paused: Bool) -> NSImage? {
        symbol(
            paused ? "pause.circle.fill" : "record.circle.fill",
            color: paused ? .systemOrange : .systemRed,
            pointSize: 14,
            description: paused ? "Recording paused" : "Recording"
        )
    }

    /// A circle that fills like a pie as `fraction` goes from 0 to 1. Drawn as a template, so it
    /// follows the menu bar's light or dark look.
    static func progress(_ fraction: Double?, size: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let ring = rect.insetBy(dx: 1.25, dy: 1.25)
            let outline = NSBezierPath(ovalIn: ring)
            outline.lineWidth = 1.5
            NSColor.black.setStroke()
            outline.stroke()
            guard let fraction, fraction > 0 else { return true }
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = ring.width / 2 - 2.25
            let wedge = NSBezierPath()
            if fraction >= 0.999 {
                wedge.appendOval(in: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            } else {
                // From twelve o'clock, clockwise.
                wedge.move(to: center)
                wedge.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 90,
                    endAngle: 90 - 360 * CGFloat(min(1, fraction)),
                    clockwise: true
                )
                wedge.close()
            }
            NSColor.black.setFill()
            wedge.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Transcribing"
        return image
    }

    /// An SF Symbol on a colored circle, or a template (following the menu bar) when `color` is nil.
    static func symbol(_ name: String, color: NSColor?, pointSize: CGFloat, description: String) -> NSImage? {
        var config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        if let color {
            // White mark (check, dot, bars) on a colored circle.
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [.white, color]))
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
        image?.isTemplate = color == nil
        return image
    }
}
