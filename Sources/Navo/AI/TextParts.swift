import Foundation

/// Cuts a long text into parts a local language model can read one at a time, so a request
/// never grows past the context that keeps the model under its memory limit.
enum TextParts {
    /// Parts of at most `limit` characters, cut between paragraphs when possible, else between
    /// sentences, else between words. Nothing is dropped: joined with blank lines, the parts
    /// hold every word of the text.
    static func split(_ text: String, limit: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit, limit > 0 else { return trimmed.isEmpty ? [] : [trimmed] }

        var pieces: [String] = []
        for paragraph in trimmed.components(separatedBy: "\n") {
            let paragraph = paragraph.trimmingCharacters(in: .whitespaces)
            guard !paragraph.isEmpty else { continue }
            if paragraph.count <= limit {
                pieces.append(paragraph)
            } else {
                pieces.append(contentsOf: sentences(paragraph, limit: limit))
            }
        }

        // Pack whole pieces into parts, as full as the limit allows.
        var parts: [String] = []
        var current = ""
        for piece in pieces {
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= limit {
                current += "\n" + piece
            } else {
                parts.append(current)
                current = piece
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "؟", "۔", "…", "。", "؛", ";"]

    /// A paragraph longer than the limit, cut after sentence ends, and inside a sentence only
    /// when one sentence alone is longer than the limit.
    private static func sentences(_ paragraph: String, limit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        var sentence = ""

        func flushSentence() {
            let text = sentence.trimmingCharacters(in: .whitespaces)
            sentence = ""
            guard !text.isEmpty else { return }
            if text.count > limit {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                result.append(contentsOf: words(text, limit: limit))
            } else if current.isEmpty {
                current = text
            } else if current.count + 1 + text.count <= limit {
                current += " " + text
            } else {
                result.append(current)
                current = text
            }
        }

        var previous: Character?
        for character in paragraph {
            if character == " ", let previous, sentenceEnds.contains(previous) {
                flushSentence()
            } else {
                sentence.append(character)
            }
            previous = character
        }
        flushSentence()
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func words(_ text: String, limit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            var word = String(word)
            // A single "word" longer than the limit (a long link, text without spaces).
            while word.count > limit {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                result.append(String(word.prefix(limit)))
                word = String(word.dropFirst(limit))
            }
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= limit {
                current += " " + word
            } else {
                result.append(current)
                current = word
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
