//
//  GenerateAppIcon.swift
//  ProxyPilot
//
//  Draws ProxyPilot's logo and writes every macOS app-icon size.
//
//      swift tools/GenerateAppIcon.swift
//
//  The shape is not guessed. It was derived from Apple's own macOS app icons:
//
//    * Artwork square — measured at 0.8047 of the canvas on a system icon with a
//      50% coverage threshold, which is Apple's documented 824pt square inside a
//      1024pt canvas.
//    * Corner curve — a cubic Bezier corner fitted to that icon's measured edge
//      profile: span r = 0.2605 of the square, tangent factor alpha = 0.672.
//      (A circular arc would need alpha = 0.4477; the real corner is much fuller.)
//
//  Each size is rasterised directly at its target pixel dimensions rather than
//  downscaling one bitmap, and the glyph is drawn slightly larger and heavier at
//  32pt and below so it stays readable in the Dock and in Finder list views.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry (all values are fractions of the 824pt artwork square)

enum Geometry {
    /// Apple's macOS artwork square inside the 1024pt canvas.
    static let artworkSquare: CGFloat = 824.0 / 1024.0
    /// Fitted corner span and tangent factor.
    static let cornerSpan: CGFloat = 0.2605
    static let cornerTangent: CGFloat = 0.672

    /// The mark is authored in its own units with the centre line at y = 0, then
    /// scaled to `fit` and centred on the artwork square's bounding box. That keeps
    /// it optically centred no matter how the proportions change.
    struct Mark {
        var trunkStartX: CGFloat
        var forkX: CGFloat
        var tipX: CGFloat
        var halfRise: CGFloat
        var strokeWidth: CGFloat
        var headLength: CGFloat
        var headHalfWidth: CGFloat
        /// Fraction of the artwork square the mark's longest edge occupies.
        var fit: CGFloat
        /// Extra breathing room added to the measured box, in artwork fractions.
        var padding: CGFloat
    }

    static let large = Mark(
        trunkStartX: 0.00, forkX: 0.92, tipX: 2.10, halfRise: 0.82,
        strokeWidth: 0.25, headLength: 0.56, headHalfWidth: 0.34,
        fit: 0.585, padding: 0.012
    )

    /// Bolder, wider and with a stubbier head so the mark survives at 16pt / 32pt.
    static let small = Mark(
        trunkStartX: 0.00, forkX: 0.92, tipX: 2.06, halfRise: 0.88,
        strokeWidth: 0.38, headLength: 0.48, headHalfWidth: 0.50,
        fit: 0.700, padding: 0.008
    )

    static func mark(forPixelSize size: CGFloat) -> Mark {
        size <= 32 ? small : large
    }
}

// MARK: - Palette

enum Palette {
    static let top = CGColor(srgbRed: 0.365, green: 0.596, blue: 1.000, alpha: 1)
    static let bottom = CGColor(srgbRed: 0.078, green: 0.325, blue: 0.843, alpha: 1)
    static let sheen = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22)
    static let glyph = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
}

// MARK: - Paths

/// Apple-style squircle: straight edges joined by a continuous corner curve.
func squirclePath(rect: CGRect) -> CGPath {
    let span = min(rect.width, rect.height) * Geometry.cornerSpan
    let tangent = Geometry.cornerTangent
    let minX = rect.minX, maxX = rect.maxX
    let minY = rect.minY, maxY = rect.maxY

    let path = CGMutablePath()

    // Start just after the top-left corner, travel clockwise.
    path.move(to: CGPoint(x: minX + span, y: minY))

    // Top edge → top-right corner
    path.addLine(to: CGPoint(x: maxX - span, y: minY))
    path.addCurve(
        to: CGPoint(x: maxX, y: minY + span),
        control1: CGPoint(x: maxX - span * (1 - tangent), y: minY),
        control2: CGPoint(x: maxX, y: minY + span * (1 - tangent))
    )

    // Right edge → bottom-right corner
    path.addLine(to: CGPoint(x: maxX, y: maxY - span))
    path.addCurve(
        to: CGPoint(x: maxX - span, y: maxY),
        control1: CGPoint(x: maxX, y: maxY - span * (1 - tangent)),
        control2: CGPoint(x: maxX - span * (1 - tangent), y: maxY)
    )

    // Bottom edge → bottom-left corner
    path.addLine(to: CGPoint(x: minX + span, y: maxY))
    path.addCurve(
        to: CGPoint(x: minX, y: maxY - span),
        control1: CGPoint(x: minX + span * (1 - tangent), y: maxY),
        control2: CGPoint(x: minX, y: maxY - span * (1 - tangent))
    )

    // Left edge → top-left corner
    path.addLine(to: CGPoint(x: minX, y: minY + span))
    path.addCurve(
        to: CGPoint(x: minX + span, y: minY),
        control1: CGPoint(x: minX, y: minY + span * (1 - tangent)),
        control2: CGPoint(x: minX + span * (1 - tangent), y: minY)
    )

    path.closeSubpath()
    return path
}

