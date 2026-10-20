import AppKit
import Foundation

/// Things that went wrong without stopping Navo: a figure that could not be measured, a model
/// that failed to answer, a transcription that did not work, an engine that stopped. Each one is
/// a line in Logs/problems.log (and the last ones are shown in Settings > Performance), so it can
/// be looked at and fixed later. Writing here never throws and never stops the work it describes.
@MainActor
final class ProblemLog: ObservableObject {
    static let shared = ProblemLog()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        /// "AI writing", "Measurements", "Dictation", "Transcription", "Engine", "Storage"
        let area: String
        let message: String
    }

    /// Newest first.
    @Published private(set) var entries: [Entry] = []

    private static let shownLimit = 200
    /// The file is cut to its newer half past this size.
    private static let fileLimit = 512 * 1024
    private let url: URL
    /// Problems written once a run (a figure a model never gives would otherwise fill the log).
    private var said: Set<String> = []

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(url: URL = Paths.problemsLog) {
        self.url = url
        entries = Self.read(url)
    }

    /// Notes a problem. `once`: only the first time in this run of Navo (for a missing figure
    /// that comes back with every answer).
    func report(_ area: String, _ message: String, once: Bool = false) {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        if once {
            guard said.insert(area + "|" + message).inserted else { return }
        }
        // The same problem again within a minute (an engine that keeps failing): one line is enough.
        if let last = entries.first, last.area == area, last.message == message, Date().timeIntervalSince(last.date) < 60 {
            return
        }
        let entry = Entry(date: Date(), area: area, message: message)
        entries.insert(entry, at: 0)
        if entries.count > Self.shownLimit { entries.removeLast(entries.count - Self.shownLimit) }
        append(entry)
    }

    /// The same, from any thread.
    nonisolated static func note(_ area: String, _ message: String, once: Bool = false) {
        Task { @MainActor in shared.report(area, message, once: once) }
    }

    func clear() {
        entries = []
        said = []
        try? Data().write(to: url, options: .atomic)
    }

    func reveal() {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url, options: .atomic)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Every line, oldest first: to paste into a message or a bug report.
    func copyAll() {
        let text = entries.reversed().map(Self.line).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: File

    private static func line(_ entry: Entry) -> String {
        let message = entry.message.replacingOccurrences(of: "\n", with: " ⏎ ")
        return "\(stamp.string(from: entry.date))\t\(entry.area)\t\(message)"
    }

    private func append(_ entry: Entry) {
        let data = Data((Self.line(entry) + "\n").utf8)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            if size > UInt64(Self.fileLimit) { trim() }
        } catch {
            // Nowhere left to say it: the log itself failed. Navo goes on.
        }
    }

    /// Keeps the newer half of a file that grew past its limit.
    private func trim() {
        guard let data = try? Data(contentsOf: url) else { return }
        let half = data.suffix(Self.fileLimit / 2)
        let start = half.firstIndex(of: 0x0A).map { half.index(after: $0) } ?? half.startIndex
        try? Data(half[start...]).write(to: url, options: .atomic)
    }

    private static func read(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(shownLimit)
        return lines.reversed().compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let date = stamp.date(from: String(fields[0])) else { return nil }
            return Entry(date: date, area: String(fields[1]), message: String(fields[2]).replacingOccurrences(of: " ⏎ ", with: "\n"))
        }
    }
}
