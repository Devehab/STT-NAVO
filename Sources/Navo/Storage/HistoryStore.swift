import Foundation

/// Which dictations a cleanup applies to.
enum PurgeMode: String, CaseIterable, Identifiable {
    case keepRecent
    case deleteRecent
    case deleteAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepRecent: return "Everything except the last…"
        case .deleteRecent: return "Only the last…"
        case .deleteAll: return "Everything"
        }
    }
}

/// What a cleanup removes.
enum PurgeScope: String, CaseIterable, Identifiable {
    case textAndAudio
    case audioOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .textAndAudio: return "Text and recordings"
        case .audioOnly: return "Recordings only, keep the text"
        }
    }
}

struct DayGroup: Identifiable {
    let id: Date
    let title: String
    let items: [Dictation]
}

/// Observable view of the SQLite history for the Hub.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [Dictation] = [] {
        didSet { groups = Self.group(items) }
    }
    /// The items by day, newest first: worked out once when they change, not on every redraw.
    private(set) var groups: [DayGroup] = []
    @Published private(set) var stats = UsageStats()
    @Published private(set) var vocabulary: [VocabularyItem] = []
    @Published private(set) var lastError: String?
    @Published private(set) var audioFileCount = 0
    @Published private(set) var audioBytes: Int64 = 0
    @Published var searchText = "" {
        didSet { scheduleReload() }
    }

    private let db: Database?
    private var reloadTask: Task<Void, Never>?
    private static let pageSize = 1000

    init(db: Database?, openError: String? = nil) {
        self.db = db
        self.lastError = openError
        reload()
        reloadVocabulary()
    }

    private static func group(_ items: [Dictation]) -> [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(id: day, title: title(for: day), items: grouped[day] ?? [])
        }
    }

    private static let dayFormatter = makeDayFormatter("EEEE MMM d")
    private static let dayYearFormatter = makeDayFormatter("EEEE MMM d yyyy")

    private static func makeDayFormatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: Date())
        return (sameYear ? dayFormatter : dayYearFormatter).string(from: day)
    }

    func reload() {
        guard let db else { return }
        do {
            items = try db.dictations(search: searchText, limit: Self.pageSize)
            stats = try db.stats()
        } catch {
            lastError = error.localizedDescription
        }
        refreshAudioUsage()
    }

    private func refreshAudioUsage() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: Paths.audioDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let wavs = files.filter { $0.pathExtension == "wav" }
        audioFileCount = wavs.count
        audioBytes = wavs.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Makes a deletion final in the database file (secure_delete is on; this also clears the WAL and free pages).
    private func finalizeDeletion() {
        do {
            try db?.compact()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, !Task.isCancelled else { return }
            self.reload()
        }
    }

    func save(_ item: Dictation) {
        guard let db else { return }
        do {
            try db.save(item)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ item: Dictation) {
        guard let db else { return }
        do {
            try db.deleteDictation(id: item.id)
            if let path = item.audioPath {
                try? FileManager.default.removeItem(atPath: path)
            }
            finalizeDeletion()
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteAll() {
        guard let db else { return }
        do {
            try db.deleteAllDictations()
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: Paths.audioDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "wav" {
                    try? fm.removeItem(at: file)
                }
            }
            finalizeDeletion()
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Cleanup by date

    /// Start of the day `days - 1` days ago: "the last 3 days" means today and the two days before.
    static func cutoff(days: Int, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
    }

    private func dateWindow(_ mode: PurgeMode, days: Int) -> (before: Date?, since: Date?) {
        switch mode {
        case .keepRecent: return (Self.cutoff(days: days), nil)
        case .deleteRecent: return (nil, Self.cutoff(days: days))
        case .deleteAll: return (nil, nil)
        }
    }

    /// How many dictations a cleanup would touch, for the confirmation dialog.
    func purgeCount(mode: PurgeMode, days: Int, scope: PurgeScope) -> Int {
        guard let db else { return 0 }
        let window = dateWindow(mode, days: days)
        return (try? db.countDictations(before: window.before, since: window.since, withAudioOnly: scope == .audioOnly)) ?? 0
    }

    /// Permanently deletes dictations (or only their recordings) in a date range. Returns how many were affected.
    @discardableResult
    func purge(mode: PurgeMode, days: Int, scope: PurgeScope) -> Int {
        guard let db else { return 0 }
        let window = dateWindow(mode, days: days)
        var affected = 0
        do {
            let fm = FileManager.default
            for path in try db.audioPaths(before: window.before, since: window.since) {
                try? fm.removeItem(atPath: path)
            }
            switch scope {
            case .textAndAudio:
                affected = try db.deleteDictations(before: window.before, since: window.since)
            case .audioOnly:
                affected = try db.clearAudioPaths(before: window.before, since: window.since)
            }
            if mode == .deleteAll {
                // Also remove recordings that no dictation points to (for example cancelled retries).
                if let files = try? fm.contentsOfDirectory(at: Paths.audioDir, includingPropertiesForKeys: nil) {
                    for file in files where file.pathExtension == "wav" {
                        try? fm.removeItem(at: file)
                    }
                }
            }
            finalizeDeletion()
        } catch {
            lastError = error.localizedDescription
        }
        reload()
        return affected
    }

    /// Automatic retention from Settings: 0 means keep forever.
    func applyRetention(textDays: Int, audioDays: Int) {
        guard db != nil else { return }
        if textDays > 0, purgeCount(mode: .keepRecent, days: textDays, scope: .textAndAudio) > 0 {
            purge(mode: .keepRecent, days: textDays, scope: .textAndAudio)
        }
        if audioDays > 0, purgeCount(mode: .keepRecent, days: audioDays, scope: .audioOnly) > 0 {
            purge(mode: .keepRecent, days: audioDays, scope: .audioOnly)
        }
    }

    // MARK: Vocabulary

    func reloadVocabulary() {
        guard let db else { return }
        do {
            vocabulary = try db.vocabulary()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// `replacement`: nil keeps the term as a spelling hint, "" removes the term from transcripts,
    /// any other text replaces it. Adding a term that already exists updates it.
    func addVocabulary(term: String, replacement: String?) {
        guard let db else { return }
        let cleanTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTerm.isEmpty else { return }
        let existing = vocabulary.first { $0.term.caseInsensitiveCompare(cleanTerm) == .orderedSame }
        let item = VocabularyItem(
            id: existing?.id ?? UUID().uuidString,
            term: cleanTerm,
            replacement: replacement?.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: existing?.createdAt ?? Date()
        )
        do {
            try db.saveVocabulary(item)
            reloadVocabulary()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteVocabulary(_ item: VocabularyItem) {
        guard let db else { return }
        do {
            try db.deleteVocabulary(id: item.id)
            reloadVocabulary()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
