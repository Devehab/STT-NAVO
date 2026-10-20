import AppKit
import SwiftUI

// MARK: Transcripts

/// A transcript, one paragraph per piece with its time, in one text you can select across:
/// drag over as many paragraphs as you like, or ⌘A for all of it, then ⌘C (Select All and Copy
/// are in its right-click menu too, and ⌘F finds a word). Only the paragraphs that changed are
/// drawn again, so an hour of live text stays as quick as a minute, and what you selected stays
/// selected while new text arrives. Silent pieces are left out.
struct TranscriptView: View {
    let chunks: [SessionChunk]
    var showTimes = false
    /// Text is still arriving: keep the newest paragraph in view (unless you scrolled up to read
    /// or selected something).
    var following = false
    var placeholder = ""
    var footer: String?
    /// Live: the text not final yet (sentences just said and the one being said), shown fainter
    /// after the final text. It is replaced by the final text of its stretch.
    var draft: LiveDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TranscriptTextView(blocks: blocks, following: following)
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var blocks: [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        let shown = chunks.filter { $0.text == nil || !($0.text ?? "").isEmpty }
        if shown.isEmpty && (draft?.isEmpty ?? true) && !placeholder.isEmpty {
            blocks.append(TranscriptBlock(text: placeholder, style: .note))
        }
        for chunk in shown {
            let time = showTimes ? SessionStore.clock(chunk.start) : nil
            if let text = chunk.text {
                blocks.append(TranscriptBlock(time: time, text: text, style: .final))
            } else {
                let problem = "This part could not be transcribed (\(chunk.error ?? "unknown error")). Continue tries it again."
                blocks.append(TranscriptBlock(time: time, text: problem, style: .failed))
            }
        }
        if let draft, !draft.isEmpty {
            blocks.append(TranscriptBlock(time: showTimes ? "" : nil, text: draft.text, preview: draft.preview?.text, style: .draft))
        }
        return blocks
    }
}

/// One paragraph of a transcript.
struct TranscriptBlock: Equatable {
    enum Style: Equatable {
        case final
        /// A part that could not be transcribed.
        case failed
        /// Live text not final yet: grey, and the sentence being said fainter still.
        case draft
        /// Placeholder text.
        case note
    }

    /// The left column: "17:19", "" for the live mark, nil for none.
    var time: String?
    var text: String
    /// Live: the sentence being said.
    var preview: String?
    var style: Style
}

/// The transcript's text view (AppKit's, for a selection that crosses paragraphs).
private struct TranscriptTextView: NSViewRepresentable {
    let blocks: [TranscriptBlock]
    let following: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        // TextKit 1: tab stops and right-to-left paragraphs behave as they always have.
        let text = TranscriptNSTextView(usingTextLayoutManager: false)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.textContainerInset = NSSize(width: 9, height: 14) // 14 with the line's own padding
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.layoutManager?.allowsNonContiguousLayout = true
        text.setAccessibilityLabel("Transcript")
        scroll.documentView = text

