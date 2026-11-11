import AppKit

/// Quick ring: hold the right button and click left to open it at the pointer.
/// Left half: six ink colours. Right half: up to six pointers (your toolbar favourites,
/// always including the one in use). Middle: how long drawings last; each click cycles
/// Stay → 1 s → 3 s → 6 s.
/// Inside the colours, three subtle circles set the pen size: thick, medium, thin.
/// The label under the ring names whatever you hover.
final class InkRing {
    enum Target: Equatable {
        case color(InkChoice)
        case pointer(PointerStyle)
        case size(PenSize)
        case timing
    }

    static let colors: [InkChoice] = [.red, .yellow, .green, .blue, .purple, .white]
    static let maxPointers = 6

    private static let outer: CGFloat = 88      // disk radius
    private static let orbit: CGFloat = 64      // distance of the items from the centre
    private static let dotRadius: CGFloat = 12
    private static let slotRadius: CGFloat = 14
    private static let inner: CGFloat = 21      // Fade/Keep button radius
    private static let sizeOrbit: CGFloat = 38  // pen-size circles sit between the centre button and the colours
    private static let sizeBand: CGFloat = 51   // closer in than this on the left half = pen size
    /// Thick near red, medium between green and blue, thin near white.
    private static let sizes: [(size: PenSize, degrees: CGFloat, radius: CGFloat)] = [
        (.thick, 118, 9), (.medium, 180, 6), (.thin, 242, 3.5),
    ]
    private static let labelHeight: CGFloat = 20
    private static let labelGap: CGFloat = 8

    let layer = CALayer()
    private let disk = CAShapeLayer()
    private var dots: [CAShapeLayer] = []
    private var sizeDots: [CAShapeLayer] = []
    private var slots: [(style: PointerStyle, back: CAShapeLayer, image: CALayer)] = []
    private let middle = CAShapeLayer()
    private let icon = CALayer()
    private let label = CATextLayer()

    private(set) var isOpen = false
    private var origin: CGPoint = .zero
    /// Where the pointer was when the ring opened (the ring itself may sit elsewhere near a screen edge).
    private(set) var openedAt: CGPoint = .zero
    private var hovered: Target?
    private var fade: Double = 0   // seconds; 0 = drawings stay
    private let centreText = CATextLayer()
    private var targets: [(target: Target, angle: CGFloat)] = []

    private var centre: CGPoint { CGPoint(x: InkRing.outer, y: InkRing.outer) }

