import AppKit

final class Ink {
    let layer = CALayer()
    var keep: Bool { Preferences.fadeSeconds == 0 }

    // With the trail setting, an eraser follows each line from its start at a steady speed, so
    // long lines take longer to go than short ones. It starts `trailDelay` after the line begins
    // and never erases what was drawn within that time.
    private var trailing: Bool { Preferences.fadeSeconds < 0 }
    private var trailDelay: CFTimeInterval { Preferences.trailDelay }
    private var eraseSpeed: CGFloat { CGFloat(Preferences.trailSpeed) }

    private final class Trail {
        let layer: CAShapeLayer
        let start: CFTimeInterval
        var last: CGPoint
        var length: CGFloat = 0
        var times: [CFTimeInterval] = []
        var distances: [CGFloat] = []
        var erased: CGFloat = 0

        init(layer: CAShapeLayer, at point: CGPoint, time: CFTimeInterval) {
            self.layer = layer
            start = time
            last = point
            times = [time]
            distances = [0]
        }

        func add(_ point: CGPoint, at time: CFTimeInterval) {
            length += hypot(point.x - last.x, point.y - last.y)
            last = point
            times.append(time)
            distances.append(length)
        }
    }
    private var live: Trail?
    private var trailTimer: Timer?
    private var lastStep: CFTimeInterval = 0

    static let purple = CGColor(srgbRed: 0.53, green: 0.33, blue: 0.95, alpha: 1)
    static let red = CGColor(srgbRed: 1.0, green: 0.16, blue: 0.12, alpha: 1)

