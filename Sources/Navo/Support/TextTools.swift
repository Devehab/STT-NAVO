import Foundation

/// Text helpers that understand Arabic, English and code-switched text.
enum TextTools {
    private static let alef: Unicode.Scalar = "\u{0627}"
    private static let yeh: Unicode.Scalar = "\u{064A}"
    private static let heh: Unicode.Scalar = "\u{0647}"
    private static let waw: Unicode.Scalar = "\u{0648}"

    static func isArabicScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return true
        default:
            return false
        }
    }

    static func isLatinLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F:
            return true
        default:
            return false
        }
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    private static func scriptCounts(_ text: String) -> (arabic: Int, latin: Int) {
        var arabic = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if isArabicScalar(scalar) {
                arabic += 1
            } else if isLatinLetter(scalar) {
                latin += 1
            }
        }
        return (arabic, latin)
    }

    /// "ar", "en", "mixed" or "" for text without letters.
    static func detectLanguage(_ text: String) -> String {
        let counts = scriptCounts(text)
        let total = counts.arabic + counts.latin
        guard total > 0 else { return "" }
        let ratio = Double(counts.arabic) / Double(total)
        if ratio >= 0.85 { return "ar" }
        if ratio <= 0.15 { return "en" }
        return "mixed"
    }

    static func isRightToLeft(_ text: String) -> Bool {
        let counts = scriptCounts(text)
        return counts.arabic > counts.latin
    }

    static func languageLabel(_ code: String) -> String {
        switch code {
        case "ar": return "Arabic"
        case "en": return "English"
        case "mixed": return "Arabic + English"
        default: return "Unknown"
        }
    }

    /// Arabic diacritics and tatweel: left out of search keys.
    static func isSearchIgnored(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x064B...0x065F, 0x0670, 0x0640: return true
        default: return false
        }
    }

    /// Search key: lowercased, without Arabic diacritics or tatweel, with hamza/alef/teh-marbuta variants unified.
    static func searchKey(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if isSearchIgnored(scalar) { continue }
            switch scalar.value {
            case 0x0622, 0x0623, 0x0625, 0x0671:
                out.append(alef)
            case 0x0649, 0x0626:
                out.append(yeh)
            case 0x0629:
                out.append(heh)
            case 0x0624:
                out.append(waw)
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }

    private static let lightRules: [(pattern: String, template: String)] = [
        // Recognizer markers such as <hesitation>, <unk>, <noise>
        (#"<\|?[a-z_]{2,24}\|?>"#, " "),
        // English hesitations
        (#"(?i)(?<![\p{L}\p{N}])(u+m+|u+h+|e+r+m+|h+m+|m{2,})(?![\p{L}\p{N}])[,،]?[ \t]*"#, ""),
        // Arabic hesitations (امم / إمم / ممم / ااا). "اه" is left alone: in Levantine it often means "yes".
        (#"(?<![\p{L}\p{N}])([اإ]+م{2,}|م{3,}|ا{3,})(?![\p{L}\p{N}])[,،]?[ \t]*"#, ""),
        // No space before punctuation
        (#"[ \t]+([,.!?;:،؛؟])"#, "$1"),
        // Collapse repeated commas
        (#"([,،])[ \t]*[,،]+"#, "$1"),
        // Collapse runs of spaces
        (#"[ \t]{2,}"#, " "),
    ]

    /// Fast, deterministic cleanup used on every transcript (and alone when LLM cleanup is off).
    static func lightCleanup(_ text: String) -> String {
        var result = text
        for rule in lightRules {
            result = result.replacingOccurrences(of: rule.pattern, with: rule.template, options: .regularExpression)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = result.first, ",،.".contains(first) {
            result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let first = result.first, first.isLowercase, first.isASCII {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }

    /// Applies dictionary replacements ("spoken" -> "written") on whole-word boundaries.
    /// An empty replacement removes the term. Terms without a replacement only guide the cleanup model.
    static func applyReplacements(_ text: String, vocabulary: [VocabularyItem]) -> String {
        var result = text
        var removedSomething = false
        for item in vocabulary {
            guard let replacement = item.replacement?.trimmingCharacters(in: .whitespaces) else { continue }
            let term = item.term.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { continue }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])"
            result = result.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: replacement),
                options: [.regularExpression, .caseInsensitive]
            )
            if replacement.isEmpty { removedSomething = true }
        }
        if removedSomething {
            result = result
                .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"[ \t]+([,.!?;:،؛؟])"#, with: "$1", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func compactNumber(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...:
            return String(format: "%.0fK", Double(value) / 1_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
