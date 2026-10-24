import AppKit
import SwiftUI

/// Clear Liquid Glass on macOS 26+, with a translucent material fallback on older systems.
enum GlassSurface {
    /// A glass backdrop view with `content` hosted inside it.
    @MainActor
    static func backdrop(cornerRadius: CGFloat, tint: NSColor? = nil, content: NSView? = nil) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            glass.contentView = content
            return glass
        }
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = cornerRadius
        fx.layer?.masksToBounds = true
        if let content {
            content.frame = fx.bounds
            content.autoresizingMask = [.width, .height]
            fx.addSubview(content)
        }
        return fx
    }
}

extension View {
    /// Clear glass behind this view, clipped to `shape`.
    @ViewBuilder
    func clearGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.clear.tint(tint).interactive(interactive), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        }
    }
}
