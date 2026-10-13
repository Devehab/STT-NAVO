import AppKit
import SwiftUI

/// The words heard so far, in a small dark card next to the Flow Bar while you dictate.
/// Finished phrases are bright, the one still being said is dimmer and may still change. Only the
/// newest two or three lines show, so a five minute dictation never fills the screen.
@MainActor
final class LiveCaptionModel: ObservableObject {
    @Published private(set) var settled = ""
    @Published private(set) var preview = ""
    @Published private(set) var rightToLeft = false

    /// Characters kept: about three lines of the card.
    private static let shown = 170

    var isEmpty: Bool { settled.isEmpty && preview.isEmpty }

    func show(_ text: LiveText) {
        var head = text.settled
        var tail = text.preview.isEmpty ? "" : (head.isEmpty ? "" : " ") + text.preview
        let total = head.count + tail.count
        if total > Self.shown {
            // Drop whole words from the start until the end fits.
            var drop = total - Self.shown
            if drop >= head.count {
                drop -= head.count
                head = ""
                tail = Self.trimStart(tail, by: drop)
            } else {
                head = Self.trimStart(head, by: drop)
            }
            head = "… " + head
        }
        if head != settled { settled = head }
        if tail != preview { preview = tail }
        let rtl = TextTools.isRightToLeft(text.settled + " " + text.preview)
        if rtl != rightToLeft { rightToLeft = rtl }
    }

    private static func trimStart(_ text: String, by count: Int) -> String {
        guard count > 0 else { return text }
        let rest = text.dropFirst(count)
        if let space = rest.firstIndex(of: " ") {
            return String(rest[rest.index(after: space)...])
        }
        return String(rest)
    }
}

struct LiveCaptionView: View {
    @ObservedObject var model: LiveCaptionModel
    let edge: FlowBarEdge

    var body: some View {
        ZStack(alignment: edge == .bottom ? .bottom : .center) {
            Color.clear
            if !model.isEmpty {
                card
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.settled)
        .animation(.easeOut(duration: 0.18), value: model.preview)
        .environment(\.colorScheme, .dark)
    }

    /// Finished words bright, the phrase still being said dimmer.
    private var words: Text {
        let settled = Text(model.settled).foregroundColor(Color.white.opacity(0.96))
        let preview = Text(model.preview).foregroundColor(Color.white.opacity(0.55))
        return settled + preview
    }

    private var card: some View {
        words
            .font(.system(size: 15))
            .lineSpacing(3)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, model.rightToLeft ? .rightToLeft : .leftToRight)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(background)
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return shape
            .fill(Color.black.opacity(0.86))
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }
}

/// Places the caption card beside the Flow Bar: above it at the bottom of the screen, next to it
/// on the left or right edge. Clicks go through it.
@MainActor
final class LiveCaptionController {
    static let size = CGSize(width: 520, height: 104)

    private let model = LiveCaptionModel()
    private let panel = FlowBarPanel(size: LiveCaptionController.size)
    private var edge: FlowBarEdge?

    init() {
        panel.ignoresMouseEvents = true
    }

    /// `bar` is the Flow Bar's visible rectangle on screen; nil hides the caption.
    func update(_ text: LiveText?, bar: NSRect?, edge: FlowBarEdge, screen: NSScreen?) {
        guard let text, !text.isEmpty, let bar else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if self.edge != edge {
            self.edge = edge
            let host = NSHostingView(rootView: LiveCaptionView(model: model, edge: edge))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: Self.size)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
        }
        model.show(text)
        panel.setFrame(frame(beside: bar, edge: edge, screen: screen), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func frame(beside bar: NSRect, edge: FlowBarEdge, screen: NSScreen?) -> NSRect {
        let size = Self.size
        var origin: CGPoint
        switch edge {
        case .bottom:
            origin = CGPoint(x: bar.midX - size.width / 2, y: bar.maxY + 2)
        case .left:
            origin = CGPoint(x: bar.maxX + 6, y: bar.midY - size.height / 2)
        case .right:
            origin = CGPoint(x: bar.minX - 6 - size.width, y: bar.midY - size.height / 2)
        }
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return NSRect(origin: origin, size: size)
    }
}
