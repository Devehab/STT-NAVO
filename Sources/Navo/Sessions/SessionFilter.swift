import Foundation

/// The dates a list of recordings or files is narrowed to.
enum SessionPeriod: Hashable {
    case any
    case today
    case yesterday
    /// The last 7 days, today included.
    case week
    /// The last 30 days, today included.
    case month
    /// One day, whichever time it holds.
    case day(Date)

    static let presets: [SessionPeriod] = [.any, .today, .yesterday, .week, .month]

    var title: String {
        switch self {
        case .any: return "Any date"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .day(let date): return date.formatted(date: .abbreviated, time: .omitted)
        }
    }

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: today) ?? today
        }
        switch self {
        case .any: return true
        case .today: return date >= today
        case .yesterday: return date >= daysAgo(1) && date < today
        case .week: return date >= daysAgo(6)
        case .month: return date >= daysAgo(29)
        case .day(let day): return calendar.isDate(date, inSameDayAs: day)
        }
    }
}

/// Finds recordings and files by words in their title, file name or text. The searchable form
/// of each text (lower case, Arabic without diacritics, hamza and alef forms as one) is built
/// once, off the main thread, and kept until that recording changes, so typing stays smooth
/// with hundreds of long transcripts.
actor SessionSearchIndex {
    /// The searchable form of one session: its title and file name, and its text.
    private struct Entry {
        let stamp: Int
        let head: String
        let body: String
    }

    private var entries: [String: Entry] = [:]

    /// The sessions that hold every word of `words`, each with a line of its text around the
    /// first word found in it ("" when only the title or file name matched).
    func hits(for words: [String], in sessions: [Session]) -> [String: String] {
        var found: [String: String] = [:]
        var alive = Set<String>()
        for session in sessions {
            if Task.isCancelled { return [:] }
            alive.insert(session.id)
            let stamp = Self.stamp(session)
            let entry: Entry
            if let cached = entries[session.id], cached.stamp == stamp {
                entry = cached
            } else {
                entry = Entry(
                    stamp: stamp,
                    head: TextTools.searchKey(session.title + "\n" + session.source),
                    body: TextTools.searchKey(session.transcript)
                )
                entries[session.id] = entry
            }
            guard words.allSatisfy({ entry.body.contains($0) || entry.head.contains($0) }) else { continue }
            found[session.id] = Self.snippet(of: session.transcript, key: entry.body, around: words)
        }
        // Deleted recordings leave the index.
        if entries.count > alive.count {
            entries = entries.filter { alive.contains($0.key) }
        }
        return found
    }

    /// Changes whenever the title or the text does, without reading the whole text.
    private static func stamp(_ session: Session) -> Int {
        var hasher = Hasher()
        hasher.combine(session.title)
        hasher.combine(session.chunks.count)
        for chunk in session.chunks {
            hasher.combine(chunk.text?.utf8.count ?? -1)
        }
        return hasher.finalize()
    }

    /// About 90 characters of `text` around the first of `words` that its search key holds.
    /// The key leaves out diacritics, so the place is counted back into the text as written.
    static func snippet(of text: String, key: String, around words: [String]) -> String {
        for word in words {
            guard let range = key.range(of: word) else { continue }
            let before = key.unicodeScalars.distance(from: key.unicodeScalars.startIndex, to: range.lowerBound)
            let scalars = Array(text.unicodeScalars)
            var kept = 0
            var position = 0
            while position < scalars.count, kept < before {
                if !TextTools.isSearchIgnored(scalars[position]) { kept += 1 }
                position += 1
            }
            let start = max(0, position - 30)
            let end = min(scalars.count, position + word.unicodeScalars.count + 60)
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[start..<end])
            let line = String(view).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return (start > 0 ? "…" : "") + line + (end < scalars.count ? "…" : "")
        }
        return ""
    }
}

/// The search words and dates of one list (Record or Files), and what they leave of it.
@MainActor
final class SessionFilter: ObservableObject {
    @Published var query = ""
    @Published var period: SessionPeriod = .any
    /// The sessions the search words are found in, with a line of text each. Nil: no words typed.
    @Published private(set) var hits: [String: String]?

    private let index = SessionSearchIndex()
    private var task: Task<Void, Never>?

    private var words: [String] {
        TextTools.searchKey(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var isActive: Bool { hits != nil || period != .any || !words.isEmpty }

    func reset() {
        task?.cancel()
        query = ""
        period = .any
        hits = nil
    }

    /// Searches again, a moment after the last key press. `sessions` is what the list holds now.
    func search(in sessions: [Session]) {
        task?.cancel()
        let words = words
        guard !words.isEmpty else {
            hits = nil
            return
        }
        let index = index
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let found = await index.hits(for: words, in: sessions)
            guard !Task.isCancelled else { return }
            self?.hits = found
        }
    }

    /// The sessions within the dates that hold the search words, in their order.
    func apply(to sessions: [Session]) -> [Session] {
        guard hits != nil || period != .any else { return sessions }
        let now = Date()
        return sessions.filter { session in
            (hits == nil || hits?[session.id] != nil) && period.contains(session.createdAt, now: now)
        }
    }
}
