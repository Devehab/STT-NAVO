import AppKit
import UniformTypeIdentifiers

/// Several recordings or files as one text or one Word document, oldest first: each with its
/// title, when it was recorded and how long it is, then its text. For Copy and Export when
/// several are selected, and Export as Word for one.
@MainActor
enum TranscriptExport {
    enum Format {
        /// .docx: opens in Word, Pages and Google Docs, Arabic right to left.
        case word
        case text
    }

    /// The ones with text, oldest first.
    static func ordered(_ sessions: [Session]) -> [Session] {
        sessions
            .filter { !$0.transcript.isEmpty }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// "Recorded Oct 19, 2026 at 2:34 PM, 30:30, Whisper, English"
    static func facts(_ session: Session) -> String {
        var parts = [
            "\(session.kind == .meeting ? "Recorded" : "Added") \(session.createdAt.formatted(date: .abbreviated, time: .shortened))",
            SessionStore.clock(session.duration),
        ]
        if let engine = session.engine {
            parts.append(SpeechEngine.from(historyName: engine).shortName)
        }
        parts.append((DictationLanguage(rawValue: session.language) ?? .ar).name)
        return parts.joined(separator: ", ")
    }

    /// The paragraphs of one, with their times when asked.
    static func paragraphs(_ session: Session, withTimes: Bool) -> [String] {
        session.chunks.compactMap { chunk in
            guard let text = chunk.text, !text.isEmpty else { return nil }
            return withTimes ? "[\(SessionStore.clock(chunk.start))] \(text)" : text
        }
    }

    /// Plain text: each one's title and facts, its text, then a line before the next.
    static func plainText(_ sessions: [Session], withTimes: Bool = false) -> String {
        ordered(sessions).map { session in
            ([session.title, facts(session), ""] + paragraphs(session, withTimes: withTimes).flatMap { [$0, ""] })
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
        }
        .joined(separator: "\n\n* * *\n\n")
    }

    /// The Word document: a title page line, then each one on its own page.
    static func document(_ sessions: [Session], withTimes: Bool = false) -> NSAttributedString {
        let chosen = ordered(sessions)
        let out = NSMutableAttributedString()
        // Arial: in Word and Google Docs too, with Arabic letters.
        let regular = NSFont(name: "ArialMT", size: 12) ?? .systemFont(ofSize: 12)
        let bold = NSFont(name: "Arial-BoldMT", size: 12) ?? .boldSystemFont(ofSize: 12)

        func add(_ text: String, size: CGFloat, bold isBold: Bool = false, color: NSColor = .black,
                 arabic: Bool = false, before: CGFloat = 0, after: CGFloat = 8) {
            let style = NSMutableParagraphStyle()
            style.baseWritingDirection = arabic ? .rightToLeft : .leftToRight
            style.alignment = arabic ? .right : .left
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            style.lineHeightMultiple = 1.15
            let font = NSFontManager.shared.convert(isBold ? bold : regular, toSize: size)
            out.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style,
            ]))
        }

        let noun = chosen.allSatisfy { $0.kind == .meeting } ? "recordings" : chosen.allSatisfy { $0.kind == .file } ? "files" : "transcripts"
        add(chosen.count == 1 ? chosen[0].title : "Transcripts", size: 22, bold: true, after: 4)
        add("\(chosen.count) \(chosen.count == 1 ? String(noun.dropLast()) : noun), oldest first. Made by Navo on \(Date().formatted(date: .abbreviated, time: .shortened)).",
            size: 10, color: .darkGray, after: 14)
        if chosen.count > 1 {
            for (index, session) in chosen.enumerated() {
                add("\(index + 1). \(session.title), \(session.createdAt.formatted(date: .abbreviated, time: .shortened))",
                    size: 11, arabic: TextTools.isRightToLeft(session.title), after: 3)
            }
        }
        for (index, session) in chosen.enumerated() {
            let arabic = TextTools.isRightToLeft(String(session.transcript.prefix(2_000)))
            // Each one on a new page (after the list), the page break in its title's paragraph.
            let pageBreak = chosen.count > 1 || index > 0 ? "\u{000C}" : ""
            if chosen.count > 1 {
                add(pageBreak + session.title, size: 16, bold: true, arabic: TextTools.isRightToLeft(session.title), before: 0, after: 4)
            }
            add(facts(session), size: 10, color: .darkGray, arabic: false, after: 12)
            for paragraph in paragraphs(session, withTimes: withTimes) {
                add(paragraph, size: 12, arabic: arabic, after: 8)
            }
        }
        return out
    }

    static func wordData(_ sessions: [Session], withTimes: Bool = false) throws -> Data {
        let text = document(sessions, withTimes: withTimes)
        return try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML, .title: "Navo transcripts"]
        )
    }

    /// Asks where to save, Downloads first, and writes the file. The saved file, or nil when
    /// cancelled. Throws when it could not be written.
    static func save(_ sessions: [Session], format: Format, withTimes: Bool) throws -> URL? {
        let chosen = ordered(sessions)
        guard !chosen.isEmpty else { return nil }
        let panel = NSSavePanel()
        let name = chosen.count == 1
            ? chosen[0].title
            : "Navo, \(chosen.count) transcripts, \(Date().formatted(date: .abbreviated, time: .omitted))"
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        switch format {
        case .word:
            panel.nameFieldStringValue = safe + ".docx"
            panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        case .text:
            panel.nameFieldStringValue = safe + ".txt"
            panel.allowedContentTypes = [.plainText]
        }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        switch format {
        case .word:
            try wordData(chosen, withTimes: withTimes).write(to: url, options: .atomic)
        case .text:
            try plainText(chosen, withTimes: withTimes).write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}