/// The mark: one route arrives, two routes leave.
/// Authored with the centre line at y = 0, then fitted and centred on `rect`.
/// Returns the stroke width in `rect` units so the caller can stroke the trunk at
/// exactly the scale the geometry was fitted with.
func markPaths(in rect: CGRect, mark: Geometry.Mark)
    -> (trunk: CGPath, heads: CGPath, lineWidth: CGFloat) {
    let fork = CGPoint(x: mark.forkX, y: 0)
    let trunkStart = CGPoint(x: mark.trunkStartX, y: 0)
    let upTip = CGPoint(x: mark.tipX, y: -mark.halfRise)
    let downTip = CGPoint(x: mark.tipX, y: mark.halfRise)

    func unit(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.0001)
        return CGPoint(x: dx / length, y: dy / length)
    }

    let upDirection = unit(fork, upTip)
    let downDirection = unit(fork, downTip)

    /// Where the shaft stops.
    ///
    /// The head has a straight base, so the shaft ends exactly one cap radius
    /// before it. The round cap's furthest point then lands precisely on the base
    /// plane: the two shapes meet flush, with no step where the narrow shaft meets
    /// the wide head and no bump sticking out behind it.
    func strokeEnd(tip: CGPoint, direction: CGPoint) -> CGPoint {
        let pullBack = max(mark.headLength - mark.strokeWidth / 2, 0)
        return CGPoint(x: tip.x - direction.x * pullBack, y: tip.y - direction.y * pullBack)
    }

    let trunk = CGMutablePath()
    trunk.move(to: trunkStart)
    trunk.addLine(to: fork)
    trunk.addLine(to: strokeEnd(tip: upTip, direction: upDirection))
    trunk.move(to: fork)
    trunk.addLine(to: strokeEnd(tip: downTip, direction: downDirection))

    func head(tip: CGPoint, direction: CGPoint) -> CGPath {
        let base = CGPoint(x: tip.x - direction.x * mark.headLength,
                           y: tip.y - direction.y * mark.headLength)
        let perpendicular = CGPoint(x: -direction.y, y: direction.x)
        let left = CGPoint(x: base.x + perpendicular.x * mark.headHalfWidth,
                           y: base.y + perpendicular.y * mark.headHalfWidth)
        let right = CGPoint(x: base.x - perpendicular.x * mark.headHalfWidth,
                            y: base.y - perpendicular.y * mark.headHalfWidth)
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: left)
        path.addLine(to: right)
        path.closeSubpath()
        return path
    }

    let heads = CGMutablePath()
    heads.addPath(head(tip: upTip, direction: upDirection))
    heads.addPath(head(tip: downTip, direction: downDirection))

    // Measure everything we actually paint, including the stroke's round caps.
    let union = CGMutablePath()
    union.addPath(trunk)
    union.addPath(heads)
    var box = union.boundingBoxOfPath
    let halfStroke = mark.strokeWidth / 2
    guard box.width > 0, box.height > 0 else {
        return (trunk, heads, max(mark.strokeWidth, 1))
    }
    box = box.insetBy(dx: -halfStroke, dy: -halfStroke)

    let target = rect.width * (mark.fit - mark.padding * 2)
    let scale = target / max(box.width, box.height)

    // p -> scale * (p - box centre) + rect centre, written out explicitly.
    // Note: CGAffineTransform's fluent translatedBy/scaledBy compose their argument
    // *before* the existing transform, which makes chained calls read backwards —
    // building the matrix directly avoids that trap.
    let transform = CGAffineTransform(
        a: scale, b: 0, c: 0, d: scale,
        tx: rect.midX - box.midX * scale,
        ty: rect.midY - box.midY * scale
    )

    let (fittedTrunk, fittedHeads): (CGPath, CGPath) = withUnsafePointer(to: transform) { pointer in
        (trunk.copy(using: pointer) ?? trunk, heads.copy(using: pointer) ?? heads)
    }

    return (fittedTrunk, fittedHeads, mark.strokeWidth * scale)
}

// MARK: - Rendering