        context.coordinator.textView = text
        context.coordinator.scrollView = scroll
        context.coordinator.show(blocks, following: following)
        if following {
            // Once it has a size: start at the newest text.
            DispatchQueue.main.async { context.coordinator.scrollToEnd() }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.show(blocks, following: following)
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        private var shown: [TranscriptBlock] = []
        /// Where each paragraph ends in the text (UTF-16).
        private var ends: [Int] = []

        func show(_ blocks: [TranscriptBlock], following: Bool) {
            guard let textView, let storage = textView.textStorage, blocks != shown else { return }
            var same = 0
            while same < min(shown.count, blocks.count), shown[same] == blocks[same] { same += 1 }
            // The last paragraph has no line break after it: it is drawn again when one follows
            // it, or when it becomes the last.
            var from = same
            if from > 0, from == shown.count || from == blocks.count { from -= 1 }
            let start = from == 0 ? 0 : ends[from - 1]

            let tail = NSMutableAttributedString()
            var newEnds = Array(ends.prefix(from))
            var position = start
            for index in from..<blocks.count {
                let paragraph = TranscriptStyle.render(blocks[index], last: index == blocks.count - 1)
                tail.append(paragraph)
                position += paragraph.length
                newEnds.append(position)
            }

            let wasAtBottom = isAtBottom
            let selection = textView.selectedRanges
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
            storage.endEditing()
            shown = blocks
            ends = newEnds

            // What you selected stays selected (the text before the change is the same).
            let length = storage.length
            let kept: [NSValue] = selection.map(\.rangeValue).compactMap { range in
                guard range.location <= length else { return nil }
                return NSValue(range: NSRange(location: range.location, length: min(range.length, length - range.location)))
            }
            if !kept.isEmpty, kept != textView.selectedRanges {
                textView.selectedRanges = kept
            }
            let selecting = textView.selectedRanges.contains { $0.rangeValue.length > 0 }
            if following, wasAtBottom, !selecting {
                scrollToEnd()
            }
        }

        func scrollToEnd() {
            guard let textView, let storage = textView.textStorage else { return }
            textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }

        /// The newest text is in view (or nearly): new text keeps it there.
        private var isAtBottom: Bool {
            guard let scrollView, let document = scrollView.documentView else { return true }
            return scrollView.contentView.documentVisibleRect.maxY >= document.bounds.height - 60
        }
    }
}

/// Copies plain text: the words and their times, without fonts and colors (and without the live mark).
final class TranscriptNSTextView: NSTextView {
    /// Where Copy puts the text (a private one in tests, so they never touch yours).
    static var pasteboard = NSPasteboard.general

    override func copy(_ sender: Any?) {
        let whole = string as NSString
        let text = selectedRanges.map { whole.substring(with: $0.rangeValue) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\u{FFFC}\t", with: "")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
        guard !text.isEmpty else { return }
        Self.pasteboard.clearContents()
        Self.pasteboard.setString(text, forType: .string)
    }
}

/// How a transcript paragraph looks: the time in a narrow column, the text beside it with its
/// wrapped lines lined up, right to left for Arabic (the time then on the right).
@MainActor
enum TranscriptStyle {
    /// The time column and the gap after it.
    static let column: CGFloat = 60
    private static let body = NSFont.systemFont(ofSize: 14.5)
    private static let italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
    private static let time = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// The live mark: Navo's waveform in its blue.
    private static let liveMark: NSAttributedString = {
        let attachment = NSTextAttachment()
        let color = NSColor(red: 0.38, green: 0.56, blue: 1.0, alpha: 1)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Being written")?.withSymbolConfiguration(config) {
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
        }
        return NSAttributedString(attachment: attachment)
    }()

    static func render(_ block: TranscriptBlock, last: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 14
        paragraph.baseWritingDirection = TextTools.isRightToLeft(block.text + " " + (block.preview ?? "")) ? .rightToLeft : .leftToRight
        if block.time != nil {
            paragraph.tabStops = [NSTextTab(textAlignment: .natural, location: column)]
            paragraph.defaultTabInterval = column
            paragraph.headIndent = column
        }

        let out = NSMutableAttributedString()
        func add(_ string: String, _ font: NSFont, _ color: NSColor) {
            out.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        if let stamp = block.time {
            if stamp.isEmpty {
                let mark = NSMutableAttributedString(attributedString: liveMark)
                mark.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: mark.length))
                out.append(mark)
            } else {
                add(stamp, time, .secondaryLabelColor)
            }
            add("\t", body, .labelColor)
        }
        switch block.style {
        case .final:
            add(block.text, body, .labelColor)
        case .failed:
            add(block.text, .systemFont(ofSize: 13), .systemOrange)
        case .note:
            add(block.text, body, .secondaryLabelColor)
        case .draft:
            add(block.text, body, .secondaryLabelColor)
            if let preview = block.preview, !preview.isEmpty {
                add((block.text.isEmpty ? "" : " ") + preview, italic, .tertiaryLabelColor)
            }
        }
        if !last { add("\n", body, .labelColor) }
        return out
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
            if !title.isEmpty {
                Text(title)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .fixedSize()
    }
}
