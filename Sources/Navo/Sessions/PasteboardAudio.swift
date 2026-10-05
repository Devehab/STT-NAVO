import AppKit
import UniformTypeIdentifiers

/// Finds audio on a pasteboard: the clipboard after Copy in Voice Memos or Finder, or a drop.
///
/// Files that already exist on the Mac are only referenced (Files copies them). Audio that
/// exists only on the pasteboard, as a promised file (Voice Memos, Mail) or as raw data, is
/// written to a private folder first, and Files moves it in.
@MainActor
enum PasteboardAudio {
    struct Found {
        /// The user's own files: copied into Navo.
        var files: [URL] = []
        /// Written by Navo from the pasteboard: moved into Navo.
        var received: [URL] = []
        /// What the pasteboard held, to explain when none of it was audio.
        var types: [String] = []
        var problem: String?

        var isEmpty: Bool { files.isEmpty && received.isEmpty }
    }

    /// Reads what it can and calls back on the main actor. Promised files can take a moment.
    static func read(_ pasteboard: NSPasteboard, completion: @escaping @MainActor (Found) -> Void) {
        var found = Found()
        found.types = (pasteboard.types ?? []).map(\.rawValue)

        // 1. Files (Finder, and apps that put the file itself on the pasteboard).
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        found.files = urls.filter { !$0.hasDirectoryPath }
        if !found.files.isEmpty {
            completion(found)
            return
        }

        // 2. Promised files: the source app writes the file when asked (Voice Memos does this).
        let promises = ((pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? [])
            .filter { promise in
                promise.fileTypes.isEmpty || promise.fileTypes.contains { UTType($0)?.conforms(to: .audio) ?? false }
            }
        if !promises.isEmpty, let folder = makeIncomingFolder() {
            receive(promises, into: folder) { received, problem in
                if received.isEmpty {
                    try? FileManager.default.removeItem(at: folder)
                }
                found.received = received
                found.problem = problem
                completion(found)
            }
            return
        }

        // 3. The sound itself as data.
        if let folder = makeIncomingFolder() {
            for (number, item) in (pasteboard.pasteboardItems ?? []).enumerated() {
                guard let type = item.types.first(where: { UTType($0.rawValue)?.conforms(to: .audio) ?? false }),
                      let data = item.data(forType: type)
                else { continue }
                let ext = UTType(type.rawValue)?.preferredFilenameExtension ?? "m4a"
                let url = folder.appendingPathComponent("Pasted audio \(number + 1).\(ext)")
                do {
                    try data.write(to: url)
                    found.received.append(url)
                } catch {
                    found.problem = error.localizedDescription
                }
            }
            if found.received.isEmpty {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        completion(found)
    }

    /// Reads a SwiftUI drop: file URLs, or audio the source app hands over as a file.
    static func read(_ providers: [NSItemProvider], completion: @escaping @MainActor (Found) -> Void) {
        let types = Array(Set(providers.flatMap(\.registeredTypeIdentifiers))).sorted()
        guard let folder = makeIncomingFolder() else {
            completion(Found(types: types))
            return
        }
        let collector = DropCollector()
        let group = DispatchGroup()
        /// Asks the source app for the audio itself (a copy made for us, valid only inside the callback).
        @Sendable func loadAudio(_ provider: NSItemProvider, type: String) {
            provider.loadFileRepresentation(forTypeIdentifier: type) { @Sendable url, error in
                if let url {
                    let copy = folder.appendingPathComponent(url.lastPathComponent)
                    do {
                        try FileManager.default.copyItem(at: url, to: copy)
                        collector.addReceived(copy)
                    } catch {
                        collector.fail(error)
                    }
                } else if let error {
                    collector.fail(error)
                }
                group.leave()
            }
        }

        for provider in providers {
            let audioType = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .audio) ?? false }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in
                    if let url, url.isFileURL {
                        collector.addFile(url)
                        group.leave()
                    } else if let audioType {
                        loadAudio(provider, type: audioType) // a promised file: no URL until it is written
                    } else {
                        group.leave()
                    }
                }
            } else if let audioType {
                group.enter()
                loadAudio(provider, type: audioType)
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let (files, received, problem) = collector.results()
                if received.isEmpty {
                    try? FileManager.default.removeItem(at: folder)
                }
                completion(Found(files: files, received: received, types: types, problem: problem))
            }
        }
    }

    /// A message for a paste or drop that held no audio.
    static func nothingFound(_ found: Found, pasted: Bool) -> String {
        if let problem = found.problem {
            return "Could not get the audio: \(problem)"
        }
        let shown = found.types.filter { !$0.hasPrefix("dyn.") }.prefix(6).joined(separator: ", ")
        let held = shown.isEmpty ? "nothing" : shown
        let source = pasted ? "on the clipboard" : "in what was dropped"
        return "No audio found \(source) (it holds: \(held)). In Voice Memos, use Share > Navo, or drag the recording to Finder first."
    }

    // MARK: Private

    private final class DropCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [URL] = []
        private var received: [URL] = []
        private var problem: String?

        func addFile(_ url: URL) {
            lock.lock()
            files.append(url)
            lock.unlock()
        }

        func addReceived(_ url: URL) {
            lock.lock()
            received.append(url)
            lock.unlock()
        }

        func fail(_ error: Error) {
            lock.lock()
            problem = error.localizedDescription
            lock.unlock()
        }

        func results() -> ([URL], [URL], String?) {
            lock.lock()
            defer { lock.unlock() }
            return (files, received, problem)
        }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        private var problem: String?
        private var remaining: Int
        private var done = false

        init(expected: Int) {
            remaining = expected
        }

        /// Returns the results once, when the last file arrived.
        func add(_ url: URL?, _ error: Error?) -> ([URL], String?)? {
            lock.lock()
            defer { lock.unlock() }
            if let url { urls.append(url) }
            if let error { problem = error.localizedDescription }
            remaining -= 1
            return remaining <= 0 ? finish() : nil
        }

        func timeOut() -> ([URL], String?)? {
            lock.lock()
            defer { lock.unlock() }
            return finish(problem ?? "the app that holds the audio did not hand it over")
        }

        private func finish(_ fallback: String? = nil) -> ([URL], String?)? {
            guard !done else { return nil }
            done = true
            return (urls, urls.isEmpty ? (problem ?? fallback) : nil)
        }
    }

    private static func receive(
        _ promises: [NSFilePromiseReceiver],
        into folder: URL,
        completion: @escaping @MainActor ([URL], String?) -> Void
    ) {
        // fileNames stays empty until the files arrive; fileTypes is known up front.
        let expected = promises.reduce(0) { $0 + max(1, $1.fileTypes.count) }
        let collector = Collector(expected: expected)
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for promise in promises {
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { @Sendable url, error in
                if let result = collector.add(error == nil ? url : nil, error) {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { completion(result.0, result.1) }
                    }
                }
            }
        }
        // A source app that never delivers must not leave the paste hanging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if let result = collector.timeOut() {
                MainActor.assumeIsolated { completion(result.0, result.1) }
            }
        }
    }

    private static func makeIncomingFolder() -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("navo-incoming-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }
}