    init() {
        let o = InkRing.outer
        layer.bounds = CGRect(x: 0, y: 0, width: o * 2, height: o * 2)
        layer.isHidden = true
        layer.masksToBounds = false

        disk.frame = layer.bounds
        disk.path = CGPath(ellipseIn: layer.bounds, transform: nil)
        disk.fillColor = CGColor(gray: 0.08, alpha: 0.82)
        disk.strokeColor = CGColor(gray: 1, alpha: 0.18)
        disk.lineWidth = 1
        disk.shadowColor = NSColor.black.cgColor
        disk.shadowOpacity = 0.35
        disk.shadowRadius = 8
        disk.shadowOffset = CGSize(width: 0, height: -2)
        layer.addSublayer(disk)

        // A faint hairline down the middle separates colours from pointers.
        let divider = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: o, y: o + InkRing.inner + 8))
        path.addLine(to: CGPoint(x: o, y: o * 2 - 10))
        path.move(to: CGPoint(x: o, y: o - InkRing.inner - 8))
        path.addLine(to: CGPoint(x: o, y: 10))
        divider.path = path
        divider.strokeColor = CGColor(gray: 1, alpha: 0.12)
        divider.lineWidth = 1
        layer.addSublayer(divider)

        for (i, choice) in InkRing.colors.enumerated() {
            let r = InkRing.dotRadius
            let dot = CAShapeLayer()
            dot.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            dot.position = point(at: InkRing.colorAngle(i))
            dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
            dot.fillColor = choice.color
            layer.addSublayer(dot)
            dots.append(dot)
        }

        for item in InkRing.sizes {
            let r = item.radius
            let dot = CAShapeLayer()
            dot.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            dot.position = point(at: item.degrees * .pi / 180, orbit: InkRing.sizeOrbit)
            dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
            layer.addSublayer(dot)
            sizeDots.append(dot)
        }

        let m = InkRing.inner
        middle.bounds = CGRect(x: 0, y: 0, width: m * 2, height: m * 2)
        middle.position = centre
        middle.path = CGPath(ellipseIn: middle.bounds, transform: nil)
        middle.fillColor = CGColor(gray: 1, alpha: 0.12)
        middle.strokeColor = CGColor(gray: 1, alpha: 0.3)
        middle.lineWidth = 1
        layer.addSublayer(middle)

        icon.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
        icon.position = centre
        icon.contentsGravity = .resizeAspect
        icon.contentsScale = 2
        layer.addSublayer(icon)

        centreText.alignmentMode = .center
        centreText.fontSize = 12
        centreText.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        centreText.foregroundColor = NSColor.white.cgColor
        centreText.contentsScale = 2
        centreText.bounds = CGRect(x: 0, y: 0, width: 34, height: 16)
        centreText.position = centre
        layer.addSublayer(centreText)

        label.alignmentMode = .center
        label.fontSize = 11
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.foregroundColor = NSColor.white.cgColor
        label.backgroundColor = CGColor(gray: 0.08, alpha: 0.82)
        label.cornerRadius = InkRing.labelHeight / 2
        label.contentsScale = 2
        label.bounds = CGRect(x: 0, y: 0, width: 140, height: InkRing.labelHeight)
        label.position = CGPoint(x: o, y: -InkRing.labelGap - InkRing.labelHeight / 2)
        layer.addSublayer(label)
    }

    // Angles in radians, 0 = right, counter-clockwise. Colours fill the left half from the top down,
    // pointers fill the right half from the top down, leaving a gap at the top and bottom.
    private static func colorAngle(_ i: Int) -> CGFloat {
        (90 + 20 + 28 * CGFloat(i)) * .pi / 180
    }

    private static func pointerAngle(_ i: Int) -> CGFloat {
        (90 - 20 - 28 * CGFloat(i)) * .pi / 180
    }

    private func point(at angle: CGFloat, orbit: CGFloat = InkRing.orbit) -> CGPoint {
        CGPoint(x: centre.x + cos(angle) * orbit, y: centre.y + sin(angle) * orbit)
    }

    /// What the centre button cycles through. 0 = drawings stay until cleared.
    static let fadeCycle: [Double] = [0, 1, 3, 6]

    /// The next fade time after this one. A value from Settings that isn't in the cycle (10 s)
    /// moves to the next one up, or back to Stay.
    static func nextFade(after current: Double) -> Double {
        if let i = fadeCycle.firstIndex(of: current) {
            return fadeCycle[(i + 1) % fadeCycle.count]
        }
        return fadeCycle.first { $0 > current } ?? 0
    }

    static func describe(_ seconds: Double) -> String {
        seconds <= 0 ? "Drawings stay" : "Drawings fade after \(Int(seconds)) s"
    }

    /// The pointers to offer: toolbar favourites in order, always including the current one.
    static func pointers(current: PointerStyle) -> [PointerStyle] {
        var list = Array(Preferences.pinnedStyles.prefix(maxPointers))
        if !list.contains(current) {
            if list.count == maxPointers {
                list.removeLast()
            }
            list.append(current)
        }
        return list
    }

    func open(at point: CGPoint, in bounds: CGRect, selected: InkChoice, fade: Double, pointer: PointerStyle, pen: PenSize) {
        let o = InkRing.outer
        let below = InkRing.labelGap + InkRing.labelHeight
        let x = min(max(point.x, bounds.minX + o + 8), bounds.maxX - o - 8)
        let y = min(max(point.y, bounds.minY + o + below + 8), bounds.maxY - o - 8)
        origin = CGPoint(x: x, y: y)
        openedAt = point
        hovered = nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = origin
        layer.isHidden = false
        buildPointerSlots(InkRing.pointers(current: pointer))
        CATransaction.commit()

        update(selected: selected, fade: fade, pointer: pointer, pen: pen)
        applyHover()

        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.85
        pop.toValue = 1
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 0
        show.toValue = 1
        let anim = CAAnimationGroup()
        anim.animations = [pop, show]
        anim.duration = 0.12
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "open")
        isOpen = true
    }

    private func buildPointerSlots(_ styles: [PointerStyle]) {
        for s in slots {
            s.back.removeFromSuperlayer()
            s.image.removeFromSuperlayer()
        }
        slots = []
        targets = InkRing.colors.enumerated().map { (target: Target.color($0.element), angle: InkRing.colorAngle($0.offset)) }

        let r = InkRing.slotRadius
        for (i, style) in styles.enumerated() {
            let angle = InkRing.pointerAngle(i)
            let back = CAShapeLayer()
            back.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            back.position = point(at: angle)
            back.path = CGPath(ellipseIn: back.bounds, transform: nil)
            back.fillColor = CGColor(gray: 1, alpha: 0.10)
            layer.insertSublayer(back, below: middle)

            let image = CALayer()
            image.bounds = CGRect(x: 0, y: 0, width: r * 1.6, height: r * 1.6)
            image.position = back.position
            image.contentsGravity = .resizeAspect
            image.contentsScale = 2
            image.contents = Toolbar.icon(for: style)
            layer.insertSublayer(image, below: middle)

            slots.append((style: style, back: back, image: image))
            targets.append((target: .pointer(style), angle: angle))
        }
    }

    func close() {
        guard isOpen else {
            return
        }
        isOpen = false
        hovered = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.isHidden = true
        CATransaction.commit()
    }

    func update(selected: InkChoice, fade: Double, pointer: PointerStyle, pen: PenSize) {
        self.fade = fade
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, item) in InkRing.sizes.enumerated() {
            let on = item.size == pen
            sizeDots[i].fillColor = CGColor(gray: 1, alpha: on ? 0.95 : 0.35)
            sizeDots[i].strokeColor = on ? CGColor(gray: 1, alpha: 0.5) : nil
            sizeDots[i].lineWidth = on ? 4 : 0
        }
        for (i, choice) in InkRing.colors.enumerated() {
            dots[i].fillColor = choice.color   // picks up the Ink tone setting
            let on = choice == selected
            dots[i].strokeColor = on ? NSColor.white.cgColor : CGColor(gray: 1, alpha: 0.35)
            dots[i].lineWidth = on ? 3 : 1
        }
        for s in slots {
            let on = s.style == pointer
            s.back.strokeColor = on ? NSColor.white.cgColor : CGColor(gray: 1, alpha: 0.22)
            s.back.lineWidth = on ? 2.5 : 1
        }
        // Stay shows a pin; a fade time shows the seconds.
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        icon.contents = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        icon.isHidden = fade > 0
        centreText.isHidden = fade <= 0
        centreText.string = "\(Int(fade))s"
        CATransaction.commit()
        updateLabel()
    }

    func target(at point: CGPoint) -> Target? {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let r = hypot(dx, dy)
        if r <= InkRing.inner + 4 {
            return .timing
        }
        if r > InkRing.outer + 14 {
            return nil
        }
        let a0 = atan2(dy, dx)
        if dx < 0 && r < InkRing.sizeBand {
            var bestSize = InkRing.sizes[0].size
            var bestSizeGap = CGFloat.greatestFiniteMagnitude
            for item in InkRing.sizes {
                let gap = abs((a0 - item.degrees * .pi / 180).remainder(dividingBy: 2 * .pi))
                if gap < bestSizeGap {
                    bestSizeGap = gap
                    bestSize = item.size
                }
            }
            return .size(bestSize)
        }
        // Nearest item by angle, so the whole slice around an item picks it.
        let a = a0
        var best: Target?
        var bestGap = CGFloat.greatestFiniteMagnitude
        for t in targets {
            let gap = abs((a - t.angle).remainder(dividingBy: 2 * .pi))
            if gap < bestGap {
                bestGap = gap
                best = t.target
            }
        }
        return best
    }

    func hover(_ point: CGPoint) {
        let t = target(at: point)
        guard t != hovered else {
            return
        }
        hovered = t
        applyHover()
    }

    private func applyHover() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        for (i, choice) in InkRing.colors.enumerated() {
            let big = hovered == .color(choice)
            dots[i].transform = big ? CATransform3DMakeScale(1.3, 1.3, 1) : CATransform3DIdentity
        }
        for s in slots {
            let big = hovered == .pointer(s.style)
            let t = big ? CATransform3DMakeScale(1.25, 1.25, 1) : CATransform3DIdentity
            s.back.transform = t
            s.image.transform = t
        }
        for (i, item) in InkRing.sizes.enumerated() {
            let big = hovered == .size(item.size)
            sizeDots[i].transform = big ? CATransform3DMakeScale(1.4, 1.4, 1) : CATransform3DIdentity
        }
        let mid = hovered == .timing
        middle.transform = mid ? CATransform3DMakeScale(1.15, 1.15, 1) : CATransform3DIdentity
        middle.fillColor = CGColor(gray: 1, alpha: mid ? 0.25 : 0.12)
        CATransaction.commit()
        updateLabel()
    }

    private func updateLabel() {
        let text: String
        switch hovered {
        case .color(let choice)?:
            text = choice.title
        case .pointer(let style)?:
            text = style.title
        case .size(let size)?:
            text = "\(size.title) pen"
        case .timing?:
            let next = InkRing.nextFade(after: fade)
            text = next <= 0 ? "Click: drawings stay" : "Click: fade after \(Int(next)) s"
        case nil:
            text = InkRing.describe(fade)
        }
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let width = max(90, (text as NSString).size(withAttributes: [.font: font]).width + 24)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.string = text
        label.bounds = CGRect(x: 0, y: 0, width: width, height: InkRing.labelHeight)
        CATransaction.commit()
    }
}
