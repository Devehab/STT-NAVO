import AppKit
import Darwin
import Foundation

/// Installs, launches and supervises the local Python engine: a small gateway on the engine port that
/// starts the model worker (the speech engines that are on, and the cleanup LLM) when a model is
/// needed and stops it after the idle time, so the models only use memory while they are in use.
@MainActor
final class LocalEngineManager: ObservableObject {
    /// Readiness of the engine that transcribes dictation.
    enum State: Equatable {
        case notInstalled
        case installing
        case stopped
        case starting
        case loading
        case sleeping
        case ready(backend: String)
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        /// Ready, or asleep and loaded again by the next request.
        var canDictate: Bool {
            isReady || self == .sleeping
        }

        var label: String {
            switch self {
            case .notInstalled: return "Not installed"
            case .installing: return "Installing"
            case .stopped: return "Stopped"
            case .starting: return "Starting"
            case .loading: return "Loading model"
            case .sleeping: return "Sleeping"
            case .ready(let backend): return "Ready (\(backend == "mlx" ? "MLX" : backend))"
            case .failed: return "Error"
            }
        }

        /// What to tell the user when dictation cannot run.
        var userMessage: String {
            switch self {
            case .notInstalled: return "Install the local engine in Settings first"
            case .installing: return "The local engine is still installing"
            case .stopped, .starting, .loading: return "The speech model is still loading"
            case .ready, .sleeping: return ""
            case .failed(let message): return message
            }
        }
    }

    /// One speech engine inside the engine process.
    struct EngineInfo: Equatable {
        var status: String // off, asleep, loading, ready or error
        var downloaded: Bool
        var backend: String?
        var device: String?
        var error: String?
        var modelPath: String?
        var modelBytes: Int64?
        var transcriptions: Int
        var lastProcessingMs: Int?

        var isReady: Bool { status == "ready" }

        var label: String {
            switch status {
            case "ready": return backend == "mlx" ? "Ready (MLX)" : "Ready" + (backend.map { " (\($0))" } ?? "")
            case "loading": return "Loading"
            case "asleep": return downloaded ? "Sleeping, loads when used" : "Not downloaded"
            case "error": return downloaded ? "Error" : "Not downloaded"
            default: return downloaded ? "Off" : "Not downloaded"
            }
        }
    }

    /// One language model (AI writing) inside the engine process.
    struct LLMInfo: Equatable {
        var status: String // asleep, loading, ready, writing or error
        var downloaded: Bool
        var error: String?
        var modelBytes: Int64?
        /// The most memory MLX has used for it this session, weights included.
        var peakMemoryBytes: Int64?
        var tokensPerSecond: Double?

        var inMemory: Bool { status == "ready" || status == "writing" || status == "loading" }

        var label: String {
            guard downloaded else { return "Not downloaded" }
            switch status {
            case "ready": return "In memory"
            case "writing": return "Writing"
            case "loading": return "Loading"
            case "error": return "Error"
            default: return "Downloaded, asleep until used"
            }
        }
    }

    private struct Health: Decodable {
        struct WriterEntry: Decodable {
            let id: String
            let status: String
            let downloaded: Bool?
            let error: String?
            let modelBytes: Int64?
            let peakMemoryBytes: Int64?
            let lastTokensPerSecond: Double?
        }

        struct LLM: Decodable {
            let available: Bool?
            let loadedModel: String?
            let path: String?
            let sizeBytes: Int64?
            let error: String?
        }

        struct EngineEntry: Decodable {
            let id: String
            let status: String
            let downloaded: Bool?
            let backend: String?
            let device: String?
            let error: String?
            let modelPath: String?
            let modelBytes: Int64?
            let transcriptions: Int?
            let lastProcessingMs: Int?
        }

        let service: String?
        let defaultEngine: String?
        let engines: [EngineEntry]?
        let workerPid: Int32?
        let sleeping: Bool?
        let idleMinutes: Double?
        let workerError: String?
        let status: String
        let backend: String?
        let error: String?
        let pid: Int32?
        let host: String?
        let port: Int?
        let offline: Bool?
        let device: String?
        let modelPath: String?
        let modelBytes: Int64?
        let transcriptions: Int?
        let lastProcessingMs: Int?
        let llm: LLM?
        let llms: [WriterEntry]?
        let mlxLmVersion: String?
    }

