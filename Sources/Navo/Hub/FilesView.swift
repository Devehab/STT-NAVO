import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files tab: audio from Voice Memos, another device or a file, turned into text.
struct FilesView: View {
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var settings: AppSettings

    @State private var picking = false
    @State private var dropTargeted = false
    @State private var receiving = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Files")
                        .font(.system(size: 28, weight: .semibold))
                    Text("Voice Memos and other audio, turned into text on this Mac.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if receiving || sessions.importing > 0 {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    paste()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .disabled(receiving)
                .help("Adds the audio you copied (⌘C) in Voice Memos, Finder or another app")
                Button {
                    picking = true
                } label: {
                    Label("Add files", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    TranscriptionOptions()
                    Spacer(minLength: 0)
                    autoToggle
                }
                VStack(alignment: .leading, spacing: 10) {
                    TranscriptionOptions(pieceLabel: nil)
                    HStack(spacing: 20) {
                        OptionField("Text every") { PieceLengthPicker() }
                        autoToggle
                    }
                }
            }

            if let message = notice ?? sessions.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Spacer()
                    if notice != nil {
                        Button {
                            notice = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            SessionBrowser(
                kind: .file,
                emptyTitle: "Drop audio here",
                emptyHint: "Or in Voice Memos use Share > Navo, or copy a recording (⌘C) and click Paste. M4A, WAV, MP3, AAC, FLAC, OGG and Opus, any length."
            )
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        )
                        .overlay(
                            Label("Drop to add", systemImage: "plus.circle.fill")
                                .font(.headline)
                                .foregroundStyle(Color.accentColor)
                        )
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, .audio], isTargeted: $dropTargeted) { providers in
                receiving = true
                PasteboardAudio.read(providers) { found in
                    add(found, pasted: false)
                }
                return true
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fileImporter(isPresented: $picking, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                notice = nil
                sessions.importFiles(urls)
            }
        }
    }

    private var autoToggle: some View {
        Toggle("Start right away", isOn: $settings.autoTranscribeImports)
            .toggleStyle(.checkbox)
            .fixedSize()
    }

    /// Audio, plus OGG and Opus (WhatsApp voice notes), which macOS does not always count as audio.
    private static let importTypes: [UTType] = [.audio]
        + SessionStore.engineOnlyExtensions.sorted().compactMap { UTType(filenameExtension: $0) }

    private func paste() {
        receiving = true
        notice = nil
        PasteboardAudio.read(NSPasteboard.general) { found in
            add(found, pasted: true)
        }
    }

    private func add(_ found: PasteboardAudio.Found, pasted: Bool) {
        receiving = false
        guard !found.isEmpty else {
            notice = PasteboardAudio.nothingFound(found, pasted: pasted)
            return
        }
        notice = nil
        sessions.importFiles(found.files + found.received, owned: Set(found.received))
    }
}
