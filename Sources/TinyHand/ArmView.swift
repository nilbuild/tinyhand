import AppKit

// A toy telescoping pointer held from below the screen: a toy hand on a stick
// rises past the bottom edge and points at the cursor. Both parts are cut from one
// image — the hand stays a constant size, only the stick stretches — so the
// fingertip lands on the cursor wherever it is. The grip stays below the screen and
// lazily follows the cursor. The `.laser` style swaps all of that for a small
// glowing red dot.
final class ArmView: NSView {
    private let group = CALayer()
    private let rodLayer = CALayer()
    private let handLayer = CALayer()
    private let dotLayer = CAShapeLayer()
    private let dotCore = CAShapeLayer()

    private(set) var style: PointerStyle = .lavender
    private var asset: HandAsset?

    // Tunables.
    private var handLenFrac: CGFloat = Preferences.pointerSize  // on-screen hand height / screen height
    private var showShadow = Preferences.showShadow
    private let minRodFrac: CGFloat = 0.05   // rod floor, fraction of screen height
    // The grip is held below the screen, leaning right of the cursor, and follows
    // it lazily — so the rod runs off the bottom edge wherever is natural.
    private let gripLeanFrac: CGFloat = 0.30 // grip x = cursor x + this × screen width
    private let gripDepthFrac: CGFloat = 0.12
    private let gripFollow: CGFloat = 0.08
    // Height of the pointer above the glass: its shadow falls this far down-right
    // (× screen height), and tucks in under the fingertip on a tap.
    private let liftFrac: CGFloat = 0.06

    let ink = Ink()
    // True while the mouse button is down: the pointer stays pressed to the glass.
    var held = false
    var inkWidth: CGFloat { max(3, bounds.height * 0.0055) }

    // 0 = resting, 1 = pressed against the glass. Snaps to 1 on a press, stays
    // there while the button is held, and eases back after release.
    private var pressAmount: CGFloat = 0
    private var gripX: CGFloat?

    // Hides the pointer, e.g. while the real cursor is over the toolbar.
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

        // Laser: a red dot with a hot centre and a red glow (light casts no shadow).
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
        }
    }

    func setStyle(_ newStyle: PointerStyle) {
        style = newStyle
        asset = newStyle.assetName.flatMap(HandAsset.load)
        if newStyle != .laser && asset == nil {
            style = .laser // missing image: fall back to something that always works
        }
        ink.color = style.inkColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let a = asset, style != .laser {
            // Full-width vertical slices of one image, so the hand and stick line up.
            // contentsRect y is measured from the image bottom.
            group.anchorPoint = CGPoint(x: a.rodX, y: 0)
            rodLayer.contents = a.image
            handLayer.contents = a.image
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

    func press() {
        pressAmount = 1
    }

    // cursor in this view's coordinates (origin bottom-left, y up).
    func aim(cursor: CGPoint) {
        let screenH = bounds.height
        let targetX = min(max(cursor.x + gripLeanFrac * bounds.width, bounds.width * 0.15), bounds.width * 1.05)
        let gx = gripX.map { $0 + (targetX - $0) * gripFollow } ?? targetX
        gripX = gx
        let grip = CGPoint(x: gx, y: -gripDepthFrac * screenH)

        if !held {
            pressAmount += (0 - pressAmount) * 0.18
        }

        if style == .laser {
            aimLaser(cursor: cursor)
            return
        }
        guard let a = asset else {
            return
        }

        let dx = cursor.x - grip.x
        let dy = cursor.y - grip.y
        let reach = hypot(dx, dy)
        let aimAngle = atan2(dy, dx)

        // Pressing moves the hand toward the glass: slightly smaller (farther from you).
        let handPts = handLenFrac * screenH * (1 - 0.06 * pressAmount)
        let s = handPts / (a.wrist - a.handTop)    // points per image-height-fraction
        let widthPts = s * a.aspect
        let handTipPts = (a.wrist - a.tip) * s
        let tipOffX = (a.tipX - a.rodX) * widthPts

        // Solve so the fingertip (offset sideways from the rod axis) sits at `reach`.
        let along = sqrt(max(0, reach * reach - tipOffX * tipOffX))
        var rodLen = along - handTipPts
        rodLen = max(minRodFrac * screenH, rodLen)
        let tipAngle = atan2(rodLen + handTipPts, tipOffX)
        let rotation = aimAngle - tipAngle

        // Screen-space shadow (light from the top-left), counter-rotated into the
        // group's frame so it doesn't swing around with the stick.
        let lift = currentLift(screenH)
        let sx = lift * 0.6
        let sy = -lift
        let shadowOffset = CGSize(
            width: sx * cos(-rotation) - sy * sin(-rotation),
            height: sx * sin(-rotation) + sy * cos(-rotation)
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Pressed, the shadow tucks right under the hand: small, tight and a bit darker.
        for sub in [rodLayer, handLayer] {
            sub.shadowOffset = shadowOffset
            sub.shadowRadius = max(1, lift * 0.35) + 4 * pressAmount
            sub.shadowOpacity = showShadow ? Float(0.26 + 0.16 * pressAmount) * style.shadowStrength : 0
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

    // How far the shadow falls: the pointer's height above the glass, a little
    // lower while pressed.
    private func currentLift(_ screenH: CGFloat) -> CGFloat {
        liftFrac * screenH * (1 - 0.95 * pressAmount)
    }

    // Pressing makes the dot a touch bigger and the glow brighter.
    private func aimLaser(cursor: CGPoint) {
        let press = pressAmount
        let r = max(4, bounds.height * 0.0038 * handLenFrac / 0.13) * (1 + 0.2 * press)
        let core = r * 0.45
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        dotCore.path = CGPath(ellipseIn: CGRect(x: -core, y: -core, width: 2 * core, height: 2 * core), transform: nil)
        dotLayer.position = cursor
        dotLayer.shadowRadius = r * (2.2 + 1.0 * press)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        rodLayer.contentsScale = scale
        handLayer.contentsScale = scale
    }
}
