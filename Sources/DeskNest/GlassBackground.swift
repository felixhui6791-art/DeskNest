import AppKit
import SwiftUI

/// Background-only glass. Content must remain a sibling above this view, so its
/// opacity and vibrancy never inherit the user's background transparency.
@MainActor
struct GlassBackground: View {
    let transparency: Double
    var cornerRadius: CGFloat = 21
    var tone: GlassTone = .frost

    private var density: Double {
        1 - AppearanceSettings.normalizedTransparency(transparency, fallback: 0)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            // Dark glass keeps enough material to support its light labels even
            // over a white window. The transparency slider still reveals more backdrop.
            GlassMaterialView(opacity: tone.isDark ? 0.62 + 0.30 * density : 0.78 * density,
                              cornerRadius: cornerRadius, tone: tone)
            tone.color.opacity((tone == .frost ? 0.055 : (tone.isDark ? 0.34 : 0.24)) * density)
            LinearGradient(
                colors: [.white.opacity(0.16 * density), .white.opacity(0.025 * density),
                         .black.opacity(0.045 * density)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        .clipShape(shape)
        .overlay {
            // Keep a faint rim even at the clearest setting, like cut glass.
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.18 + 0.34 * density),
                                        .white.opacity(0.05 + 0.07 * density),
                                        .white.opacity(0.12 + 0.18 * density)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
private struct GlassMaterialView: NSViewRepresentable {
    var opacity: Double
    var cornerRadius: CGFloat
    var tone: GlassTone

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = tone == .frost ? nil : NSAppearance(named: tone.isDark ? .darkAqua : .aqua)
        view.alphaValue = CGFloat(opacity)
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
    }
}