    /// Live facts that show the engine runs on this Mac.
    struct Details: Equatable {
        var pid: Int32?
        var workerPid: Int32?
        var sleeping = false
        var workerError: String?
        var host = "127.0.0.1"
        var port = 0
        var offline = false
        var device: String?
        var modelPath: String?
        var modelBytes: Int64?
        var llmPath: String?
        var llmBytes: Int64?
        var transcriptions = 0
        var lastProcessingMs: Int?
        /// The engine's mlx-lm package, which runs the language models.
        var mlxLMVersion: String?
        /// Gateway plus model worker (the worker only exists while models are in memory).
        var memoryBytes: UInt64?

        var isLoopbackOnly: Bool {
            host == "127.0.0.1" || host == "localhost" || host == "::1"
        }
    }

    @Published private(set) var state: State
    @Published private(set) var engines: [SpeechEngine: EngineInfo] = [:]
    @Published private(set) var installProgress: Double = 0
    @Published private(set) var installStatus = ""
    @Published private(set) var installLog: [String] = []
    /// The engine whose model is being downloaded, if any (progress in installProgress and installStatus).
    @Published private(set) var downloading: SpeechEngine?
    @Published private(set) var downloadErrors: [SpeechEngine: String] = [:]
    /// The language models for AI writing, as the engine reports them.
    @Published private(set) var llms: [WritingModel: LLMInfo] = [:]
    /// The language model being downloaded, if any (progress in installProgress and installStatus).
    @Published private(set) var downloadingModel: WritingModel?
    @Published private(set) var modelDownloadErrors: [WritingModel: String] = [:]
    /// The small cleanup model is being downloaded.
    @Published private(set) var downloadingCleanup = false
    @Published private(set) var cleanupDownloadError: String?
    @Published private(set) var llmAvailable = false
    @Published private(set) var llmLoaded: String?
    @Published private(set) var details: Details?

    private let settings: AppSettings
    private var process: Process?
    private var logHandle: FileHandle?
    private var installer: Process?
    private var pollTask: Task<Void, Never>?
    private var stopping = false
    private var synced = false
    private var postingIdle = false
    private var pendingOutput = Data()