    static func hex(_ v: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    var color = Ink.purple
    var scale: CGFloat = 2
    private var fadeDelay: CFTimeInterval { max(0.5, Preferences.fadeSeconds) }
    private let fadeDuration: CFTimeInterval = 0.6

    var arrow = false {
        didSet {
            if arrow != oldValue {
                redraw()
            }
        }
    }

    private var stroke: CAShapeLayer?
    private var points: [CGPoint] = []

    var isDrawing: Bool { stroke != nil }

    init() {
        layer.masksToBounds = false
    }

    func begin(at point: CGPoint, width: CGFloat) {
        let s = CAShapeLayer()
        s.strokeColor = color
        s.fillColor = nil
        s.lineWidth = width
        s.lineCap = .round
        s.lineJoin = .round
        s.shadowColor = NSColor.black.cgColor
        s.shadowOpacity = 0.18
        s.shadowRadius = 1.5
        s.shadowOffset = CGSize(width: 1, height: -1.5)
        layer.addSublayer(s)
        stroke = s
        points = [point]
        if trailing {
            live = Trail(layer: s, at: point, time: CACurrentMediaTime())
            startTrailTimer()
        }
        redraw()
    }

    func extend(to point: CGPoint) {
        guard stroke != nil, let last = points.last else {
            return
        }
        if hypot(point.x - last.x, point.y - last.y) < 1.5 {
            return
        }
        points.append(point)
        live?.add(point, at: CACurrentMediaTime())
        redraw()
    }

    func end() {
        guard let s = stroke else {
            return
        }
        stroke = nil
        let headLength = self.headLength(s)
        points = []
        arrow = false
        if let t = live {
            live = nil
            stopTrailTimer()
            finish(t, headLength: headLength)
            return
        }
        freeze(s)
        if keep {
            return
        }
        fade(s, after: fadeDelay, over: fadeDuration)
    }

    func clear() {
        stroke = nil
        points = []
        live = nil
        stopTrailTimer()
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    private func startTrailTimer() {
        stopTrailTimer()
        lastStep = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            self?.stepLiveTrail()
        }
        RunLoop.main.add(timer, forMode: .common)
        trailTimer = timer
    }

    private func stopTrailTimer() {
        trailTimer?.invalidate()
        trailTimer = nil
    }

    // Moves the eraser along the line being drawn, keeping clear of the part drawn most recently.
    private func stepLiveTrail() {
        let now = CACurrentMediaTime()
        let step = eraseSpeed * CGFloat(now - lastStep)
        lastStep = now
        guard let t = live, now - t.start >= trailDelay else {
            return
        }
        let limit = t.times.lastIndex { $0 <= now - trailDelay }.map { t.distances[$0] } ?? 0
        t.erased = min(t.erased + step, max(t.erased, limit))
        setStrokeStart(t)
    }

    private func setStrokeStart(_ t: Trail) {
        let total = t.length + headLength(t.layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        t.layer.strokeStart = total > 0 ? min(1, t.erased / total) : 0
        CATransaction.commit()
    }

    // Once the line is finished, the rest of the erasing runs as one animation at the same speed.
    private func finish(_ t: Trail, headLength: CGFloat) {
        let now = CACurrentMediaTime()
        let wait = max(0, t.start + trailDelay - now)
        let total = t.length + headLength
        let from = total > 0 ? min(1, t.erased / total) : 0
        let duration = max(0.05, CFTimeInterval((total - t.erased) / eraseSpeed))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        t.layer.strokeStart = 1
        CATransaction.commit()
        let anim = CABasicAnimation(keyPath: "strokeStart")
        anim.fromValue = from
        anim.toValue = 1
        anim.beginTime = now + wait
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.fillMode = .backwards
        t.layer.add(anim, forKey: "trail")
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + duration) { [weak s = t.layer] in
            s?.removeFromSuperlayer()
        }
    }

    // The arrowhead's two strokes are drawn after the line, so the eraser reaches them last.
    private func headLength(_ s: CAShapeLayer) -> CGFloat {
        arrow ? 2 * max(14, s.lineWidth * 3.2) : 0
    }

    private func freeze(_ s: CAShapeLayer) {
        guard let path = s.path else {
            return
        }
        let pad = s.lineWidth / 2 + s.shadowRadius * 3 + max(abs(s.shadowOffset.width), abs(s.shadowOffset.height)) + 2
        let box = path.boundingBoxOfPath.insetBy(dx: -pad, dy: -pad).integral
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.bounds = box
        s.position = CGPoint(x: box.midX, y: box.midY)
        s.rasterizationScale = scale
        s.shouldRasterize = true
        CATransaction.commit()
    }

    private func fade(_ s: CAShapeLayer, after delay: CFTimeInterval, over duration: CFTimeInterval) {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1
        anim.toValue = 0
        anim.beginTime = CACurrentMediaTime() + delay
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        s.add(anim, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration) { [weak s] in
            s?.removeFromSuperlayer()
        }
    }

    private func redraw() {
        guard let s = stroke, let first = points.first else {
            return
        }
        let path = smoothPath(first)
        if arrow {
            addHead(to: path, size: max(14, s.lineWidth * 3.2))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.path = path
        CATransaction.commit()
    }

    private func smoothPath(_ first: CGPoint) -> CGMutablePath {
        let path = CGMutablePath()
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
        }
        for i in 1..<max(1, points.count) {
            let p = points[i]
            let prev = points[i - 1]
            let mid = CGPoint(x: (prev.x + p.x) / 2, y: (prev.y + p.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
        }
        if points.count > 1, let last = points.last {
            path.addLine(to: last)
        }
        return path
    }

    // Aims the head along the last stretch of the stroke, so a wobble at the very end doesn't twist it.
    private func addHead(to path: CGMutablePath, size: CGFloat) {
        guard let end = points.last else {
            return
        }
        let back = points.last { hypot(end.x - $0.x, end.y - $0.y) >= size * 1.2 } ?? points.first ?? end
        let length = hypot(end.x - back.x, end.y - back.y)
        guard length > 1 else {
            return
        }
        let head = min(size, length * 0.8)
        let angle = atan2(end.y - back.y, end.x - back.x)
        let spread = CGFloat.pi / 7
        for side: CGFloat in [-1, 1] {
            let a = angle + .pi + side * spread
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x + cos(a) * head, y: end.y + sin(a) * head))
        }
    }
}
