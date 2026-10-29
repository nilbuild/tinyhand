import AppKit

// The pointers the user can pick from the toolbar: a few toy hands on sticks, and
// a small red laser dot. Each hand is one vertical image (hand on top, stick below); its
// fingertip, wrist and rod are found from the image's alpha when it loads, so a new
// hand only needs a new PNG.
enum PointerStyle: String, CaseIterable {
    case lavender
    case glove
    case sunny
    case plush
    case robot
    case laser

    var title: String {
        switch self {
        case .lavender: return "Lavender toy"
        case .glove: return "Cursor glove"
        case .sunny: return "Sunny vinyl"
        case .plush: return "Plush"
        case .robot: return "Robot"
        case .laser: return "Laser dot"
        }
    }

    var assetName: String? {
        switch self {
        case .laser: return nil
        default: return "hand_\(rawValue)"
        }
    }

    var inkColor: CGColor {
        self == .laser ? Ink.red : Ink.purple
    }

    private static let defaultsKey = "pointerStyle"

    static var saved: PointerStyle {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey)
            if raw == "dot" {
                return .laser // renamed
            }
            return raw.flatMap(PointerStyle.init(rawValue:)) ?? .lavender
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

// A hand image plus where things are in it, as fractions measured top-down from
// the image's top-left.
struct HandAsset {
    let image: CGImage
    let aspect: CGFloat     // width / height
    let handTop: CGFloat    // a little headroom above the fingertip
    let tip: CGFloat        // fingertip
    let wrist: CGFloat      // where the hand meets the stick
    let rodEnd: CGFloat     // where the stick ends, or a handle begins
    let tipX: CGFloat       // finger centerline
    let rodX: CGFloat       // stick axis
    let handMinX: CGFloat   // the hand's horizontal extent, for thumbnails
    let handMaxX: CGFloat

    private static var cache: [String: HandAsset] = [:]

    static func load(_ name: String) -> HandAsset? {
        if let hit = cache[name] {
            return hit
        }
        guard let image = loadImage(name), let asset = measure(image) else {
            return nil
        }
        cache[name] = asset
        return asset
    }

    // A square crop hugging the hand, for toolbar buttons.
    var thumbnail: NSImage {
        let h = CGFloat(image.height)
        let w = CGFloat(image.width)
        let handW = (handMaxX - handMinX) * w
        let handH = (wrist - handTop) * h
        let side = max(handW, handH) * 1.06
        let cx = (handMinX + handMaxX) / 2 * w
        let cy = (handTop + wrist) / 2 * h
        let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        let cropped = image.cropping(to: rect) ?? image
        return NSImage(cgImage: cropped, size: NSSize(width: 64, height: 64))
    }

    private static func measure(_ image: CGImage) -> HandAsset? {
        let w = image.width
        let h = image.height
        var alpha = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &alpha, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Row 0 of the buffer is the image's top row.
        func count(_ y: Int) -> Int {
            var n = 0
            let row = y * w
            for x in 0..<w where alpha[row + x] > 128 {
                n += 1
            }
            return n
        }
        func center(_ y: Int) -> CGFloat {
            let row = y * w
            var lo = -1
            var hi = -1
            for x in 0..<w where alpha[row + x] > 128 {
                if lo < 0 {
                    lo = x
                }
                hi = x
            }
            return lo < 0 ? 0.5 : CGFloat(lo + hi) / 2 / CGFloat(w)
        }

        let counts = (0..<h).map(count)
        guard let top = counts.firstIndex(where: { $0 > 0 }) else {
            return nil
        }
        let searchEnd = min(h, top + Int(0.45 * Double(h)))
        let maxW = counts[top..<searchEnd].max() ?? 0
        guard maxW > 0,
              let fist = (top..<h).first(where: { Double(counts[$0]) > 0.6 * Double(maxW) }),
              let wrist = (fist..<h).first(where: { Double(counts[$0]) < 0.35 * Double(maxW) }) else {
            return nil
        }
        let rodW = counts[min(h - 1, wrist + h / 50)]
        let lastRow = counts.lastIndex(where: { $0 > 0 }) ?? (h - 1)
        let from = min(h - 1, wrist + h / 33)
        let handle = (from..<h).first(where: { Double(counts[$0]) > 1.8 * Double(rodW) })
        let rodEnd = handle ?? lastRow

        var minX = w
        var maxX = 0
        for y in top..<wrist {
            let row = y * w
            for x in 0..<w where alpha[row + x] > 128 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }

        let fh = CGFloat(h)
        return HandAsset(
            image: image,
            aspect: CGFloat(w) / fh,
            handTop: max(0, CGFloat(top) - 0.004 * fh) / fh,
            tip: CGFloat(top) / fh,
            wrist: CGFloat(wrist) / fh,
            rodEnd: CGFloat(rodEnd) / fh,
            tipX: center(min(h - 1, top + h / 200)),
            rodX: center((wrist + rodEnd) / 2),
            handMinX: CGFloat(minX) / CGFloat(w),
            handMaxX: CGFloat(maxX) / CGFloat(w)
        )
    }

    private static func loadImage(_ name: String) -> CGImage? {
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        var urls: [URL] = []
        if let u = Bundle.main.url(forResource: name, withExtension: "png") {
            urls.append(u)
        }
        urls.append(exeDir.appendingPathComponent("\(name).png"))
        urls.append(exeDir.appendingPathComponent("assets/\(name).png"))
        urls.append(URL(fileURLWithPath: "assets/\(name).png"))
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url),
               let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return cg
            }
        }
        return nil
    }
}
