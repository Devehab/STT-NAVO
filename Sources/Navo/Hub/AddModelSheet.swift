import AppKit
import SwiftUI

/// What a folder or file holds, as far as Navo can tell before loading it.
struct ModelFolder: Identifiable, Hashable {
    let url: URL
    let format: CustomModel.Format
    let bytes: Int64
    /// A readable name from the folder or file name.
    let suggestedName: String
    /// Who published it, from LM Studio's folders (models/<publisher>/<model>).
    let publisher: String?

    var id: String { url.path }

    /// Where LM Studio keeps its models, now and in older versions.
    static var lmStudioFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".lmstudio/models", isDirectory: true),
            home.appendingPathComponent(".cache/lm-studio/models", isDirectory: true),
        ]
    }

    /// The models in LM Studio's folders: two levels down, publisher then model.
    static func scanLMStudio() -> [ModelFolder] {
        let fm = FileManager.default
        var found: [ModelFolder] = []
        for root in lmStudioFolders where fm.fileExists(atPath: root.path) {
            let publishers = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for publisher in publishers where publisher.hasDirectoryPath {
                let models = (try? fm.contentsOfDirectory(at: publisher, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                for model in models {
                    if let folder = inspect(model, publisher: publisher.lastPathComponent) {
                        found.append(folder)
                    }
                }
            }
        }
        return found.sorted { $0.suggestedName.localizedCaseInsensitiveCompare($1.suggestedName) == .orderedAscending }
    }

    /// A model folder (MLX: config.json and .safetensors; GGUF: a .gguf file) or a .gguf file.
    static func inspect(_ url: URL, publisher: String? = nil) -> ModelFolder? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue {
            guard url.pathExtension.lowercased() == "gguf" else { return nil }
            return ModelFolder(url: url, format: .gguf, bytes: size(of: url), suggestedName: pretty(url.deletingPathExtension().lastPathComponent), publisher: publisher)
        }
        let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        if names.contains("config.json"), names.contains(where: { $0.hasSuffix(".safetensors") }) {
            return ModelFolder(url: url, format: .mlx, bytes: folderSize(url), suggestedName: pretty(url.lastPathComponent), publisher: publisher)
        }
        let ggufs = names.filter { $0.lowercased().hasSuffix(".gguf") && !$0.lowercased().hasPrefix("mmproj") }
        guard !ggufs.isEmpty else { return nil }
        // The engine runs the largest one (other files are often vision projectors or other sizes).
        let largest = ggufs.map { url.appendingPathComponent($0) }.max { size(of: $0) < size(of: $1) }!
        return ModelFolder(url: url, format: .gguf, bytes: size(of: largest), suggestedName: pretty(url.lastPathComponent), publisher: publisher)
    }

    /// "gemma-4-12B-it-QAT-GGUF" -> "gemma 4 12B it QAT"
    static func pretty(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .filter { !["gguf", "mlx"].contains($0.lowercased()) }
        return words.joined(separator: " ")
    }

    static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Bytes in a folder, following links (a Hugging Face style folder links to its files).
    static func folderSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        let root = url.resolvingSymlinksInPath()
        var total: Int64 = 0
        guard let walker = fm.enumerator(atPath: root.path) else { return 0 }
        for case let name as String in walker {
            let file = root.appendingPathComponent(name).resolvingSymlinksInPath()
            guard let attributes = try? fm.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular
            else { continue }
            total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }
}

