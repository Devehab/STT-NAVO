import Foundation

/// What the AI panel can make from a transcript, in English or Arabic whatever the text is in.
/// A language model on this Mac (Gemma or Llama) writes it: nothing is sent anywhere.
enum WritingAction: String, CaseIterable, Identifiable {
    case summary
    case detailedSummary
    case formalEmail
    case friendlyEmail
    case textMessage
    case tidy

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case summarize = "Summarize"
        case rewrite = "Rewrite"

        var id: String { rawValue }

        var actions: [WritingAction] {
            WritingAction.allCases.filter { $0.group == self }
        }
    }

    var group: Group {
        switch self {
        case .summary, .detailedSummary: return .summarize
        case .formalEmail, .friendlyEmail, .textMessage, .tidy: return .rewrite
        }
    }

    var title: String {
        switch self {
        case .summary: return "Summary"
        case .detailedSummary: return "Detailed summary"
        case .formalEmail: return "Formal email"
        case .friendlyEmail: return "Friendly email"
        case .textMessage: return "Text message"
        case .tidy: return "Clean rewrite"
        }
    }

    var subtitle: String {
        switch self {
        case .summary: return "The main points, short"
        case .detailedSummary: return "Points, decisions, tasks, names and numbers"
        case .formalEmail: return "Professional and polished"
        case .friendlyEmail: return "Warm and personal, still professional"
        case .textMessage: return "WhatsApp or iMessage, the way people text"
        case .tidy: return "Same message, clear and natural: American English or everyday Levantine"
        }
    }

    var icon: String {
        switch self {
        case .summary: return "text.alignleft"
        case .detailedSummary: return "list.bullet.rectangle"
        case .formalEmail: return "envelope"
        case .friendlyEmail: return "envelope.open"
        case .textMessage: return "message"
        case .tidy: return "wand.and.stars"
        }
    }

    /// The languages it can write in.
    var languages: [OutputLanguage] {
        group == .summarize ? [.sameAsText, .english, .arabic] : [.english, .arabic]
    }

    /// What most people want from this text: messages and emails in the other language (an
    /// Arabic dictation becomes an English email, an English one an Arabic email), a clean
    /// rewrite in the same language, a summary in the text's language.
    func defaultLanguage(sourceIsArabic: Bool) -> OutputLanguage {
        switch self {
        case .summary, .detailedSummary: return .sameAsText
        case .formalEmail, .friendlyEmail, .textMessage: return sourceIsArabic ? .english : .arabic
        case .tidy: return sourceIsArabic ? .arabic : .english
        }
    }

    /// Arabic answers are shown right to left.
    func writesArabic(_ language: OutputLanguage, sourceIsArabic: Bool) -> Bool {
        switch language {
        case .arabic: return true
        case .english: return false
        case .sameAsText: return sourceIsArabic
        }
    }

    // MARK: How the model is asked

    /// Steady for summaries, a little freer for messages that should sound like a person.
    var temperature: Double {
        switch self {
        case .summary, .detailedSummary: return 0.2
        case .tidy: return 0.3
        case .formalEmail, .friendlyEmail: return 0.4
        case .textMessage: return 0.6
        }
    }

    /// The most the answer may be, in tokens.
    var maxTokens: Int {
        switch self {
        case .summary: return 700
        case .detailedSummary: return 1_500
        case .formalEmail, .friendlyEmail: return 1_000
        case .textMessage: return 400
        case .tidy: return 2_048
        }
    }

    /// The most characters the model reads at once. A longer text is read in parts, which keeps
    /// every request inside the context that holds the model under its memory limit. A clean
    /// rewrite is as long as its text, so its parts are smaller: the answer has to fit too.
    var partLimit: Int {
        self == .tidy ? 3_000 : 5_000
    }

    /// With `fromNotes`, the text is notes taken part by part from a long transcript.
    func instructions(language: OutputLanguage, fromNotes: Bool = false) -> String {
        [fromNotes ? Self.notesSource : Self.source, task(language: language), Self.rules].joined(separator: "\n\n")
    }

    /// For one part of a long transcript: the notes the final answer is written from.
    static let notesInstructions = """
    You receive one part of a longer transcript of speech: a dictation, a meeting, or a voice \
    note. It was made by speech recognition, so it may contain misheard words, repetitions and \
    filler words, and it may mix Arabic with English.

    Task: write notes of this part, in the language of the transcript. One short line per point, \
    every line starting with "• ". Keep everything that matters: main points, decisions, tasks \
    with who does them and by when, names, numbers, dates, prices and open questions. Leave out \
    small talk and repetition.

    Rules:
    - Use only what the transcript says. Never add anything that is not in it.
    - Plain text only: no Markdown, no headings.
    - Reply with the notes only. No introduction and no closing remarks.
    """

    private static let notesSource = """
    You receive notes taken, part by part and in order, from a long transcript of speech: a \
    dictation, a meeting, or a voice note. They may mix Arabic with English. Work from what the \
    notes say, as if you had the whole transcript.
    """

    private static let source = """
    You receive a transcript of speech: a dictation, a meeting, or a voice note. It was made by \
    speech recognition, so it may contain misheard words, repetitions, filler words and missing \
    punctuation, and it may mix Arabic (often a spoken dialect) with English. Understand what the \
    speaker meant and work from that meaning.
    """

    private static let rules = """
    Rules:
    - Use only what the transcript says. Never add facts, names, numbers, dates, promises or \
    opinions that are not in it.
    - Keep names, numbers, dates, prices and technical terms exactly as meant.
    - Never use em dashes or en dashes. Use commas, periods or line breaks instead.
    - Plain text only: no Markdown, no asterisks, no # headings, no bold.
    - Reply with the result only. No introduction such as "Here is", no notes, no closing remarks.
    """

    private func task(language: OutputLanguage) -> String {
        let arabic = language == .arabic
        switch self {
        case .summary:
            return """
            Task: summarize the transcript. \(language.summaryInstruction)
            Start with one sentence that says what it is about. Then list the most important points, \
            at most seven, one short line each, every line starting with "• ". Leave out small talk \
            and repetition.
            """
        case .detailedSummary:
            return """
            Task: write a thorough, well organized summary of the transcript. \(language.summaryInstruction)
            Use these sections, each as a short title on its own line followed by its content. Leave \
            out any section the transcript has nothing for:
            Overview: two or three sentences.
            Key points: every important point, one per line starting with "• ".
            Decisions: what was decided, one per line starting with "• ".
            Action items: who does what and by when, when the transcript says so, one per line \
            starting with "• ".
            Details: names, numbers, dates, places and figures that matter, one per line starting \
            with "• ".
            Open questions: what was left unresolved, one per line starting with "• ".
            Put one empty line between sections. Translate the section titles into the language \
            of the summary.
            """
        case .formalEmail where arabic:
            return """
            Task: turn the transcript into a formal, professional email in Modern Standard Arabic, \
            translating if it is in English. Write clearly and precisely, the way an experienced \
            professional writes to a client or a senior official in the Arab world, in correct and \
            elegant Arabic.
            Format: first line "الموضوع: " with a specific subject. Then a blank line, a greeting \
            such as "السيد [الاسم] المحترم،" then "تحية طيبة وبعد،", a body of short, well built \
            paragraphs, and a closing such as "وتفضلوا بقبول فائق الاحترام،" followed by "[اسمك]" \
            on its own line. Use [الاسم] and [اسمك] instead of guessing names that are not in the \
            transcript.
            """
        case .formalEmail:
            return """
            Task: turn the transcript into a formal, professional email in English, translating if \
            it is in Arabic. Write clearly and precisely, the way an experienced professional \
            writes to a client or a senior colleague.
            Format: first line "Subject: " with a specific subject. Then a blank line, a greeting \
            such as "Dear [Name]," a body of short, well built paragraphs, and a closing such as \
            "Kind regards," followed by "[Your name]" on its own line. Use [Name] and [Your name] \
            instead of guessing names that are not in the transcript.
            """
        case .friendlyEmail where arabic:
            return """
            Task: turn the transcript into a warm, friendly email in Arabic, translating if it is in \
            English. Use simple, natural Modern Standard Arabic that sounds close to everyday speech: \
            relaxed and personal, still polite and professional. Avoid stiff formulas such as \
            "تحية طيبة وبعد" or "نحيطكم علماً".
            Format: first line "الموضوع: " with a short, natural subject. Then a blank line, \
            "مرحباً [الاسم]،" a few short paragraphs, and a sign off such as "مع خالص التحية،" or \
            "شكراً لك،" followed by "[اسمك]". Use [الاسم] and [اسمك] instead of guessing names.
            """
        case .friendlyEmail:
            return """
            Task: turn the transcript into a warm, friendly email in natural American English, \
            translating if it is in Arabic. It should read like a thoughtful American colleague \
            wrote it: relaxed and personable, contractions welcome, clear and still professional. \
            Avoid stiff phrases such as "I hope this email finds you well" or "Please be advised".
            Format: first line "Subject: " with a short, natural subject. Then a blank line, \
            "Hi [Name]," a few short paragraphs, and a sign off such as "Thanks," or "Best," \
            followed by "[Your name]". Use [Name] and [Your name] instead of guessing names.
            """
        case .textMessage where arabic:
            return """
            Task: turn the transcript into a WhatsApp message in everyday spoken Levantine Arabic, \
            the clean city dialect of Jordan and Syria that everyone in the region understands, \
            translating if it is in English. Write it the way people really text a friend or a \
            coworker: short, relaxed, simple words, in Arabic letters, for example هلأ، بدي، شو، \
            كتير، منيح، هيك، تمام.
            It must not sound written or formal. No Modern Standard Arabic phrasing, few commas, no \
            bullet points, no lists, no subject line, no formal greeting and no sign off. Keep it as \
            short as the message allows, usually one to four short lines. An emoji only if the tone \
            clearly calls for one.
            """
        case .textMessage:
            return """
            Task: turn the transcript into a text message (WhatsApp or iMessage) in casual, natural \
            American English, translating if it is in Arabic. Write it the way a real person texts \
            a friend or a coworker: short, relaxed, simple words, contractions.
            It must not sound written or structured. Use few commas. No semicolons, no bullet \
            points, no lists, no subject line, no greeting like "Dear", no sign off, and no \
            connecting words such as "Additionally", "Furthermore", "Moreover" or "Therefore". \
            Keep it as short as the message allows, usually one to four short lines. An emoji only \
            if the tone clearly calls for one.
            """
        case .tidy where arabic:
            return """
            Task: rewrite the transcript in Arabic, in the everyday spoken Levantine Arabic that \
            people in Jordan and Syria use and everyone in the region understands: a clean city \
            dialect, not the accent of one village or area, and not Modern Standard Arabic. \
            Translate if it is in English.
            Write it neatly and smoothly: fix recognition errors and spelling, drop repetitions and \
            filler words, put the ideas in a natural order and use natural Levantine wording, for \
            example هلأ، بدي، شو، كتير، منيح، هيك، لازم، مشان. Keep every piece of meaning and \
            every detail, and keep the speaker's own voice. Use Arabic letters and proper Arabic \
            punctuation (، and ؟). Use short paragraphs when the text is long.
            """
        case .tidy:
            return """
            Task: rewrite the transcript in clear, natural American English, translating if it is in \
            Arabic. Keep the speaker's own voice and point of view, as if they had written it \
            themselves: not an email and not a summary.
            Fix recognition errors, drop repetitions and filler words, put the ideas in a natural \
            order, and use plain, everyday wording with contractions where they sound natural. \
            Keep every piece of meaning and every detail. Use short paragraphs when the text is long.
            """
        }
    }
}

/// The language an answer is written in.
enum OutputLanguage: String, CaseIterable, Identifiable {
    case sameAsText
    case english
    case arabic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sameAsText: return "Same as the text"
        case .english: return "English"
        case .arabic: return "Arabic"
        }
    }

    var summaryInstruction: String {
        switch self {
        case .sameAsText:
            return "Write it in the main language of the transcript. If that is Arabic, use clear Modern Standard Arabic."
        case .english:
            return "Write it in English."
        case .arabic:
            return "Write it in clear Modern Standard Arabic."
        }
    }
}
