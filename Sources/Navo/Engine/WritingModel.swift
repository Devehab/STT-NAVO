import Foundation

/// A language model you already have on this Mac (downloaded by LM Studio, for example), used
/// from its own folder for AI writing. Nothing is copied: Navo reads the files where they are.
struct CustomModel: Codable, Hashable, Identifiable {
    enum Format: String, Codable, CaseIterable, Identifiable {
        /// A folder with config.json and .safetensors, run on MLX like Gemma and Llama.
        case mlx
        /// A .gguf file, run on llama.cpp with Metal.
        case gguf

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mlx: return "MLX"
            case .gguf: return "GGUF"
            }
        }
    }

    /// "custom-" and a short random part: the engine's name for it (/custom-…/v1/chat/completions).
    let id: String
    var name: String
    /// The model folder, or the .gguf file itself.
    var path: String
    var format: Format
    /// Its size on disk when it was added.
    var bytes: Int64

    static func newID() -> String {
        "custom-" + UUID().uuidString.prefix(8).lowercased()
    }
}

/// The models added from a folder, readable from anywhere (AppSettings keeps them).
enum CustomModels {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: [CustomModel] = []

    static var all: [CustomModel] {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    static func set(_ models: [CustomModel]) {
        lock.lock()
        current = models
        lock.unlock()
    }

    static func model(_ id: String) -> CustomModel? {
        all.first { $0.id == id }
    }
}

/// A local language model that summarizes and rewrites text (AI writing): Gemma or Llama, which
/// Navo downloads, or one you added from a folder. They run inside the Navo engine on this Mac,
/// never together with a speech model.
struct WritingModel: Hashable, Identifiable {
    /// The engine's name for it: "gemma", "llama" or "custom-…".
    let rawValue: String

    static let gemma = WritingModel(id: "gemma")
    static let llama = WritingModel(id: "llama")
    /// The ones Navo downloads itself.
    static let builtIn: [WritingModel] = [.gemma, .llama]

    private init(id: String) {
        rawValue = id
    }

    /// A built-in model, or one added from a folder; nil for anything else.
    init?(rawValue: String) {
        guard Self.builtIn.contains(where: { $0.rawValue == rawValue }) || CustomModels.model(rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    init(_ custom: CustomModel) {
        rawValue = custom.id
    }

    /// Every model to choose from: Gemma, Llama, then the ones added from a folder.
    static var allCases: [WritingModel] {
        builtIn + CustomModels.all.map(WritingModel.init)
    }

    var id: String { rawValue }

    /// Added from a folder (nil for Gemma and Llama).
    var custom: CustomModel? { CustomModels.model(rawValue) }
    var isCustom: Bool { rawValue.hasPrefix("custom-") }

    var title: String {
        switch rawValue {
        case "gemma": return "Gemma 4 E4B"
        case "llama": return "Llama 3.1 8B"
        default: return custom?.name ?? "Your model"
        }
    }

    var shortName: String {
        switch rawValue {
        case "gemma": return "Gemma"
        case "llama": return "Llama"
        default: return custom?.name ?? "Your model"
        }
    }

    var maker: String {
        switch rawValue {
        case "gemma": return "Google"
        case "llama": return "Meta"
        default: return custom.map { "\($0.format.title), from a folder" } ?? ""
        }
    }

    /// 4 bit MLX builds: the same runtime as the speech models, and under 6 GB in memory. For a
    /// model added from a folder: that folder.
    var defaultModel: String {
        switch rawValue {
        case "gemma": return "mlx-community/gemma-4-e4b-it-4bit"
        case "llama": return "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"
        default: return custom?.path ?? ""
        }
    }

    /// The download, in GB (the size on disk for a model added from a folder).
    var downloadGB: Double {
        switch rawValue {
        case "gemma": return 5.2
        case "llama": return 4.5
        default: return Double(custom?.bytes ?? 0) / 1_000_000_000
        }
    }

    var summary: String {
        switch rawValue {
        case "gemma":
            return "Google's open model, trained on more than 140 languages. The better choice for Arabic. Public, about 5.2 GB, Apache 2.0."
        case "llama":
            return "Meta's open model. Strong in English, weaker in Arabic dialects. Public, about 4.5 GB, Llama 3.1 Community License."
        default:
            guard let custom else { return "" }
            return "Used where it is, nothing copied: \((custom.path as NSString).abbreviatingWithTildeInPath)"
        }
    }

    var modelPage: URL {
        if let custom { return URL(fileURLWithPath: custom.path) }
        return URL(string: "https://huggingface.co/\(defaultModel)")!
    }
}
