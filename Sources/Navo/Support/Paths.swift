import Foundation

/// Every location Navo reads or writes.
enum Paths {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Paths.ensure(base.appendingPathComponent("Navo", isDirectory: true))
    }()

    /// Started with `--demo` (scripts/demo.sh): Navo shows made-up sample data instead of your
    /// own, for screenshots and demos. The history, the recordings and the clipboard then live in
    /// a folder of their own that is filled again on every start. The engine and its models are shared.
    static let isDemo = CommandLine.arguments.contains("--demo")

    /// Where the history, the recordings and the clipboard are kept.
    static let dataDir: URL = {
        guard isDemo else { return supportDir }
        return Paths.ensure(supportDir.appendingPathComponent("Demo", isDirectory: true))
    }()

    static var database: URL { dataDir.appendingPathComponent("navo.sqlite") }
    static var audioDir: URL { ensure(dataDir.appendingPathComponent("Audio", isDirectory: true)) }
    /// Meeting recordings and imported files, one folder per session (kept apart from dictation audio).
    static var sessionsDir: URL { ensure(dataDir.appendingPathComponent("Sessions", isDirectory: true)) }

    static func sessionDir(_ id: String) -> URL {
        ensure(sessionsDir.appendingPathComponent(id, isDirectory: true))
    }
    /// Audio handed to Navo from the Share menu (the share extension writes here) or a paste,
    /// waiting to be moved into Files.
    static var inboxDir: URL { ensure(dataDir.appendingPathComponent("Inbox", isDirectory: true)) }
    static var logsDir: URL { ensure(supportDir.appendingPathComponent("Logs", isDirectory: true)) }
    static var engineLog: URL { logsDir.appendingPathComponent("engine.log") }

    static var engineHome: URL { supportDir.appendingPathComponent("engine", isDirectory: true) }
    static var enginePython: URL { engineHome.appendingPathComponent("venv/bin/python") }
    static var engineMarker: URL { engineHome.appendingPathComponent("installed.json") }

    /// Engine sources: bundled at Navo.app/Contents/Resources/engine, or NAVO_ENGINE_DIR during development.
    static var engineSource: URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["NAVO_ENGINE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("engine", isDirectory: true),
           fm.fileExists(atPath: bundled.appendingPathComponent("navo_engine").path) {
            return bundled
        }
        return nil
    }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
