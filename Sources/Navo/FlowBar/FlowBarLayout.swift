import AppKit
import SwiftUI

/// What the Flow Bar is showing right now.
enum FlowBarVisual: Equatable {
    case hidden
    case orb
    case menu
    case recording
    case processing(String)
    case message(String, isError: Bool)
}

/// Single source of truth for Flow Bar geometry, shared by the SwiftUI view (sizes) and the
/// controller (window placement and mouse hit-testing).
enum FlowBarLayout {
    static let inset: CGFloat = 8

    /// Size of the transparent panel that hosts the bar for a given edge.
    static func canvas(_ edge: FlowBarEdge) -> CGSize {
        switch edge {
        case .bottom: return CGSize(width: 340, height: 84)
        case .left, .right: return CGSize(width: 320, height: 240)
        }
    }

    static func size(_ visual: FlowBarVisual, edge: FlowBarEdge) -> CGSize {
        switch visual {
        case .hidden: return .zero
        case .orb: return CGSize(width: 22, height: 22)
        case .menu: return edge == .bottom ? CGSize(width: 292, height: 46) : CGSize(width: 56, height: 222)
        case .recording: return CGSize(width: 300, height: 46)
        case .processing: return CGSize(width: 190, height: 46)
        case .message(_, let isError): return CGSize(width: isError ? 300 : 230, height: 46)
        }
    }

    /// Where the visible content sits inside the canvas, in AppKit coordinates (origin bottom-left).
    static func contentRect(_ visual: FlowBarVisual, edge: FlowBarEdge) -> CGRect {
        let canvas = Self.canvas(edge)
        let size = Self.size(visual, edge: edge)
        switch edge {
        case .bottom:
            return CGRect(x: (canvas.width - size.width) / 2, y: inset, width: size.width, height: size.height)
        case .left:
            return CGRect(x: inset, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
        case .right:
            return CGRect(x: canvas.width - inset - size.width, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
        }
    }

    /// SwiftUI alignment matching `contentRect`.
    static func alignment(_ edge: FlowBarEdge) -> Alignment {
        switch edge {
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    static func padding(_ edge: FlowBarEdge) -> Edge.Set {
        switch edge {
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    /// Panel frame on a screen for an edge and a 0...1 position along it.
    static func panelFrame(edge: FlowBarEdge, position: Double, screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let size = Self.canvas(edge)
        let fraction = CGFloat(min(max(position, 0), 1))
        switch edge {
        case .bottom:
            let x = visible.minX + visible.width * fraction - size.width / 2
            return NSRect(
                x: min(max(x, visible.minX), visible.maxX - size.width),
                y: visible.minY,
                width: size.width,
                height: size.height
            )
        case .left, .right:
            let y = visible.minY + visible.height * fraction - size.height / 2
            return NSRect(
                x: edge == .left ? visible.minX : visible.maxX - size.width,
                y: min(max(y, visible.minY), visible.maxY - size.height),
                width: size.width,
                height: size.height
            )
        }
    }
}

/// Borderless, transparent, non-activating panel: clicking it never steals focus from the app you dictate into.
final class FlowBarPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on a non-key panel reach SwiftUI buttons.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
