import AppKit
import SwiftUI

/// Clipboard tab: the text you copied anywhere on the Mac, to find and copy again.
struct ClipboardView: View {
    @EnvironmentObject private var clipboard: ClipboardStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var quickPaste: QuickPasteController

    @State private var query = ""
    @State private var selection: String?
    @State private var confirmClear = false
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Clipboard")
                        .font(.system(size: 30, weight: .semibold))
                    Text("Text you copy anywhere, in any app, kept on this Mac so you can copy it again. Starred items are never deleted automatically. Passwords from password managers are not kept.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let keys = settings.clipboardShortcut, quickPaste.shortcutProblem == nil {
                        Label("Press \(keys.spelled) in any app for your last 10 copies, and paste one without leaving what you are doing.", systemImage: "command")
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                keepControls
            }

            controls

            if !settings.clipboardHistory {
                Label("Keeping copies is off. Turn it on above or in Settings; what is already here stays.", systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = clipboard.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            browser

            Text(countLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: query) {
            // Searches once typing pauses.
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, clipboard.search != query else { return }
            clipboard.search = query
        }
        .onAppear {
            query = clipboard.search
            clipboard.reload()
        }
        .confirmationDialog("Delete every item that is not starred?", isPresented: $confirmClear) {
            Button("Delete permanently", role: .destructive) {
                clipboard.clearUnstarred()
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(clipboard.total - clipboard.starredTotal) items are erased from this Mac. Starred items stay. This cannot be undone.")
        }
    }

    /// Whether copies are kept, and for how long.
    private var keepControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Toggle("Keep what I copy", isOn: $settings.clipboardHistory)
                .toggleStyle(.switch)
            Picker("Keep for", selection: $settings.clipboardDays) {
                ForEach(AppSettings.clipboardDayChoices, id: \.self) { days in
                    Text(ClipboardView.dayLabel(days)).tag(days)
                }
            }
            .disabled(!settings.clipboardHistory)
        }
        .fixedSize()
    }