    init(settings: AppSettings) {
        self.settings = settings
        state = .stopped
        if !isInstalled { state = .notInstalled }
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: Paths.enginePython.path) && fm.fileExists(atPath: Paths.engineMarker.path)
    }

    /// The engine process answers on its port.
    var isRunning: Bool { details != nil }

    /// True while the installer or a model download runs.
    var isBusy: Bool { installer != nil }

    var baseURL: URL { settings.engineBaseURL }
    var chatBaseURL: URL { settings.engineBaseURL.appendingPathComponent("v1") }

    /// Root of one engine's OpenAI-compatible API, for example http://127.0.0.1:7861/audar
    func baseURL(for engine: SpeechEngine) -> URL {
        settings.engineBaseURL.appendingPathComponent(engine.rawValue)
    }

    /// Root of one language model's OpenAI-compatible API, for example http://127.0.0.1:7861/gemma
    func baseURL(for model: WritingModel) -> URL {
        settings.engineBaseURL.appendingPathComponent(model.rawValue)
    }

    /// The model is on this Mac: what the engine reports, or the download folder while the
    /// engine is not running.
    func isDownloaded(_ model: WritingModel) -> Bool {
        llms[model]?.downloaded ?? Self.isDownloaded(settings.model(for: model))
    }

    func isDownloaded(_ engine: SpeechEngine) -> Bool {
        engines[engine]?.downloaded ?? Self.isDownloaded(settings.model(for: engine))
    }

    var cleanupModelDownloaded: Bool {
        isRunning ? llmAvailable : Self.isDownloaded(settings.localLLMModel)
    }

    /// Gemma 4 needs mlx-lm 0.32 or newer: an engine installed before that has to be updated
    /// (Reinstall / update keeps the models that are downloaded).
    var gemmaNeedsEngineUpdate: Bool {
        guard let version = details?.mlxLMVersion else { return false }
        let parts = version.split(separator: ".").prefix(2).map { Int($0.prefix { $0.isNumber }) ?? 0 }
        guard parts.count == 2 else { return false }
        return parts[0] == 0 && parts[1] < 32
    }

    /// Memory of the models process right now (the speech or language model in use).
    var modelsMemory: UInt64? {
        details?.workerPid.flatMap { ProcessMemory.footprint(pid: $0) }
    }

    // MARK: Lifecycle

    func startIfInstalled() {
        if isInstalled { start() }
    }

    func start() {
        guard isInstalled else {
            state = .notInstalled
            return
        }
        if state == .installing || process?.isRunning == true { return }
        state = .starting
        stopping = false
        synced = false
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Reuse an engine that is already listening on the port (for example one started by hand),
            // unless it is an older version that does not know every speech engine and language model.
            let existing = await self.fetchHealth()
            guard !Task.isCancelled, !self.stopping else { return }
            if let health = existing, health.service == "navo-engine" {
                let known = Set((health.engines ?? []).map(\.id))
                let writers = Set((health.llms ?? []).map(\.id))
                if SpeechEngine.allCases.allSatisfy({ known.contains($0.rawValue) }),
                   WritingModel.allCases.allSatisfy({ writers.contains($0.rawValue) }) {
                    self.apply(health)
                    self.poll()
                    return
                }
                await self.replaceOutdatedEngine(pid: health.pid)
                guard !Task.isCancelled, !self.stopping else { return }
            }
            do {
                try self.launch()
            } catch {
                self.state = .failed("Could not start the engine: \(error.localizedDescription)")
                return
            }
            self.poll()
        }
    }

    func stop() {
        stopping = true
        engines = [:]
        llms = [:]
        pollTask?.cancel()
        pollTask = nil
        if let process, process.isRunning {
            process.terminate()
        } else if process == nil, let pid = details?.pid, pid > 1 {
            kill(pid, SIGTERM) // an engine Navo reused instead of launching
        }
        details = nil
        process = nil
        if state != .installing {
            state = isInstalled ? .stopped : .notInstalled
        }
    }

    func restart() {
        let old = process
        stop()
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Let the old engine exit and free the port before a new one starts.
            for _ in 0..<50 {
                let busy: Bool
                if old?.isRunning == true {
                    busy = true
                } else {
                    busy = await self.fetchHealth() != nil
                }
                if !busy { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self.start()
        }
    }

    /// Waits for the dictation engine to finish loading (first launch after install can take a while).
    func waitUntilReady(timeout: TimeInterval) async -> Bool {
        // A sleeping engine loads the model for the request itself.
        if state.canDictate { return true }
        switch state {
        case .notInstalled, .installing, .failed:
            return false
        case .stopped:
            start()
        default:
            break
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            switch state {
            case .ready, .sleeping:
                return true
            case .starting, .loading:
                continue
            default:
                return false // stopped, installing or failed while waiting
            }
        }
        return false
    }

    /// An engine from an earlier Navo version is listening on the port: stop it so the new one can start.
    private func replaceOutdatedEngine(pid: Int32?) async {
        guard let pid, pid > 1 else { return }
        kill(pid, SIGTERM)
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if await fetchHealth() == nil { return }
        }
    }

    private func launch() throws {
        guard let source = Paths.engineSource else {
            throw EngineError(message: "Engine files are missing from the app bundle")
        }
        let process = Process()
        process.executableURL = Paths.enginePython
        var arguments = [
            "-m", "navo_engine",
            "--port", "\(settings.enginePort)",
            "--engines", settings.enabledEngines.map(\.rawValue).joined(separator: ","),
            "--default-engine", settings.dictationEngine.rawValue,
            "--asr-model", settings.asrModel,
            "--audar-model", settings.audarModel,
            "--whisper-model", settings.whisperModel,
            "--qwen3-model", settings.qwen3Model,
            "--llm-model", settings.localLLMModel,
            "--gemma-model", settings.gemmaModel,
            "--llama-model", settings.llamaModel,
            "--idle-minutes", "\(settings.idleMinutes)",
            "--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)",
        ]
        if settings.cleanupMode != .local {
            arguments.append("--no-preload-llm")
        }
        process.arguments = arguments
        process.environment = engineEnvironment(source: source)

        FileManager.default.createFile(atPath: Paths.engineLog.path, contents: nil)
        let log = try FileHandle(forWritingTo: Paths.engineLog)
        try? logHandle?.close()
        logHandle = log
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let id = ObjectIdentifier(finished)
            guard let self else { return }
            Task { @MainActor in
                self.engineExited(id: id, status: status)
            }
        }
        try process.run()
        self.process = process
        synced = true // the launch arguments already match the settings
    }

    private func engineEnvironment(source: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = source.path
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HUB_OFFLINE"] = "1"
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        return environment
    }

    private func engineExited(id: ObjectIdentifier, status: Int32) {
        // Only the current engine counts: an old one from before a restart may exit late.
        guard let process, ObjectIdentifier(process) == id else { return }
        self.process = nil
        guard !stopping, state != .installing else { return }
        pollTask?.cancel()
        details = nil
        engines = [:]
        llms = [:]
        state = .failed("The engine stopped (exit code \(status)). Open the engine log for details.")
    }

    private func poll() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            var misses = 0
            while !Task.isCancelled {
                guard let self else { return }
                let health = await self.fetchHealth()
                if Task.isCancelled { return }
                if let health {
                    misses = 0
                    self.apply(health)
                    if !self.synced {
                        self.synced = true
                        await self.syncEngines()
                    }
                } else {
                    misses += 1
                    if self.process == nil && misses >= 5 {
                        if case .failed = self.state {} else {
                            self.state = .failed("The engine is not responding")
                        }
                        return
                    }
                }
                let busy = !self.state.canDictate || self.isBusy
                    || self.engines.values.contains { $0.status == "loading" }
                    || self.llms.values.contains { $0.inMemory }
                try? await Task.sleep(nanoseconds: busy ? 1_000_000_000 : 5_000_000_000)
            }
        }
    }

    /// Brings an engine process that Navo did not start in line with the settings: turning off
    /// comes first, so the engines that should be on always fit in the limit of two.
    private func syncEngines() async {
        for engine in SpeechEngine.allCases where !settings.isEnabled(engine) {
            await control("disable", engine)
        }
        for engine in settings.enabledEngines {
            await control("enable", engine)
        }
        await control("default", settings.dictationEngine)
        await postSleepSetting()
        await refresh()
    }

    private func apply(_ health: Health) {
        // A reply that was already on its way when the engine was stopped or reinstalled.
        guard !stopping, state != .installing else { return }
        llmAvailable = health.llm?.available ?? false
        llmLoaded = health.llm?.loadedModel

        var infos: [SpeechEngine: EngineInfo] = [:]
        for entry in health.engines ?? [] {
            guard let engine = SpeechEngine(rawValue: entry.id) else { continue }
            infos[engine] = EngineInfo(
                status: entry.status,
                downloaded: entry.downloaded ?? true,
                backend: entry.backend,
                device: entry.device,
                error: entry.error,
                modelPath: entry.modelPath,
                modelBytes: entry.modelBytes,
                transcriptions: entry.transcriptions ?? 0,
                lastProcessingMs: entry.lastProcessingMs
            )
        }
        if infos != engines { engines = infos }

        var writers: [WritingModel: LLMInfo] = [:]
        for entry in health.llms ?? [] {
            guard let model = WritingModel(rawValue: entry.id) else { continue }
            writers[model] = LLMInfo(
                status: entry.status,
                downloaded: entry.downloaded ?? false,
                error: entry.error,
                modelBytes: entry.modelBytes,
                peakMemoryBytes: entry.peakMemoryBytes,
                tokensPerSecond: entry.lastTokensPerSecond
            )
        }
        if writers != llms { llms = writers }

        let dictation = infos[settings.dictationEngine]
        let pid = health.pid ?? process?.processIdentifier
        let memory: UInt64? = pid.flatMap { gateway in
            let own = ProcessMemory.footprint(pid: gateway) ?? 0
            let worker = health.workerPid.flatMap { ProcessMemory.footprint(pid: $0) } ?? 0
            return own + worker
        }
        let next = Details(
            pid: pid,
            workerPid: health.workerPid,
            sleeping: health.sleeping ?? false,
            workerError: health.workerError,
            host: health.host ?? "127.0.0.1",
            port: health.port ?? settings.enginePort,
            offline: health.offline ?? false,
            device: dictation?.device ?? health.device,
            modelPath: dictation?.modelPath,
            modelBytes: dictation?.modelBytes,
            llmPath: health.llm?.path,
            llmBytes: health.llm?.sizeBytes,
            transcriptions: health.transcriptions ?? 0,
            lastProcessingMs: dictation?.lastProcessingMs,
            mlxLMVersion: health.mlxLmVersion,
            memoryBytes: memory
        )
        if next != details { details = next }

        // A change made while the engine was starting did not reach it yet.
        if let remote = health.idleMinutes, Int(remote) != settings.idleMinutes, !postingIdle {
            postingIdle = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.postSleepSetting()
                self.postingIdle = false
            }
        }

        guard let dictation else {
            state = .loading
            return
        }
        switch dictation.status {
        case "ready":
            state = .ready(backend: dictation.backend ?? "local")
        case "asleep":
            state = dictation.downloaded
                ? .sleeping
                : .failed("\(settings.dictationEngine.title) is not downloaded yet. Download it in Settings > Speech engines.")
        case "error":
            state = .failed(dictation.error ?? "\(settings.dictationEngine.title) failed to load")
        default: // loading, or off until the enable request arrives
            state = .loading
        }
    }

    private func fetchHealth() async -> Health? {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 3
        guard let result = try? await URLSession.shared.data(for: request) else { return nil }
        guard (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Health.self, from: result.0)
    }

    private func refresh() async {
        if let health = await fetchHealth() {
            apply(health)
        }
    }

    /// POST /v1/engines/{engine}/{load|unload|default}
    @discardableResult
    private func control(_ action: String, _ engine: SpeechEngine) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/engines/\(engine.rawValue)/\(action)"))
        request.httpMethod = "POST"
        switch action {
        case "load": request.timeoutInterval = 200 // may start the model worker first
        case "unload", "disable": request.timeoutInterval = 60 // waits for requests already queued
        default: request.timeoutInterval = 5
        }
        guard let result = try? await URLSession.shared.data(for: request) else { return false }
        return (result.1 as? HTTPURLResponse)?.statusCode == 200
    }

    /// POST a path on the engine, optionally with a JSON body.
    @discardableResult
    private func post(_ path: String, json: [String: Any]? = nil, timeout: TimeInterval = 5) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        if let json, let body = try? JSONSerialization.data(withJSONObject: json) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        guard let result = try? await URLSession.shared.data(for: request) else { return false }
        return (result.1 as? HTTPURLResponse)?.statusCode == 200
    }

    private func postSleepSetting() async {
        await post("v1/sleep", json: ["idle_minutes": settings.idleMinutes])
    }

    // MARK: Sleep and wake

    /// Starts loading an engine (the dictation engine unless named) and the cleanup model,
    /// for example while the user is still talking or as a meeting starts.
    func wake(_ speech: SpeechEngine? = nil, cleanup: Bool = false) {
        let engine = speech ?? settings.dictationEngine
        let speechAsleep = state == .sleeping || engines[engine]?.status == "asleep"
        let cleanupAsleep = cleanup && llmAvailable && llmLoaded == nil
        guard isRunning, speechAsleep || cleanupAsleep else { return }
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/wake"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "engine", value: engine.rawValue),
            URLQueryItem(name: "cleanup", value: cleanup ? "true" : "false"),
        ]
        guard let url = components?.url else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 200 // includes starting the model worker
            _ = try? await URLSession.shared.data(for: request)
            await self.refresh()
        }
    }

    /// Minutes without use before models leave memory (0 keeps them loaded).
    func setIdleMinutes(_ minutes: Int) {
        settings.idleMinutes = max(0, minutes)
        guard isRunning else { return }
        let keepLoaded = settings.idleMinutes == 0
        let enabled = settings.enabledEngines
        let cleanup = settings.cleanupMode == .local
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.postSleepSetting()
            if keepLoaded {
                // "Never" means loaded now and kept loaded.
                for engine in enabled {
                    await self.control("load", engine)
                }
                if cleanup {
                    await self.post("v1/cleanup/load", timeout: 200)
                }
            }
            await self.refresh()
        }
    }

    /// Unloads every model now and stops the model worker.
    func freeMemoryNow() {
        guard isRunning else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.post("v1/sleep/now", timeout: 30)
            await self.refresh()
        }
    }

    // MARK: Language models (AI writing)

    /// Frees the language model now (the AI panel closed). With "keep models loaded", the speech
    /// engines that made room for it load again.
    func unloadWritingModels() {
        guard isRunning else { return }
        let reload = settings.idleMinutes == 0 ? settings.enabledEngines : []
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.post("v1/llms/unload", timeout: 60) // waits for an answer still being written
            for engine in reload {
                await self.control("load", engine)
            }
            await self.refresh()
        }
    }

    /// Downloads a language model into the Hugging Face cache. Public models: no token needed.
    func download(_ model: WritingModel) {
        guard installer == nil, isInstalled else { return }
        downloadingModel = model
        modelDownloadErrors[model] = nil
        runDownload(model: settings.model(for: model), label: "Downloading \(model.shortName)", token: nil) { [weak self] status in
            guard let self else { return }
            self.downloadingModel = nil
            if status == 0 {
                self.installProgress = 1
                self.installStatus = "\(model.shortName) downloaded"
                self.refreshSoon()
            } else {
                self.modelDownloadErrors[model] = self.lastInstallProblem(status)
                self.installStatus = "Download failed"
            }
        }
    }

    /// Downloads the small cleanup model (it normally comes with Install).
    func downloadCleanupModel() {
        guard installer == nil, isInstalled else { return }
        downloadingCleanup = true
        cleanupDownloadError = nil
        runDownload(model: settings.localLLMModel, label: "Downloading the cleanup model", token: nil) { [weak self] status in
            guard let self else { return }
            self.downloadingCleanup = false
            if status == 0 {
                self.installProgress = 1
                self.installStatus = "Cleanup model downloaded"
                self.refreshSoon()
            } else {
                self.cleanupDownloadError = self.lastInstallProblem(status)
                self.installStatus = "Download failed"
            }
        }
    }

    private func runDownload(model: String, label: String, token: String?, onExit: @escaping @MainActor (Int32) -> Void) {
        guard let source = Paths.engineSource else {
            onExit(-1)
            return
        }
        resetInstallOutput(status: "Starting download")
        var environment = engineEnvironment(source: source)
        environment["HF_HUB_OFFLINE"] = "0"
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            environment["HF_TOKEN"] = token
        }
        runTool(
            executable: Paths.enginePython,
            arguments: ["-m", "navo_engine.download", "--model", model, "--label", label],
            environment: environment,
            onExit: onExit
        )
    }

    private func lastInstallProblem(_ status: Int32) -> String {
        installLog.last(where: { $0.hasPrefix("ERROR") }) ?? installLog.last ?? "exit code \(status)"
    }

    /// After a download: the engine sees the new model on its next report.
    private func refreshSoon() {
        if isRunning {
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        } else {
            startIfInstalled()
        }
    }

    // MARK: Engines

    /// Turns an engine on (it loads when used) or off (frees its memory and refuses requests).
    /// The dictation engine stays on, and at most two engines are on at once.
    func setEnabled(_ engine: SpeechEngine, _ enabled: Bool) {
        guard enabled || engine != settings.dictationEngine else { return }
        guard !enabled || settings.canEnable(engine) else { return }
        settings.setEnabled(engine, enabled)
        guard isRunning else { return }
        let keepLoaded = settings.idleMinutes == 0
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.control(enabled ? (keepLoaded ? "load" : "enable") : "disable", engine)
            await self.refresh()
        }
    }

    /// Makes an engine the one that transcribes dictation (it is turned on if it was off, when
    /// there is room). The old dictation engine stays on only if its own switch is on.
    func useForDictation(_ engine: SpeechEngine) {
        guard engine != settings.dictationEngine, settings.canUseForDictation(engine) else { return }
        let previous = settings.dictationEngine
        settings.dictationEngine = engine
        settings.setEnabled(engine, true)
        let previousOff = !settings.isEnabled(previous)
        guard isRunning else {
            startIfInstalled()
            return
        }
        let keepLoaded = settings.idleMinutes == 0
        if keepLoaded, let info = engines[engine], !info.isReady {
            state = .loading
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if previousOff {
                await self.control("disable", previous) // first, to make room
            }
            await self.control(keepLoaded ? "load" : "enable", engine)
            await self.control("default", engine)
            await self.refresh()
        }
    }

    /// Downloads one engine's model into the Hugging Face cache, then turns the engine on.
    func download(_ engine: SpeechEngine, huggingFaceToken: String?) {
        guard installer == nil, isInstalled else { return }
        downloading = engine
        downloadErrors[engine] = nil
        runDownload(model: settings.model(for: engine), label: "Downloading \(engine.shortName)", token: huggingFaceToken) { [weak self] status in
            self?.downloadFinished(engine, status: status)
        }
    }

    private func downloadFinished(_ engine: SpeechEngine, status: Int32) {
        downloading = nil
        guard status == 0 else {
            downloadErrors[engine] = lastInstallProblem(status)
            installStatus = "Download failed"
            return
        }
        installProgress = 1
        guard settings.canEnable(engine) else {
            // Two others are on: it stays off until one of them is turned off.
            installStatus = "\(engine.shortName) downloaded. \(settings.enabledEnginesText) are on: turn one of them off to use it."
            return
        }
        installStatus = "\(engine.shortName) downloaded"
        settings.setEnabled(engine, true)
        if isRunning {
            let keepLoaded = settings.idleMinutes == 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.control(keepLoaded ? "load" : "enable", engine)
                await self.refresh()
            }
        } else {
            startIfInstalled()
        }
    }

    // MARK: Install

    func install(huggingFaceToken: String?) {
        guard installer == nil else { return }
        guard let source = Paths.engineSource else {
            state = .failed("Engine files are missing from the app bundle")
            return
        }
        stop()
        state = .installing
        resetInstallOutput(status: "Starting installer")

        let token = huggingFaceToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if token.isEmpty {
            useOnlyPublicEngines()
        }

        var environment = ProcessInfo.processInfo.environment
        environment["NAVO_SUPPORT_DIR"] = Paths.supportDir.path
        environment["NAVO_ASR_MODELS"] = settings.enabledEngines.map { settings.model(for: $0) }.joined(separator: " ")
        if settings.cleanupMode == .local {
            environment["NAVO_LLM_MODEL"] = settings.localLLMModel
        } else {
            environment["NAVO_SKIP_LLM"] = "1"
        }
        if !token.isEmpty {
            environment["HF_TOKEN"] = token
        }
        runTool(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [source.appendingPathComponent("setup-engine.sh").path],
            environment: environment
        ) { [weak self] status in
            self?.installFinished(status: status)
        }
    }

    /// Without a Hugging Face token a gated model (Cohere) can't be downloaded, so a first install
    /// with no token sets Navo up with Audar, which is public: it works right away, and Cohere can
    /// be downloaded later from Settings with a token. A token saved by an earlier download, or
    /// a Cohere model already on this Mac, keeps the choice as it is.
    private func useOnlyPublicEngines() {
        let gated = settings.enabledEngines.filter(\.isGated)
        guard !gated.isEmpty, !Self.hasSavedHuggingFaceToken,
              !gated.allSatisfy({ Self.isDownloaded(settings.model(for: $0)) })
        else { return }
        if settings.dictationEngine.isGated {
            settings.dictationEngine = .audar
        }
        if settings.jobEngine.isGated {
            settings.jobEngine = .audar
        }
        for engine in gated where engine != settings.dictationEngine {
            settings.setEnabled(engine, false)
        }
        if settings.canEnable(.audar) {
            settings.setEnabled(.audar, true)
        }
        installLog.append("No Hugging Face token: installing Audar, which needs none. To add Cohere later, paste a token in Settings and click Download next to it.")
    }

    /// The Hugging Face cache, where models are downloaded.
    private static var huggingFaceHome: URL {
        if let custom = ProcessInfo.processInfo.environment["HF_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface", isDirectory: true)
    }

    private static var hasSavedHuggingFaceToken: Bool {
        let path = huggingFaceHome.appendingPathComponent("token").path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 0
    }

    /// A model folder on disk, or a Hugging Face id with a snapshot in the cache.
    private static func isDownloaded(_ model: String) -> Bool {
        let local = (model as NSString).expandingTildeInPath
        if local.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: local + "/config.json")
        }
        let folder = "models--" + model.replacingOccurrences(of: "/", with: "--")
        let snapshots = huggingFaceHome.appendingPathComponent("hub/\(folder)/snapshots").path
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: snapshots)) ?? []
        return !versions.isEmpty
    }

    private func installFinished(status: Int32) {
        if status == 0 && isInstalled {
            installProgress = 1
            installStatus = "Installed"
            state = .stopped
            start()
        } else {
            let reason = installLog.last(where: { $0.hasPrefix("ERROR") }) ?? installLog.last ?? "exit code \(status)"
            installStatus = "Install failed"
            state = .failed("Install failed: \(reason)")
        }
    }

    // MARK: Installer and downloader output

    private func resetInstallOutput(status: String) {
        installProgress = 0
        installStatus = status
        installLog = []
        pendingOutput = Data()
    }

    /// Runs a helper (installer or downloader) and streams its output into installLog.
    private func runTool(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onExit: @escaping @MainActor (Int32) -> Void
    ) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil // end of output
                return
            }
            guard let self else { return }
            Task { @MainActor in
                self.consume(data)
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            guard let self else { return }
            Task { @MainActor in
                // Give the last lines (often the ERROR that explains a failure) time to arrive.
                try? await Task.sleep(nanoseconds: 300_000_000)
                pipe.fileHandleForReading.readabilityHandler = nil
                self.flushPendingOutput()
                self.installer = nil
                onExit(status)
            }
        }

        do {
            try process.run()
            installer = process
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            appendLog("ERROR: could not start \(executable.lastPathComponent): \(error.localizedDescription)")
            onExit(-1)
        }
    }

    private func flushPendingOutput() {
        let line = String(decoding: pendingOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        pendingOutput = Data()
        if !line.isEmpty { handleInstallLine(line) }
    }

    private func consume(_ data: Data) {
        pendingOutput.append(data)
        while let index = pendingOutput.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = pendingOutput.subdata(in: pendingOutput.startIndex..<index)
            pendingOutput.removeSubrange(pendingOutput.startIndex...index)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            handleInstallLine(line)
        }
    }

    private func handleInstallLine(_ line: String) {
        let marker = "NAVO_PROGRESS "
        if line.hasPrefix(marker) {
            let parts = line.dropFirst(marker.count).split(separator: " ", maxSplits: 1)
            if let first = parts.first, let value = Double(first) {
                installProgress = max(installProgress, value)
            }
            if parts.count > 1 {
                let status = String(parts[1])
                // Keep one log line per step, not one per progress tick.
                let stepName = status.split(separator: " ").prefix(3).joined(separator: " ")
                if !installStatus.hasPrefix(stepName) {
                    appendLog("▸ " + status)
                }
                installStatus = status
            }
            return
        }
        appendLog(line)
    }

    private func appendLog(_ line: String) {
        installLog.append(line)
        if installLog.count > 400 {
            installLog.removeFirst(installLog.count - 400)
        }
    }

    func openLog() {
        NSWorkspace.shared.open(Paths.engineLog)
    }
}
