import AppKit
import CoreGraphics
import Foundation

// Reproducible, opaque 1024 px source for the iOS app icon. Xcode's asset
// compiler derives the device-specific sizes from this image.
//
// The mark is Nimlet's N milled into a brushed metal face. The light does not
// sit on top of the metal — it lives inside the cut, welling up the channels
// and pooling at the foot of each stroke, which is what keeps the icon reading
// as an object rather than a glyph on a background.
let size = 1024
let output = CommandLine.arguments.dropFirst().first
    ?? "NimletRemote/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create icon bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.setAllowsAntialiasing(true)

/// The artwork is laid out in the same top-left coordinates as the design
/// comps; CoreGraphics draws from the bottom left.
func flip(_ y: CGFloat) -> CGFloat { CGFloat(size) - y }

// The anodized face. Light falls from the top left, so the grade runs down to
// the opposite corner.
let face = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.212, green: 0.231, blue: 0.263, alpha: 1),
        CGColor(red: 0.078, green: 0.090, blue: 0.106, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(face,
                           start: CGPoint(x: 0, y: flip(0)),
                           end: CGPoint(x: CGFloat(size), y: flip(CGFloat(size))),
                           options: [])

// Brushing. Vertical hairlines at a 10 px pitch: a light one and, offset by
// half the pitch, a darker one. Invisible at 29 pt and the whole reason the
// face reads as metal at 1024.
for x in stride(from: 0, to: size, by: 10) {
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.05))
    context.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: CGFloat(size)))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.10))
    context.fill(CGRect(x: CGFloat(x + 5), y: 0, width: 1, height: CGFloat(size)))
}

// The N, as a centre line. Everything else is this path at a different width.
let mark = CGMutablePath()
mark.move(to: CGPoint(x: 352, y: flip(740)))
mark.addLine(to: CGPoint(x: 352, y: flip(288)))
mark.addLine(to: CGPoint(x: 672, y: flip(740)))
mark.addLine(to: CGPoint(x: 672, y: flip(288)))

func stroked(_ width: CGFloat) -> CGPath {
    mark.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

// Light escaping the cut and washing the metal around it. Drawn as one filled
// path so the overlapping strokes of the N do not double up.
context.addPath(stroked(212))
context.setFillColor(CGColor(red: 0.545, green: 0.788, blue: 1.0, alpha: 0.13))
context.fillPath()

// The chamfer: the bevelled lip of the cut, catching the same light as the face.
context.addPath(stroked(148))
context.setFillColor(CGColor(red: 0.255, green: 0.282, blue: 0.325, alpha: 1))
context.fillPath()

// Everything from here happens inside the cut.
context.saveGState()
context.addPath(stroked(120))
context.clip()

context.setFillColor(CGColor(red: 0.020, green: 0.031, blue: 0.047, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))

// Three stops, not two: a straight fade from clear to white passes through
// grey and loses the blue entirely. The saturated stop in the middle is what
// makes the light read as Nimlet's colour rather than as a chrome bevel.
let inside = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.353, green: 0.620, blue: 0.925, alpha: 0),
        CGColor(red: 0.353, green: 0.620, blue: 0.925, alpha: 0.92),
        CGColor(red: 0.886, green: 0.953, blue: 1.0, alpha: 1),
    ] as CFArray,
    locations: [0, 0.52, 1]
)!
// Dark at the top of the channel, full brightness by the feet — and held
// there, so each stroke ends in a pool of light.
context.drawLinearGradient(inside,
                           start: CGPoint(x: 0, y: flip(300)),
                           end: CGPoint(x: 0, y: flip(740)),
                           options: [.drawsAfterEndLocation])

context.restoreGState()

graphics.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

// App Store Connect rejects icon PNGs with an alpha channel, even when every
// pixel is opaque. Re-encode through an RGB bitmap to remove that channel.
guard let rgbData = bitmap.representation(using: .jpeg,
                                          properties: [.compressionFactor: 1.0]),
      let rgbBitmap = NSBitmapImageRep(data: rgbData),
      let png = rgbBitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon PNG")
}
try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: output).deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: URL(fileURLWithPath: output))
