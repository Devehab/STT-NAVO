import AppKit
import UniformTypeIdentifiers

/// "Navo" in the Share menu of Voice Memos, Finder and other apps: copies the shared audio into
/// Navo's inbox and opens Navo, which moves it into Files and transcribes it.
///
/// App extensions run sandboxed; this one may write only to
/// ~/Library/Application Support/Navo/Inbox (see NavoShare.entitlements).
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    private let status = NSTextField(wrappingLabelWithString: "Sending to Navo…")
    private let spinner = NSProgressIndicator()
    private var started = false
    private var finished = false

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 110))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 20, y: 46, width: 18, height: 18)
        spinner.startAnimation(nil)
        status.frame = NSRect(x: 48, y: 14, width: 276, height: 82)
        status.maximumNumberOfLines = 5
        root.addSubview(spinner)
        root.addSubview(status)
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started else { return }
        started = true
        receive()
    }

    private func receive() {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let inbox = Self.inbox()
        // An app that never hands the audio over must not leave the sheet spinning.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            MainActor.assumeIsolated {
                self?.finish(saved: 0, problem: "the app did not hand the recording over in time", offered: [])
            }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            var saved = 0
            var problem: String?
            var offered: [String] = []
            do {
                try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            } catch {
                problem = error.localizedDescription
            }
            for provider in providers {
                offered += provider.registeredTypeIdentifiers
                do {
                    try await ShareReceiver.save(provider, into: inbox)
                    saved += 1
                } catch {
                    problem = error.localizedDescription
                }
            }
            let result = (saved, problem, offered)
            await MainActor.run {
                self?.finish(saved: result.0, problem: result.1, offered: result.2)
            }
        }
    }

    private func finish(saved: Int, problem: String?, offered: [String]) {
        guard !finished else { return }
        finished = true
        spinner.stopAnimation(nil)
        guard saved > 0 else {
            var message = "Navo could not get the audio"
            if let problem { message += ": \(problem)" }
            if !offered.isEmpty {
                message += ". Offered: " + Array(Set(offered)).sorted().joined(separator: ", ")
            }
            status.stringValue = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                MainActor.assumeIsolated {
                    self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                }
            }
            return
        }
        status.stringValue = saved == 1 ? "Sent to Navo." : "\(saved) recordings sent to Navo."
        if let url = URL(string: "navo://import") {
            NSWorkspace.shared.open(url)
        }
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    /// ~/Library/Application Support/Navo/Inbox in the real home folder, not the sandbox container.
    private static func inbox() -> URL {
        var home = NSHomeDirectory()
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            home = String(cString: directory)
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Navo/Inbox", isDirectory: true)
    }
}

/// Gets one shared item into the inbox, trying every way an app can hand audio over: the file
/// itself, the item for each audio type (a file or its bytes), a file copy, and the raw data.
private enum ShareReceiver {
    struct NothingUsable: LocalizedError {
        var errorDescription: String? { "nothing in the shared item could be read as audio" }
    }

    static func save(_ provider: NSItemProvider, into inbox: URL) async throws {
        let types = provider.registeredTypeIdentifiers
        let audioTypes = types.filter { UTType($0)?.conforms(to: .audio) ?? false }
        let name = provider.suggestedName
        var lastError: Error = NothingUsable()

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            do {
                try await item(provider, type: UTType.fileURL.identifier, name: name, into: inbox)
                return
            } catch {
                lastError = error
            }
        }
        for type in audioTypes {
            for attempt in [item, fileCopy, data] {
                do {
                    try await attempt(provider, type, name, inbox)
                    return
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError
    }

    /// The item as the app registered it: a file URL or the audio bytes.
    private static func item(_ provider: NSItemProvider, type: String, name: String?, into inbox: URL) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            provider.loadItem(forTypeIdentifier: type, options: nil) { @Sendable item, error in
                do {
                    if let error { throw error }
                    if let url = item as? URL ?? (item as? Data).flatMap({ URL(dataRepresentation: $0, relativeTo: nil) }), url.isFileURL {
                        try copy(url, into: inbox, name: name)
                    } else if let data = item as? Data, type != UTType.fileURL.identifier {
                        try write(data, type: type, into: inbox, name: name)
                    } else {
                        throw NothingUsable()
                    }
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// A copy of the file made for this extension, valid only inside the callback.
    private static func fileCopy(_ provider: NSItemProvider, type: String, name: String?, into inbox: URL) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { @Sendable url, error in
                do {
                    guard let url else { throw error ?? NothingUsable() }
                    try copy(url, into: inbox, name: name)
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    private static func data(_ provider: NSItemProvider, type: String, name: String?, into inbox: URL) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { @Sendable data, error in
                do {
                    guard let data, !data.isEmpty else { throw error ?? NothingUsable() }
                    try write(data, type: type, into: inbox, name: name)
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    private static func copy(_ url: URL, into inbox: URL, name: String?) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let base = name ?? url.deletingPathExtension().lastPathComponent
        try place(inbox: inbox, base: base, ext: ext) { partial in
            try FileManager.default.copyItem(at: url, to: partial)
        }
    }

    private static func write(_ data: Data, type: String, into inbox: URL, name: String?) throws {
        let ext = UTType(type)?.preferredFilenameExtension ?? "m4a"
        try place(inbox: inbox, base: name ?? "Shared recording", ext: ext) { partial in
            try data.write(to: partial)
        }
    }

    /// Writes under a hidden name first, so Navo never picks up a half-written file.
    private static func place(inbox: URL, base: String, ext: String, write: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let clean = base.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let stem = clean.isEmpty ? "Shared recording" : clean
        var target = inbox.appendingPathComponent("\(stem).\(ext)")
        var number = 2
        while fm.fileExists(atPath: target.path) {
            target = inbox.appendingPathComponent("\(stem) \(number).\(ext)")
            number += 1
        }
        let partial = inbox.appendingPathComponent(".\(UUID().uuidString).partial")
        do {
            try write(partial)
            try fm.moveItem(at: partial, to: target)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }
}