func renderIcon(pixelSize: Int) -> CGImage? {
    let size = CGFloat(pixelSize)
    guard let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    // Flip so y increases downwards, matching the geometry above.
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)

    let inset = size * (1 - Geometry.artworkSquare) / 2
    let artRect = CGRect(x: inset, y: inset,
                         width: size * Geometry.artworkSquare,
                         height: size * Geometry.artworkSquare)

    let shape = squirclePath(rect: artRect)
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [Palette.top, Palette.bottom] as CFArray,
        locations: [0, 1]
    )!

    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: artRect.midX, y: artRect.minY),
        end: CGPoint(x: artRect.midX, y: artRect.maxY),
        options: []
    )
    // Soft top sheen, the way Apple's own icons catch the light.
    let sheen = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [Palette.sheen, CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        sheen,
        start: CGPoint(x: artRect.midX, y: artRect.minY),
        end: CGPoint(x: artRect.midX, y: artRect.minY + artRect.height * 0.55),
        options: []
    )
    context.restoreGState()

    // Glyph
    let mark = Geometry.mark(forPixelSize: size)
    let paths = markPaths(in: artRect, mark: mark)

    context.saveGState()
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(Palette.glyph)
    context.setFillColor(Palette.glyph)
    context.setLineWidth(paths.lineWidth)
    context.addPath(paths.trunk)
    context.strokePath()
    context.addPath(paths.heads)
    context.fillPath()
    context.restoreGState()

    // A hairline inside the edge keeps the silhouette crisp on light backgrounds.
    if size >= 128 {
        context.saveGState()
        context.addPath(shape)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
        context.setLineWidth(max(1, size / 512))
        context.strokePath()
        context.restoreGState()
    }

    return context.makeImage()
}

/// Renders the mark on its own, for the brand sheet and for inspecting the head
/// geometry at full scale.
func renderMark(pixelWidth: Int, pixelHeight: Int, color: CGColor) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(x: 1, y: -1)

    let rect = CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
    let mark = Geometry.large
    let paths = markPaths(in: rect, mark: mark)

    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(color)
    context.setFillColor(color)
    context.setLineWidth(paths.lineWidth)
    context.addPath(paths.trunk)
    context.strokePath()
    context.addPath(paths.heads)
    context.fillPath()

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "GenerateAppIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "GenerateAppIcon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "cannot finalise \(url.path)"])
    }
}

// MARK: - Entry point

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconSet = root.appendingPathComponent("managerproxy/Assets.xcassets/AppIcon.appiconset")
let reference = root.appendingPathComponent("docs/logo")

// name -> pixel size
let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

var rendered: [Int: CGImage] = [:]

for (name, size) in outputs {
    let image: CGImage
    if let cached = rendered[size] {
        image = cached
    } else if let fresh = renderIcon(pixelSize: size) {
        rendered[size] = fresh
        image = fresh
    } else {
        FileHandle.standardError.write("failed to render \(size)px\n".data(using: .utf8)!)
        exit(1)
    }
    try write(image, to: iconSet.appendingPathComponent(name))
    print("  \(name)  \(size)x\(size)")
}

if let master = rendered[1024] {
    try write(master, to: reference.appendingPathComponent("proxypilot-icon-1024.png"))
    print("  docs/logo/proxypilot-icon-1024.png")
}

// The mark on its own — a brand asset, and the quickest way to sanity-check the
// head geometry after changing any of the numbers above.
if let markImage = renderMark(pixelWidth: 1024, pixelHeight: 512,
                              color: CGColor(srgbRed: 0.176, green: 0.482, blue: 0.957, alpha: 1)) {
    try write(markImage, to: reference.appendingPathComponent("proxypilot-mark.png"))
    print("  docs/logo/proxypilot-mark.png")
}

// A small strip so the mark can be checked at Dock and Finder sizes.
if let master = rendered[1024] {
    let stripSizes = [16, 32, 64, 128, 256]
    let padded = 16
    let totalWidth = stripSizes.reduce(0) { $0 + $1 + padded } + padded
    let height = 256 + padded * 2
    if let context = CGContext(
        data: nil, width: totalWidth, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) {
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: height))
        var x = padded
        for size in stripSizes {
            let scaled = renderIcon(pixelSize: size) ?? master
            context.draw(scaled, in: CGRect(x: x, y: height - padded - size,
                                           width: size, height: size))
            x += size + padded
        }
        if let image = context.makeImage() {
            try write(image, to: reference.appendingPathComponent("proxypilot-icon-sizes.png"))
            print("  docs/logo/proxypilot-icon-sizes.png")
        }
    }
}

// MARK: - Asset catalog metadata
//
// The generator owns these files so the PNGs and the catalog can never drift.

func writeCatalogJSON(_ json: String, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try json.write(to: directory.appendingPathComponent("Contents.json"),
                   atomically: true, encoding: .utf8)
    print("  \(directory.lastPathComponent)/Contents.json")
}

let appIconEntries = """
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
"""

try writeCatalogJSON("""
{
  "images" : [
\(appIconEntries)  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

""", to: iconSet)

// The same artwork as a normal image set, for the sidebar brand mark.
let brandSet = root.appendingPathComponent("managerproxy/Assets.xcassets/BrandMark.imageset")
if let small = rendered[128], let large = rendered[256] {
    try write(small, to: brandSet.appendingPathComponent("BrandMark.png"))
    try write(large, to: brandSet.appendingPathComponent("BrandMark@2x.png"))
    print("  BrandMark.imageset/BrandMark.png + @2x")
}
try writeCatalogJSON("""
{
  "images" : [
    {
      "filename" : "BrandMark.png",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "filename" : "BrandMark@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

""", to: brandSet)

print("done")
