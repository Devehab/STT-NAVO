import SwiftUI

// MARK: Transcripts

/// A transcript as one paragraph per piece, drawn lazily: an hour of text stays as quick to
/// scroll, resize and update as a minute of it. Silent pieces are left out.
struct TranscriptView: View {
    let chunks: [SessionChunk]
    var showTimes = false
    /// Text is still arriving: keep the newest paragraph in view.
    var following = false
    var placeholder = ""
    var footer: String?

    private var shown: [SessionChunk] {
        chunks.filter { $0.text == nil || !($0.text ?? "").isEmpty }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if shown.isEmpty && !placeholder.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(shown, id: \.index) { chunk in
                        TranscriptParagraph(chunk: chunk, showTime: showTimes)
                    }
                    if let footer, !footer.isEmpty {
                        Text(footer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.endID)
                }
                .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            .onAppear {
                if following { proxy.scrollTo(Self.endID, anchor: .bottom) }
            }
            .onChange(of: chunks.count) { _, _ in
                guard following else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.endID, anchor: .bottom)
                }
            }
        }
    }

    private static let endID = "transcript-end"
}

private struct TranscriptParagraph: View {
    let chunk: SessionChunk
    let showTime: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if showTime {
                Text(SessionStore.clock(chunk.start))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
            }
            if let text = chunk.text {
                Text(text)
                    .font(.system(size: 14.5))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, TextTools.isRightToLeft(text) ? .rightToLeft : .leftToRight)
            } else {
                Text("This part could not be transcribed (\(chunk.error ?? "unknown error")). Continue tries it again.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: Long text in lists

/// Shows the first lines of a text with More to open the rest, so one long item does not
/// take over a list. Clicking the shortened text opens it too.
struct ExpandableText: View {
    let text: String
    var lines = 3
    var font: Font = .system(size: 14.5)
    var selectable = true

    @State private var expanded = false
    @State private var truncated = false

    private var rightToLeft: Bool { TextTools.isRightToLeft(text) }
    /// Short single lines never need checking.
    private var mayBeLong: Bool { text.count > 110 || text.contains("\n") }
    private var shortened: Bool { mayBeLong && truncated }

    var body: some View {
        // Leading follows the layout direction set below: the right edge for Arabic.
        VStack(alignment: .leading, spacing: 4) {
            if expanded {
                styled(Text(text))
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(SelectableText(enabled: selectable))
            } else if shortened {
                // Not selectable while shortened: macOS would draw the whole text over what
                // follows. A click opens it instead, and then it can be selected.
                styled(Text(text))
                    .lineLimit(lines)
                    .background(truncationCheck)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle() }
                    .help("Click to see all of it")
            } else {
                styled(Text(text))
                    .lineLimit(lines)
                    .background(truncationCheck)
                    .modifier(SelectableText(enabled: selectable))
            }
            if expanded || shortened {
                Button(expanded ? "Less" : "More", action: toggle)
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
        .onPreferenceChange(TruncatedKey.self) { value in
            // Preferences arrive on the main thread.
            MainActor.assumeIsolated {
                if let value, value != truncated {
                    truncated = value
                }
            }
        }
        .onChange(of: text) { _, _ in
            expanded = false
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.15)) {
            expanded.toggle()
        }
    }

    private func styled(_ view: Text) -> some View {
        view
            .font(font)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Reports whether the whole text is taller than the lines shown: the full text is laid out
    /// hidden at the same width and the two heights are compared.
    @ViewBuilder
    private var truncationCheck: some View {
        if mayBeLong {
            GeometryReader { shown in
                styled(Text(text))
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .background(GeometryReader { full in
                        Color.clear.preference(key: TruncatedKey.self, value: full.size.height > shown.size.height + 1)
                    })
            }
        }
    }
}

private struct SelectableText: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}

private struct TruncatedKey: PreferenceKey {
    static let defaultValue: Bool? = nil
    static func reduce(value: inout Bool?, nextValue: () -> Bool?) {
        value = nextValue() ?? value
    }
}

// MARK: Search

/// A rounded search field with a clear button.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        self._text = text
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

// MARK: Controllers without redrawing

/// Controllers that rows and small views call into without following their changes: the
/// dictation controller publishes the microphone level many times a second, and a page that
/// followed it would be drawn again each time.
struct HubControllers {
    let dictation: DictationController
    let engine: LocalEngineManager
}

private struct HubControllersKey: EnvironmentKey {
    static var defaultValue: HubControllers? { nil }
}

extension EnvironmentValues {
    var hubControllers: HubControllers? {
        get { self[HubControllersKey.self] }
        set { self[HubControllersKey.self] = newValue }
    }
}

// MARK: Small labelled controls

/// A caption next to a compact control, for option rows.
struct OptionField<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
            content
        }
        .fixedSize()
    }
}
