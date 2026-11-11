import AppKit

/// The left-click ripple: a ring that spreads out from the click and fades, like a drop in water.
/// Three looks (set in Settings → Drawing → Click ripple):
/// - Glass: a thin ring of real frosted glass that blurs whatever is underneath, with a coloured edge.
/// - Glow: a soft coloured bloom, no blur.
/// - Line: a crisp thin ring.
///
/// Each ripple is its own small click-through window, so the glass can sample the apps below.
/// Windows are pooled and reused.
final class Splash {
    struct Look {
        var style: RippleStyle
        var color: CGColor
        var diameter: CGFloat
        var duration: TimeInterval
    }

    /// Settings → Click ripple posts this to show a ripple under the mouse.
    static let previewRequested = Notification.Name("TinyHandRipplePreview")

    private struct Parts {
        let window: NSWindow
        let glass: NSVisualEffectView
        let color: NSImageView
    }

    private static let startDiameter: CGFloat = 18

    private var pool: [Parts] = []
    private var tints: [String: NSImage] = [:]
    private let level: NSWindow.Level

    private lazy var glassMask = Splash.ringImage(stops: [
        (NSColor(white: 0, alpha: 0), 0.0),
        (NSColor(white: 0, alpha: 0), 0.80),
        (NSColor(white: 0, alpha: 0.7), 0.90),
        (NSColor(white: 0, alpha: 0), 1.0),
    ])

    /// - Parameter level: window level for the ripples; keep it under the pointer's overlay.
    init(level: NSWindow.Level) {
        self.level = level
    }

    /// - Parameter point: click location in global screen coordinates (bottom-left origin).
    func splash(at point: CGPoint, look: Look) {
        let parts = take()
        let window = parts.window
        parts.glass.isHidden = look.style != .glass
        parts.color.image = tint(for: look)

        let start = Splash.frame(around: point, diameter: Splash.startDiameter)
        let end = Splash.frame(around: point, diameter: look.diameter)
        window.setFrame(start, display: true)
        window.alphaValue = look.style == .glass ? 0.85 : 0.95
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = look.duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
            window.animator().setFrame(end, display: true)
        })
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = look.duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.pool.append(parts)
        })
    }

    private func take() -> Parts {
        if let p = pool.popLast() {
            return p
        }
        let frame = NSRect(x: 0, y: 0, width: Splash.startDiameter, height: Splash.startDiameter)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = level
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let container = NSView(frame: frame)
        container.autoresizesSubviews = true

        let glass = NSVisualEffectView(frame: frame)
        glass.blendingMode = .behindWindow
        glass.material = .popover
        glass.appearance = NSAppearance(named: .aqua)   // light glass, reads as light catching water on dark screens
        glass.state = .active               // stay frosted even though TinyHand is never the active app
        glass.maskImage = glassMask
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)

        let color = NSImageView(frame: frame)
        color.imageScaling = .scaleAxesIndependently
        color.autoresizingMask = [.width, .height]
        container.addSubview(color)

        w.contentView = container
        return Parts(window: w, glass: glass, color: color)
    }

    /// The coloured part of the ripple, built once per style and colour.
    private func tint(for look: Look) -> NSImage {
        let base = NSColor(cgColor: look.color)?.usingColorSpace(.sRGB) ?? .systemBlue
        let key = "\(look.style.rawValue)-\(base.redComponent)-\(base.greenComponent)-\(base.blueComponent)"
        if let hit = tints[key] {
            return hit
        }
        let light = base.blended(withFraction: 0.6, of: .white) ?? base
        func c(_ color: NSColor, _ alpha: CGFloat) -> NSColor { color.withAlphaComponent(alpha) }
        let stops: [(NSColor, CGFloat)]
        switch look.style {
        case .glass:
            stops = [(c(light, 0), 0), (c(light, 0), 0.80), (c(light, 0.45), 0.87), (c(base, 0.30), 0.93), (c(base, 0), 1)]
        case .glow:
            stops = [(c(base, 0), 0), (c(base, 0.06), 0.40), (c(light, 0.22), 0.78), (c(base, 0.18), 0.88), (c(base, 0), 1)]
        case .line:
            stops = [(c(base, 0), 0), (c(base, 0), 0.89), (c(light, 0.9), 0.935), (c(base, 0), 0.98), (c(base, 0), 1)]
        }
        let image = Splash.ringImage(stops: stops)
        tints[key] = image
        return image
    }

    private static func frame(around p: CGPoint, diameter d: CGFloat) -> NSRect {
        NSRect(x: (p.x - d / 2).rounded(), y: (p.y - d / 2).rounded(), width: d.rounded(), height: d.rounded())
    }

    /// A soft ring: a radial gradient from the centre (location 0) to the edge (location 1).
    /// Stretches with the window, so the ring widens as it spreads, like a real wave.
    private static func ringImage(stops: [(NSColor, CGFloat)]) -> NSImage {
        let size = NSSize(width: 256, height: 256)
        let image = NSImage(size: size, flipped: false) { rect in
            let colors = stops.map { $0.0 }
            var locations = stops.map { $0.1 }
            guard let gradient = NSGradient(colors: colors, atLocations: &locations, colorSpace: .sRGB) else {
                return false
            }
            // Explicit radii: location 0 is the centre, 1 is the edge of the circle.
            // (Drawing into an oval path instead stretches the gradient out to the image corners,
            // which pushed the ring outside the visible circle.)
            let c = CGPoint(x: rect.midX, y: rect.midY)
            gradient.draw(fromCenter: c, radius: 0, toCenter: c, radius: rect.width / 2, options: [])
            return true
        }
        image.capInsets = NSEdgeInsetsZero
        image.resizingMode = .stretch
        return image
    }
}
