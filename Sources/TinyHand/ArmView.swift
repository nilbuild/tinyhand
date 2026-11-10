import AppKit

final class ArmView: NSView {
    private let group = CALayer()
    private let rodLayer = CALayer()
    private let handLayer = CALayer()
    private let dotLayer = CAShapeLayer()
    private let dotCore = CAShapeLayer()

    private(set) var style: PointerStyle = .lavender
    private var asset: HandAsset?

    private var handLenFrac: CGFloat = Preferences.pointerSize
    private var showShadow = Preferences.showShadow
    private let minRodFrac: CGFloat = 0.05
    private let gripLeanFrac: CGFloat = 0.30
    private let gripDepthFrac: CGFloat = 0.12
    private let gripFollow: CGFloat = 0.08
    private let liftFrac: CGFloat = 0.06

    let ink = Ink()
    var held = false {
        didSet {
            if oldValue && !held {
                releasedAt = CACurrentMediaTime()
            }
        }
    }
    var inkWidth: CGFloat { max(3, bounds.height * 0.0055) }

    private var pressAmount: CGFloat = 0
    private var tapStart: CFTimeInterval?
    private var swingRange = CGFloat(Preferences.swingRange)
    private var releasedAt: CFTimeInterval = 0

    /// Seconds from press() until the fingertip lands on the spot (wind-up + swing-in).
    /// The tap sound waits this long so it plays on contact.
    static let swingWindUp: CFTimeInterval = 0.13
    static let swingIn: CFTimeInterval = 0.09
    static var strikeDelay: CFTimeInterval { swingWindUp + swingIn }
    private static let settleTime: CFTimeInterval = 0.12
    private var gripX: CGFloat?
    private var lastPose: [CGFloat] = []
    private var lastLaserPose: [CGFloat] = []
    private var gripTarget: CGFloat?
    private var displayImageHeight = 0

    var isSettling: Bool {
        if pressAmount > 0.002 || swing(at: CACurrentMediaTime()).press > 0.002 {
            return true
        }
        guard let gx = gripX, let target = gripTarget else {
            return false
        }
        return abs(target - gx) > 0.5
    }

    var pointerHidden = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            group.isHidden = pointerHidden || style == .laser
            dotLayer.isHidden = pointerHidden || style != .laser
            CATransaction.commit()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.masksToBounds = false
        layer = root
        wantsLayer = true
        root.addSublayer(ink.layer)
        root.addSublayer(group)

        root.addSublayer(dotLayer)

        group.masksToBounds = false
        group.addSublayer(rodLayer)
        group.addSublayer(handLayer)
        for sub in [rodLayer, handLayer] {
            sub.contentsGravity = .resize
            sub.contentsScale = 2
            sub.anchorPoint = CGPoint(x: 0.5, y: 0)
            sub.shadowColor = NSColor.black.cgColor
            sub.shadowOpacity = 0.38
        }

        dotLayer.fillColor = Ink.red
        dotLayer.shadowColor = Ink.red
        dotLayer.shadowOpacity = 1
        dotLayer.shadowOffset = .zero
        dotCore.fillColor = CGColor(srgbRed: 1, green: 0.86, blue: 0.82, alpha: 0.95)
        dotLayer.addSublayer(dotCore)

