import AppKit
import SwiftUI

/// An AppKit Liquid Glass background, used in place of SwiftUI's
/// `glassEffect(_:in:)`.
///
/// Why: SwiftUI's `glassEffect` renders the material through the SwiftUI
/// hosting tree — the modifier "captures the content to send to the container
/// to render" — so when anything in the sampled backdrop changes (a streaming
/// transcript sitting behind the floating bars) the system re-renders that
/// whole region, which is the entire session window. `NSGlassEffectView` is a
/// real AppKit view that the window server composites and samples per-region —
/// the documented route for content that scrolls under window chrome (see
/// `NSVisualEffectView`'s in-window blending). Same Liquid Glass look, without
/// the hosting-tree capture.
struct GlassBackground: NSViewRepresentable {
    enum Shape {
        /// A fixed corner radius: the composer and any larger glass panel.
        case roundedRectangle(cornerRadius: CGFloat)
        /// A pill: the corner radius tracks half the view's height, so the
        /// capsule stays correct as the pill resizes.
        case capsule
    }

    var shape: Shape = .roundedRectangle(cornerRadius: WindowChrome.cornerRadius)
    /// A semantic tint (the error banner rides the glass in red). Every other
    /// surface leaves this nil, so the untinted material is identical across
    /// all chrome.
    var tint: NSColor?

    func makeNSView(context: Context) -> AdaptiveGlassView {
        let view = AdaptiveGlassView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: AdaptiveGlassView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: AdaptiveGlassView) {
        // ONE material for every glass surface in the app (toolbar chrome,
        // tab bars, the composer, panels, banners). The style is deliberately
        // not a parameter: a single `.clear` capsule used to sit next to
        // `.regular` ones and read as a different material (the "nav bar
        // doesn't match the sub-nav/prompt" mismatch). Shape may vary (a
        // capsule pill vs a rounded panel); the material may not.
        view.style = .regular
        view.tintColor = tint
        switch shape {
        case .roundedRectangle(let radius):
            view.cornerMode = .fixed(radius)
        case .capsule:
            view.cornerMode = .capsule
        }
    }
}

/// `NSGlassEffectView` whose corner radius can track the view's height, for
/// pill-shaped chrome whose height isn't known until layout runs.
final class AdaptiveGlassView: NSGlassEffectView {
    enum CornerMode {
        case fixed(CGFloat)
        case capsule
    }

    var cornerMode: CornerMode = .fixed(WindowChrome.cornerRadius) {
        didSet { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let radius: CGFloat
        switch cornerMode {
        case .fixed(let value): radius = value
        case .capsule: radius = bounds.height / 2
        }
        // Only when it actually changes: an unconditional set re-renders the
        // glass on every layout pass, which during streaming is every frame.
        if cornerRadius != radius { cornerRadius = radius }
    }
}