/// Adds a language model that is already on this Mac (LM Studio's, or any folder) for AI
/// writing: Navo reads it where it is, so it takes no extra space. Ends with a real test.
struct AddModelSheet: View {
    @EnvironmentObject private var engine: LocalEngineManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ai: AIWriter
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case choosing
        case working(String)
        case passed(String)
        case failed(String)
    }

    @State private var found: [ModelFolder] = []
    @State private var scanned = false
    @State private var chosen: ModelFolder?
    @State private var name = ""
    @State private var format: CustomModel.Format = .mlx
    @State private var step: Step = .choosing
    @State private var added: CustomModel?
    @State private var useIt = true

    private var memory: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }
    private var alreadyAdded: Set<String> { Set(settings.customModels.map(\.path)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            switch step {
            case .choosing:
                chooser
            case .working(let message):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(message)
                }
                if engine.addingGGUF {
                    ProgressView(value: engine.installProgress)
                    Text(engine.installStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            case .passed(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Use it for AI writing now", isOn: $useIt)
                Spacer(minLength: 0)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Divider()
            buttons
        }
        .padding(22)
        .frame(width: 640, height: 600)
        .task {
            guard !scanned else { return }
            scanned = true
            found = await Task.detached(priority: .userInitiated) { ModelFolder.scanLMStudio() }.value
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            SettingsIcon(pane: .writing, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a model you already have")
                    .font(.title2.weight(.semibold))
                Text("For summaries, rewrites and translations. Navo uses the model where it is, from LM Studio's folder or any other: nothing is downloaded or copied, so it takes no extra space.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Choosing

    @ViewBuilder
    private var chooser: some View {
        if found.isEmpty {
            Text(scanned ? "No models found in LM Studio's folder (~/.lmstudio/models). Choose a folder or a .gguf file below." : "Looking in LM Studio's folder…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text("In LM Studio")
                .font(.headline)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(found) { folder in
                        foundRow(folder)
                    }
                }
            }
            .frame(maxHeight: 190)
        }
        Button("Choose a folder or a .gguf file…") { choose() }
        if let chosen {
            form(chosen)
        }
        Spacer(minLength: 0)
    }

    private func foundRow(_ folder: ModelFolder) -> some View {
        let isAdded = alreadyAdded.contains(folder.url.path)
        return Button {
            pick(folder)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: chosen == folder ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(chosen == folder ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.suggestedName).lineLimit(1)
                    Text([folder.publisher, folder.url.lastPathComponent].compactMap { $0 }.joined(separator: " / "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isAdded {
                    Text("Added").font(.caption).foregroundStyle(.secondary)
                }
                FormatBadge(format: folder.format)
                Text(ProcessMemory.formatFile(folder.bytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(chosen == folder ? Color.accentColor.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func form(_ folder: ModelFolder) -> some View {
        Form {
            TextField("Name", text: $name)
            LabeledContent("Where") {
                Text((folder.url.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Picker("Format", selection: $format) {
                ForEach(CustomModel.Format.allCases) { format in
                    Text(format == .mlx ? "MLX (a folder of .safetensors)" : "GGUF (a .gguf file)").tag(format)
                }
            }
            LabeledContent("Size") {
                Text(ProcessMemory.formatFile(folder.bytes))
            }
            ForEach(notes(folder), id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 230)
    }

    private func notes(_ folder: ModelFolder) -> [String] {
        var notes: [String] = []
        let ram = Double(memory)
        if Double(folder.bytes) > ram * 0.8 {
            notes.append("This model is \(ProcessMemory.formatFile(folder.bytes)) and this Mac has \(ProcessMemory.formatFile(memory)) of memory: it will most likely not load. Models up to about \(ProcessMemory.formatFile(Int64(ram * 0.6))) work well here.")
        } else if Double(folder.bytes) > ram * 0.6 {
            notes.append("This model is large for this Mac (\(ProcessMemory.formatFile(memory)) of memory): it may be slow, and other apps may slow down while it writes.")
        }
        if format == .gguf && engine.ggufRuntime == nil {
            notes.append("GGUF models run on llama.cpp. Navo adds it to its engine first: one ready-made package, about 15 MB, one time.")
        }
        if format != folder.format {
            notes.append("This looks like \(folder.format.title) to Navo. Pick another format only if you are sure.")
        }
        return notes
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack {
            switch step {
            case .choosing:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add and test") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen == nil || name.trimmingCharacters(in: .whitespaces).isEmpty || !engine.isInstalled)
                    .help(engine.isInstalled ? "Adds it, then loads it and asks it for one sentence" : "Install the local engine first")
            case .working:
                Spacer()
                Button("Close") { dismiss() }
                    .help("It keeps going in the background")
            case .passed:
                Spacer()
                Button("Done") {
                    if useIt, let added { settings.writingModel = WritingModel(added) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            case .failed:
                if let added {
                    Button("Remove it") {
                        settings.removeCustomModel(added.id)
                        engine.customModelsChanged()
                        self.added = nil
                        step = .choosing
                    }
                    .help("Navo stops using it. Its files stay where they are.")
                }
                Spacer()
                Button("Try again") { if let added { test(added) } else { step = .choosing } }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: Actions

    private func pick(_ folder: ModelFolder) {
        chosen = folder
        name = folder.suggestedName
        format = folder.format
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a model folder (MLX) or a .gguf file"
        panel.prompt = "Choose"
        if let start = ModelFolder.lmStudioFolders.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            panel.directoryURL = start
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let folder = ModelFolder.inspect(url) {
            pick(folder)
        } else {
            step = .failed("No model there. Navo needs a folder with config.json and .safetensors files (MLX), or a .gguf file.")
        }
    }

    private func add() {
        guard let folder = chosen else { return }
        let model = CustomModel(
            id: CustomModel.newID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            path: folder.url.path,
            format: format,
            bytes: folder.bytes
        )
        Task { @MainActor in
            if model.format == .gguf && engine.ggufRuntime == nil {
                step = .working("Adding GGUF support to Navo's engine")
                guard await engine.addGGUFSupport() else {
                    step = .failed("Could not add GGUF support: \(engine.lastProblem)")
                    return
                }
            }
            settings.addCustomModel(model)
            added = model
            engine.customModelsChanged()
            test(model)
        }
    }

    private func test(_ model: CustomModel) {
        let writing = WritingModel(model)
        step = .working("Starting the engine with \(model.name)")
        Task { @MainActor in
            // The engine restarts to read the new list: wait until it lists the model.
            for _ in 0..<120 where engine.llms[writing] == nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard engine.llms[writing] != nil else {
                step = .failed("The engine did not start with the new model. Open Settings > Speech engines > Engine log for details.")
                return
            }
            step = .working("Loading \(model.name) and asking it for one sentence. A large model can take a minute.")
            do {
                let result = try await ai.test(writing)
                step = .passed("\(model.name) works: it answered in \(String(format: "%.1f", result.seconds)) s"
                    + (result.stats.map { ", \($0)" } ?? "")
                    + ": \"\(result.reply)\"")
            } catch {
                step = .failed("\(model.name) did not answer: \(error.localizedDescription)")
            }
        }
    }
}

/// "MLX" or "GGUF" in a small capsule.
struct FormatBadge: View {
    let format: CustomModel.Format

    var body: some View {
        Text(format.title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().strokeBorder(Color.secondary.opacity(0.5)))
            .foregroundStyle(.secondary)
    }
}
