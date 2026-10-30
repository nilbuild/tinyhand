import AppKit

enum PointerStyle: String, CaseIterable {
    case lavender
    case glove
    case coral
    case plush
    case robot
    case pink
    case blue
    case mint
    case lemon
    case black
    case chrome
    case holo
    case fuzzy
    case wood
    case marble
    case terrazzo
    case glass
    case jelly
    case pastel
    case pixel
    case lowpoly
    case knit
    case skeleton
    case astro
    case space
    case monster
    case water
    case lava
    case grass
    case cactus
    case choco
    case cloud
    case laser

    static let defaultPinned: [PointerStyle] = [.lavender, .glove, .coral, .plush, .robot, .laser]

    var title: String {
        switch self {
        case .lavender: return "Lavender toy"
        case .glove: return "Cursor glove"
        case .coral: return "Coral vinyl"
        case .plush: return "Plush"
        case .robot: return "Robot"
        case .pink: return "Bubblegum"
        case .blue: return "Sky"
        case .mint: return "Mint"
        case .lemon: return "Lemon"
        case .black: return "Midnight"
        case .chrome: return "Chrome"
        case .holo: return "Holo"
        case .fuzzy: return "Fuzzy"
        case .wood: return "Wood"
        case .marble: return "Marble"
        case .terrazzo: return "Terrazzo"
        case .glass: return "Glass"
        case .jelly: return "Jelly"
        case .pastel: return "Pastel"
        case .pixel: return "Pixel"
        case .lowpoly: return "Low poly"
        case .knit: return "Knit"
        case .skeleton: return "Skeleton"
        case .astro: return "Astronaut"
        case .space: return "Space"
        case .monster: return "Monster"
        case .water: return "Water"
        case .lava: return "Lava"
        case .grass: return "Grass"
        case .cactus: return "Cactus"
        case .choco: return "Chocolate"
        case .cloud: return "Cloud"
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
        switch self {
        case .laser, .coral, .space: return Ink.red
        case .lavender, .glove, .holo, .fuzzy, .lowpoly, .knit: return Ink.purple
        case .plush, .blue, .astro, .cloud: return Ink.hex(0x2F86F0)
        case .robot, .mint: return Ink.hex(0x16A87A)
        case .pink, .pastel: return Ink.hex(0xEE4F98)
        case .lemon: return Ink.hex(0xF2B705)
        case .black, .pixel: return Ink.hex(0x1D1D21)
        case .chrome, .marble: return Ink.hex(0x6B7380)
        case .wood, .skeleton, .choco: return Ink.hex(0x9A5E2C)
        case .terrazzo, .lava: return Ink.hex(0xF0561D)
        case .glass, .water: return Ink.hex(0x1597E5)
        case .jelly: return Ink.hex(0xA33FE6)
        case .monster, .grass, .cactus: return Ink.hex(0x3E9E2E)
        }
    }

    private static let defaultsKey = "pointerStyle"

    static var saved: PointerStyle {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey)
            if raw == "dot" {
                return .laser
            }
            if raw == "sunny" {
                return .coral
            }
            return raw.flatMap(PointerStyle.init(rawValue:)) ?? .lavender
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

struct HandAsset {
    let image: CGImage
    let aspect: CGFloat
    let handTop: CGFloat
    let tip: CGFloat
    let wrist: CGFloat
    let rodEnd: CGFloat
    let tipX: CGFloat
    let rodX: CGFloat
    let handMinX: CGFloat
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

    private static var thumbnails: [String: NSImage] = [:]

    static func cachedThumbnail(_ name: String) -> NSImage? {
        thumbnails[name]
    }

    static func preloadThumbnails(_ names: [String], done: (() -> Void)? = nil) {
        let missing = names.filter { thumbnails[$0] == nil }
        guard !missing.isEmpty else {
            done?()
            return
        }
        DispatchQueue.global(qos: .utility).async {
            var built: [(String, NSImage)] = []
            for name in missing {
                if let thumb = loadImage(name).flatMap(measure)?.thumbnail {
                    built.append((name, thumb))
                }
            }
            DispatchQueue.main.async {
                for (name, thumb) in built where thumbnails[name] == nil {
                    thumbnails[name] = thumb
                }
                done?()
            }
        }
    }

    static func thumbnail(_ name: String) -> NSImage? {
        if let hit = thumbnails[name] {
            return hit
        }
        let asset = cache[name] ?? loadImage(name).flatMap(measure)
        guard let thumb = asset?.thumbnail else {
            return nil
        }
        thumbnails[name] = thumb
        return thumb
    }

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
        let px = 128
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(cgImage: cropped, size: NSSize(width: 64, height: 64))
        }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: px, height: px))
        guard let small = ctx.makeImage() else {
            return NSImage(cgImage: cropped, size: NSSize(width: 64, height: 64))
        }
        return NSImage(cgImage: small, size: NSSize(width: 64, height: 64))
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