        setStyle(PointerStyle.saved)
        NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            self?.handLenFrac = Preferences.pointerSize
            self?.showShadow = Preferences.showShadow
            self?.swingRange = CGFloat(Preferences.swingRange)
        }
    }

    func updateInkColor() {
        ink.color = Preferences.inkChoice.resolved(for: style)
    }

    func setStyle(_ newStyle: PointerStyle) {
        style = newStyle
        asset = newStyle.assetName.flatMap(HandAsset.load)
        if newStyle != .laser && asset == nil {
            style = .laser
        }
        updateInkColor()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let a = asset, style != .laser {
            group.anchorPoint = CGPoint(x: a.rodX, y: 0)
            displayImageHeight = 0
            updateDisplayImage(a)
            rodLayer.contentsRect = CGRect(x: 0, y: 1 - a.rodEnd, width: 1, height: a.rodEnd - a.wrist)
            handLayer.contentsRect = CGRect(x: 0, y: 1 - a.wrist, width: 1, height: a.wrist - a.handTop)
        }
        CATransaction.commit()
        let hidden = pointerHidden
        pointerHidden = hidden
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    /// At swing range 0 the tap is the original one: no swing, just the small shrink.
    private var swings: Bool { swingRange > 0.001 }

    /// How long the tap sound waits so it plays when the fingertip lands.
    var tapSoundDelay: CFTimeInterval { swings && style != .laser ? ArmView.strikeDelay : 0 }

    func press() {
        pressAmount = 1
        tapStart = swings ? CACurrentMediaTime() : nil
    }

    /// Jump straight to the moment the fingertip touches (used when a drag starts, and by renders).
    func skipSwing() {
        if tapStart != nil {
            tapStart = CACurrentMediaTime() - ArmView.strikeDelay
        }
    }

    /// The tap: the stick lifts up (and a little right), the holding hand rising with it,
    /// then swings down onto the spot and presses. No oscillation.
    /// Distances are fractions of the screen height; press is 1 on the glass, negative when lifted.
    private struct Swing {
        var press: CGFloat = 0
        var poke: CGFloat = 0
        var tilt: CGFloat = 0
        var tipX: CGFloat = 0
        var tipY: CGFloat = 0
        var gripX: CGFloat = 0
        var gripY: CGFloat = 0
    }

    private func swing(at now: CFTimeInterval) -> Swing {
        guard let start = tapStart else {
            return Swing()
        }
        let t = now - start
        let up = ArmView.swingWindUp
        let strike = ArmView.strikeDelay
        let k = swingRange
        func pose(_ e: CGFloat, press: CGFloat) -> Swing {
            let tipX: CGFloat = 0.025 * k
            let tipY: CGFloat = 0.2 * k
            return Swing(press: press, poke: 0.02 * k * e, tilt: -0.03 * k * e,
                         tipX: tipX * e, tipY: tipY * e, gripX: 0.45 * tipX * e, gripY: 0.45 * tipY * e)
        }
        if t < up {
            let e = 1 - pow(1 - CGFloat(t / up), 3)
            return pose(e, press: -0.6 * e)
        }
        if t < strike {
            let e = pow(CGFloat((t - up) / (strike - up)), 2)
            return pose(1 - e, press: -0.6 + 1.6 * e)
        }
        if held {
            return Swing(press: 1)
        }
        let since = now - max(start + strike, releasedAt)
        let press = CGFloat(exp(-since / ArmView.settleTime))
        if press < 0.001 {
            tapStart = nil
            return Swing()
        }
        return Swing(press: press)
    }

    func aim(cursor: CGPoint) {
        let screenH = bounds.height
        let targetX = min(max(cursor.x + gripLeanFrac * bounds.width, bounds.width * 0.15), bounds.width * 1.05)
        let gx = gripX.map { $0 + (targetX - $0) * gripFollow } ?? targetX
        gripX = gx
        gripTarget = targetX
        if !held {
            pressAmount += (0 - pressAmount) * 0.18
        }

        if ink.isDrawing {
            skipSwing()
        }
        let sw = swing(at: CACurrentMediaTime())
        let grip = CGPoint(x: gx + sw.gripX * screenH, y: (sw.gripY - gripDepthFrac) * screenH)

        if style == .laser {
            aimLaser(cursor: cursor)
            return
        }
        guard let a = asset else {
            return
        }
        updateDisplayImage(a)

        let toCursor = CGPoint(x: cursor.x - grip.x, y: cursor.y - grip.y)
        let dist = max(1, hypot(toCursor.x, toCursor.y))
        let poke = sw.poke * screenH
        let dx = toCursor.x - toCursor.x / dist * poke + sw.tipX * screenH
        let dy = toCursor.y - toCursor.y / dist * poke + sw.tipY * screenH
        let reach = hypot(dx, dy)
        let aimAngle = atan2(dy, dx)

        // Swing range 0 keeps the original press: pressAmount and a 6% shrink.
        let press = swings ? sw.press : pressAmount
        let handPts = handLenFrac * screenH * (1 - (swings ? 0.10 : 0.06) * press)
        let s = handPts / (a.wrist - a.handTop)
        let widthPts = s * a.aspect
        let handTipPts = (a.wrist - a.tip) * s
        let tipOffX = (a.tipX - a.rodX) * widthPts

        let along = sqrt(max(0, reach * reach - tipOffX * tipOffX))
        var rodLen = along - handTipPts
        rodLen = max(minRodFrac * screenH, rodLen)
        let tipAngle = atan2(rodLen + handTipPts, tipOffX)
        let rotation = aimAngle - tipAngle + sw.tilt

        let lift = liftFrac * screenH * (1 - 0.8 * press)
        let pressed = max(0, press)
        let sx = lift * 0.6
        let sy = -lift
        let shadowOffset = CGSize(
            width: sx * cos(-rotation) - sy * sin(-rotation),
            height: sx * sin(-rotation) + sy * cos(-rotation)
        )

        let pose = [rotation, rodLen, handPts, widthPts, grip.x, grip.y, lift, press, showShadow ? 1 : 0, a.aspect]
            .map { ($0 * 100).rounded() }
        guard pose != lastPose else {
            return
        }
        lastPose = pose

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for sub in [rodLayer, handLayer] {
            sub.shadowOffset = shadowOffset
            sub.shadowRadius = max(1, lift * 0.35) + 5 * pressed
            sub.shadowOpacity = showShadow ? Float(0.26 + 0.02 * pressed) : 0
        }

        rodLayer.bounds = CGRect(x: 0, y: 0, width: widthPts, height: rodLen)
        rodLayer.position = CGPoint(x: widthPts / 2, y: 0)
        handLayer.bounds = CGRect(x: 0, y: 0, width: widthPts, height: handPts)
        handLayer.position = CGPoint(x: widthPts / 2, y: rodLen)

        group.bounds = CGRect(x: 0, y: 0, width: widthPts, height: rodLen + handPts)
        group.position = grip
        group.transform = CATransform3DMakeRotation(rotation, 0, 0, 1)

        CATransaction.commit()
    }

    private func aimLaser(cursor: CGPoint) {
        let press = pressAmount
        let r = max(4, bounds.height * 0.0038 * handLenFrac / 0.13) * (1 + 0.2 * press)
        let laserPose = [r, cursor.x, cursor.y].map { ($0 * 100).rounded() }
        guard laserPose != lastLaserPose else {
            return
        }
        lastLaserPose = laserPose
        let core = r * 0.45
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dot = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        dotLayer.path = dot
        dotLayer.shadowPath = dot
        dotCore.path = CGPath(ellipseIn: CGRect(x: -core, y: -core, width: 2 * core, height: 2 * core), transform: nil)
        dotLayer.position = cursor
        dotLayer.shadowRadius = r * (2.2 + 1.0 * press)
        CATransaction.commit()
    }

    private func updateDisplayImage(_ a: HandAsset) {
        let full = a.image
        let scale = window?.backingScaleFactor ?? 2
        let restPts = handLenFrac * bounds.height / (a.wrist - a.handTop)
        let step = 64
        let needed = (Int((restPts * scale).rounded(.up)) + step - 1) / step * step
        let height = needed >= full.height * 9 / 10 ? full.height : max(step, needed)
        guard height != displayImageHeight else {
            return
        }
        displayImageHeight = height
        let image = height == full.height ? full : HandAsset.resized(full, height: height) ?? full
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rodLayer.contents = image
        handLayer.contents = image
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        applyBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    private func applyBackingScale() {
        let scale = window?.backingScaleFactor ?? 2
        rodLayer.contentsScale = scale
        handLayer.contentsScale = scale
        ink.scale = scale
    }
}
