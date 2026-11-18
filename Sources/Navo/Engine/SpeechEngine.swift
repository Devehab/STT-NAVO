import Foundation

/// The speech-to-text engines the local Navo engine can run. They live in one engine process
/// on the same port, each can be loaded or unloaded on its own, and at most
/// `AppSettings.maxEnabledEngines` are on at once.
enum SpeechEngine: String, CaseIterable, Identifiable {
    case cohere
    case audar
    case whisper
    case qwen3
    case jais

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cohere: return "Cohere Transcribe Arabic"
        case .audar: return "Audar ASR V1 Turbo"
        case .whisper: return "Whisper Large v3 Turbo"
        case .qwen3: return "Qwen3-ASR 1.7B"
        case .jais: return "Jais-ASR"
        }
    }

    var shortName: String {
        switch self {
        case .cohere: return "Cohere"
        case .audar: return "Audar"
        case .whisper: return "Whisper"
        case .qwen3: return "Qwen3"
        case .jais: return "Jais"
        }
    }

    var defaultModel: String {
        switch self {
        case .cohere: return "CohereLabs/cohere-transcribe-arabic-07-2026"
        case .audar: return "audarai/Audar-ASR-V1-Turbo"
        case .whisper: return "mlx-community/whisper-large-v3-turbo-asr-fp16"
        case .qwen3: return "mlx-community/Qwen3-ASR-1.7B-bf16"
        // The 8-bit MLX build: the most accurate of IFM's Mac builds (WER 22.76%).
        case .jais: return "IFM/Jais-ASR-MLX-8bit"
        }
    }

    /// Stored in the history next to each dictation, for example "audar-asr-v1-turbo (mlx)".
    var historyName: String {
        switch self {
        case .cohere: return "cohere-transcribe-arabic"
        case .audar: return "audar-asr-v1-turbo"
        case .whisper: return "whisper-large-v3-turbo"
        case .qwen3: return "qwen3-asr-1.7b"
        case .jais: return "jais-asr"
        }
    }

    var isGated: Bool { self == .cohere }

    /// The download, in GB.
    var downloadGB: Double {
        switch self {
        case .cohere: return 4.1
        case .audar: return 4.7
        case .whisper: return 1.6
        case .qwen3: return 4.1
        case .jais: return 7.0
        }
    }

    /// What it is best at, in a few words.
    var purpose: String {
        switch self {
        case .cohere: return "Speech to text: Arabic dialects, English"
        case .audar: return "Speech to text: Arabic dialects, English"
        case .whisper: return "Speech to text: English, 100 languages"
        case .qwen3: return "Speech to text: English, 30 languages"
        case .jais: return "Speech to text: Arabic dialects of 19 countries, English"
        }
    }

    /// Languages Navo asks for. Audar, Whisper, Qwen3 and Jais can also detect the language
    /// themselves (and through the API they take more languages); Audar's and Jais's dialect
    /// (Gulf, Egyptian, Levantine, Maghrebi, MSA) always comes from the audio.
    var languages: [DictationLanguage] {
        switch self {
        case .cohere: return [.ar, .en]
        case .audar, .whisper, .qwen3, .jais: return [.ar, .en, .auto]
        }
    }

    var summary: String {
        switch self {
        case .cohere:
            return "Arabic dialects and English. Gated on Hugging Face: needs a Read token once to download."
        case .audar:
            return "Qwen3-ASR based, near the top of the Open Universal Arabic ASR leaderboard. Public, about 4.7 GB, AudarAI Community License."
        case .whisper:
            return "OpenAI's Whisper, fast and strong in English, 99 other languages too. Public, about 1.6 GB, MIT License."
        case .qwen3:
            return "Alibaba's Qwen3-ASR, strong in English and 29 other languages, 16 bit. Public, about 4.1 GB, Apache 2.0."
        case .jais:
            return "IFM's Jais-ASR, the lowest error rate on the Open Universal Arabic ASR leaderboard: MSA and the dialects of 19 Arab countries, Levantine included, with English kept in its own letters. 8 bit. Public, about 7 GB, Apache 2.0. Best with 16 GB of memory or more."
        }
    }

    var modelPage: URL {
        URL(string: "https://huggingface.co/\(defaultModel)")!
    }

    /// The engine that produced a history item, from its stored engine name.
    static func from(historyName name: String) -> SpeechEngine {
        let name = name.lowercased()
        if name.contains("audar") { return .audar } // before qwen3: Audar is a Qwen3-ASR fine-tune
        if name.contains("whisper") { return .whisper }
        if name.contains("qwen3") { return .qwen3 }
        if name.contains("jais") { return .jais }
        return .cohere
    }
}