    /// Show, search, clear. The buttons keep their full size; the search field gives way.
    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $clipboard.starredOnly) {
                Text("All").tag(false)
                Text("Starred").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            SearchField("Search copies", text: $query)
                .frame(minWidth: 140, maxWidth: 320)
            Spacer(minLength: 8)
            Button {
                confirmClear = true
            } label: {
                Label("Clear…", systemImage: "trash")
            }
            .fixedSize()
            .disabled(clipboard.total == clipboard.starredTotal)
            .help("Delete everything that is not starred")
        }
    }

    static func dayLabel(_ days: Int) -> String {
        switch days {
        case 1: return "1 day"
        case 60: return "2 months"
        case 30: return "1 month"
        case 14: return "2 weeks"
        case 7: return "1 week"
        default: return "\(days) days"
        }
    }

    private var browser: some View {
        HStack(spacing: 0) {
            Group {
                if clipboard.items.isEmpty {
                    VStack {
                        Spacer()
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    clipList
                }
            }
            .frame(minWidth: 230, idealWidth: 330, maxWidth: 360)

            Divider()

            Group {
                if let id = selection, let item = clipboard.items.first(where: { $0.id == id }) {
                    ClipDetail(item: item)
                        .id(item.id)
                } else {
                    VStack {
                        Spacer()
                        Text(clipboard.items.isEmpty ? "" : "Select an item to see all of it.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The copies, drawn only as they scroll into view. Click one to see all of it; the arrow
    /// keys move between them.
    private var clipList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(clipboard.items) { item in
                        ClipRow(item: item, selected: item.id == selection, last: item.id == clipboard.items.last?.id)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = item.id
                                listFocused = true
                            }
                            .contextMenu {
                                Button("Copy") { _ = clipboard.copy(item.id) }
                                Button(item.starred ? "Remove star" : "Star") { clipboard.setStarred(item.id, !item.starred) }
                                Divider()
                                Button("Delete", role: .destructive) { clipboard.delete(item.id) }
                            }
                    }
                }
                .padding(6)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                move(direction, proxy: proxy)
            }
        }
    }

    private func move(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let items = clipboard.items
        guard !items.isEmpty else { return }
        let current = selection.flatMap { id in items.firstIndex { $0.id == id } }
        let next: Int
        switch direction {
        case .up:
            next = max(0, (current ?? 0) - 1)
        case .down:
            next = min(items.count - 1, (current ?? -1) + 1)
        default:
            return
        }
        selection = items[next].id
        proxy.scrollTo(items[next].id)
    }

    private var emptyMessage: String {
        if !query.isEmpty { return "Nothing matches \"\(query)\"." }
        if clipboard.starredOnly { return "No starred items yet. Star an item to keep it for good." }
        return "Copy some text anywhere (⌘C) and it appears here."
    }

    private var countLine: String {
        let shown = clipboard.items.count
        let total = clipboard.total
        let base = "\(total) \(total == 1 ? "item" : "items"), \(clipboard.starredTotal) starred"
        return shown < total && query.isEmpty && !clipboard.starredOnly ? base + ". Newest \(shown) shown; search finds the rest." : base
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let selected: Bool
    /// No line under the last one.
    let last: Bool

    @EnvironmentObject private var clipboard: ClipboardStore
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        let rightToLeft = TextTools.isRightToLeft(item.preview)
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.preview.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 13))
                    .lineLimit(3)
                    .multilineTextAlignment(rightToLeft ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: rightToLeft ? .trailing : .leading)
                HStack(spacing: 6) {
                    // Once a minute is enough for "5 minutes ago".
                    TimelineView(.everyMinute) { _ in
                        Text(item.copiedAt.formatted(.relative(presentation: .named)))
                    }
                    if let app = item.appName {
                        Text(app)
                    }
                    if item.characters > 200 {
                        Text("\(item.characters) characters")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            VStack(spacing: 6) {
                Button {
                    clipboard.setStarred(item.id, !item.starred)
                } label: {
                    Image(systemName: item.starred ? "star.fill" : "star")
                        .foregroundStyle(item.starred ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(item.starred ? "Starred: kept until you delete it" : "Star: keep it for good")
                Button {
                    copied = clipboard.copy(item.id)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy again")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .padding(.vertical, 2)
        // A line between items, so each one stands apart.
        .overlay(alignment: .bottom) {
            if !last {
                Rectangle()
                    .fill(Color.primary.opacity(0.09))
                    .frame(height: 1)
                    .padding(.horizontal, 10)
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct ClipDetail: View {
    let item: ClipItem

    @EnvironmentObject private var clipboard: ClipboardStore
    @State private var lines: [String] = []
    @State private var rightToLeft = false
    @State private var copied = false

    /// Showing a very long text all at once would make the window slow; Copy always takes all of it.
    private static let shownLimit = 50_000

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.appName.map { "Copied in \($0)" } ?? "Copied")
                        .font(.headline)
                    Text("\(item.copiedAt.formatted(date: .abbreviated, time: .shortened)), \(item.characters) characters")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    clipboard.setStarred(item.id, !item.starred)
                } label: {
                    Image(systemName: item.starred ? "star.fill" : "star")
                        .foregroundStyle(item.starred ? Color.yellow : Color.primary)
                }
                .help(item.starred ? "Starred: kept until you delete it. Click to remove the star." : "Star: keep it for good")
                Button(copied ? "Copied" : "Copy") {
                    copied = clipboard.copy(item.id)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive) {
                    clipboard.delete(item.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete permanently")
            }
            ScrollView {
                // Line by line, drawn as they scroll into view: long copies stay quick.
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
                .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            if item.characters > Self.shownLimit {
                Text("Showing the first \(Self.shownLimit) of \(item.characters) characters. Copy takes all of it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .onAppear {
            let full = clipboard.fullText(item.id) ?? item.preview
            let shown = full.count > Self.shownLimit ? String(full.prefix(Self.shownLimit)) : full
            // Character.isNewline counts a Windows line end (CR LF) as one break.
            lines = shown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            rightToLeft = TextTools.isRightToLeft(shown)
        }
    }
}
