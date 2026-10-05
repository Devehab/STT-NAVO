import Foundation

/// The local language models that summarize and rewrite text (AI writing). They run inside the
/// Navo engine on this Mac, never together with a speech model, and use at most 6 GB of memory.
enum WritingModel: String, CaseIterable, Identifiable {
    case gemma
    case llama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemma: return "Gemma 4 E4B"
        case .llama: return "Llama 3.1 8B"
        }
    }

    var shortName: String {
        switch self {
        case .gemma: return "Gemma"
        case .llama: return "Llama"
        }
    }

    var maker: String {
        switch self {
        case .gemma: return "Google"
        case .llama: return "Meta"
        }
    }

    /// 4 bit MLX builds: the same runtime as the speech models, and under 6 GB in memory.
    var defaultModel: String {
        switch self {
        case .gemma: return "mlx-community/gemma-4-e4b-it-4bit"
        case .llama: return "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"
        }
    }

    /// The download, in GB.
    var downloadGB: Double {
        switch self {
        case .gemma: return 5.2
        case .llama: return 4.5
        }
    }

    var summary: String {
        switch self {
        case .gemma:
            return "Google's open model, trained on more than 140 languages. The better choice for Arabic. Public, about 5.2 GB, Apache 2.0."
        case .llama:
            return "Meta's open model. Strong in English, weaker in Arabic dialects. Public, about 4.5 GB, Llama 3.1 Community License."
        }
    }

    var modelPage: URL {
        URL(string: "https://huggingface.co/\(defaultModel)")!
    }
}
