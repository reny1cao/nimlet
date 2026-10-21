import UIKit

/// The Mac's application icons, kept on the phone.
///
/// A dock draws applications, and an application drawn as a grey glyph is the
/// one thing on this screen that does not look like what it is. The icons come
/// from the Mac — it is the machine that has them — and they are kept here
/// because they are the same fifteen kilobytes every launch, and because a dock
/// that has to wait for a connection before it can draw itself flashes a row of
/// placeholders every time the app is opened.
///
/// On disk in Caches on purpose: iOS may take the folder back under pressure,
/// which costs nothing — the phone asks the Mac for the icons of its own
/// targets on every connection, and until they arrive the tiles wear the
/// glyphs they always did.
@MainActor
final class AppIconStore {
    private(set) var images: [String: UIImage] = [:]

    /// How much bigger than its own canvas each icon has to be drawn.
    ///
    /// A Mac icon is drawn on a grid with transparent margin around it: the
    /// rounded square that *is* the icon occupies about four fifths of the
    /// picture, and the rest is the space macOS leaves for the shadow and the
    /// odd icon that breaks the grid deliberately. Draw that picture at the
    /// same size as a filled glyph tile beside it and the app reads a size
    /// smaller than the glyph — which is backwards, because the artwork is the
    /// thing that identifies the target and the glyph is the fallback.
    ///
    /// So each icon is measured once, and drawn so its own opaque pixels fill
    /// the tile the glyph fills. Measured rather than assumed at 1.25: not
    /// every icon keeps to the grid, and a circular one or one that already
    /// fills its canvas would be blown through the edges of the tile by a
    /// constant.
    private var scales: [String: CGFloat] = [:]

    private let directory: URL?

    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("AppIcons", isDirectory: true)
        load()
    }

    func icon(for bundleID: String?) -> UIImage? {
        guard let bundleID else { return nil }
        return images[bundleID.lowercased()]
    }

    /// The factor that makes this icon's artwork the size of the tile.
    ///
    /// 1 for anything that has not been measured or that fills its canvas
    /// already, and never more than `maximumScale` — an icon whose opaque
    /// pixels are a small badge in the middle of a big transparent square is a
    /// misdrawn icon, not an invitation to magnify it four times.
    func contentScale(for bundleID: String?) -> CGFloat {
        guard let bundleID else { return 1 }
        let key = bundleID.lowercased()
        if let known = scales[key] { return known }
        guard let image = images[key] else { return 1 }
        let scale = Self.scale(filling: image)
        scales[key] = scale
        return scale
    }

    private static let maximumScale: CGFloat = 1.32

    /// Scans the alpha channel for the box the artwork actually occupies.
    ///
    /// At 64 points a side, which is plenty: this is deciding a scale factor
    /// to two decimal places, not tracing an outline. The alpha floor is low
    /// but not zero — a drop shadow is part of the picture and not part of the
    /// icon, and every Mac icon has one.
    private static func scale(filling image: UIImage) -> CGFloat {
        guard let source = image.cgImage else { return 1 }
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels,
                                      width: side, height: side,
                                      bitsPerComponent: 8,
                                      bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 1 }
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))

        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where pixels[(y * side + x) * 4 + 3] > 40 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return 1 }
        let filled = max(CGFloat(maxX - minX + 1), CGFloat(maxY - minY + 1)) / CGFloat(side)
        guard filled > 0.01 else { return 1 }
        return min(max(1 / filled, 1), maximumScale)
    }

    /// Folds a catalogue's icons in. Returns whether anything actually changed,
    /// so a chunk that carried no pictures does not redraw the dock.
    @discardableResult
    func absorb(_ apps: [MacApp]) -> Bool {
        var changed = false
        for app in apps {
            guard let data = app.icon, !data.isEmpty,
                  let image = UIImage(data: data) else { continue }
            let key = app.bundleID.lowercased()
            // The Mac re-renders an icon every time its cache is cold, and the
            // bytes are not guaranteed identical; comparing them is not worth
            // it, but writing the same picture to disk on every reconnect is
            // not worth it either.
            if images[key] == nil { write(data, for: key) }
            images[key] = image
            changed = true
        }
        return changed
    }

    /// Which of these the phone cannot draw yet — the list it should ask the
    /// Mac for, and nothing more than that.
    func missing(from bundleIDs: [String]) -> [String] {
        var asked = Set<String>()
        return bundleIDs.filter { bundleID in
            let key = bundleID.lowercased()
            guard images[key] == nil else { return false }
            return asked.insert(key).inserted
        }
    }

    // MARK: - Disk

    /// A bundle identifier is dots and letters in practice, but it arrives over
    /// a network from a machine this phone does not control, so it is not
    /// allowed to name a file until it has been reduced to something that can
    /// only be one.
    private static func filename(for key: String) -> String {
        let safe = key.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character : "-"
        }
        return String(safe) + ".png"
    }

    private func load() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "png" {
            guard let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { continue }
            images[file.deletingPathExtension().lastPathComponent] = image
        }
    }

    private func write(_ data: Data, for key: String) {
        guard let directory else { return }
        let url = directory.appendingPathComponent(Self.filename(for: key))
        // Off the main thread: a dozen icons land together in one chunk, and
        // the dock is drawing while they do.
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// How big an SF Symbol has to be drawn to weigh what the artwork beside it
/// weighs.
///
/// A dock with both in it has a problem the tile size cannot fix: every tile
/// is 56 points, but a Mac icon fills its 56 and a symbol is a few strokes
/// somewhere inside them. Worse, symbols do not agree with each other — at one
/// font size `terminal` is a wide rectangle covering most of its line while
/// `cursorarrow.click` is a small mark in the middle of one, and font size is
/// cap height, which neither of them is made of.
///
/// So each symbol is measured the same way the artwork is: drawn once, scanned
/// for the box its ink actually occupies, and then sized so that box is the
/// same fraction of the tile for all of them. What comes out is a row where
/// the eye finds the tiles equally heavy — which is what "the same size" was
/// supposed to mean.
enum SymbolInk {
    /// The ink's larger side, per point of font size. Measured once per symbol.
    private static var measured: [String: CGFloat] = [:]

    /// The font size at which this symbol's ink is `fraction` of `side`.
    ///
    /// Falls back to the fraction itself for a symbol that could not be
    /// measured, which is the old fixed proportion and never worse than it.
    @MainActor
    static func size(of name: String, filling side: CGFloat, fraction: CGFloat) -> CGFloat {
        let ink = measured[name] ?? measure(name)
        guard ink > 0.05 else { return side * fraction }
        return side * fraction / ink
    }

    @MainActor
    private static func measure(_ name: String) -> CGFloat {
        let probe: CGFloat = 96
        let configuration = UIImage.SymbolConfiguration(pointSize: probe, weight: .medium)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration) else {
            measured[name] = 0
            return 0
        }
        // Drawn into a canvas comfortably larger than the symbol so nothing
        // touches an edge and the scan cannot mistake a clipped stroke for the
        // end of the ink.
        let canvas = Int(probe * 2)
        var pixels = [UInt8](repeating: 0, count: canvas * canvas * 4)
        guard let context = CGContext(data: &pixels,
                                      width: canvas, height: canvas,
                                      bitsPerComponent: 8,
                                      bytesPerRow: canvas * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let drawn = symbol.withTintColor(.white, renderingMode: .alwaysOriginal).cgImage
        else {
            measured[name] = 0
            return 0
        }
        let box = CGRect(x: (CGFloat(canvas) - symbol.size.width) / 2,
                         y: (CGFloat(canvas) - symbol.size.height) / 2,
                         width: symbol.size.width, height: symbol.size.height)
        context.draw(drawn, in: box)

        var minX = canvas, minY = canvas, maxX = -1, maxY = -1
        for y in 0..<canvas {
            for x in 0..<canvas where pixels[(y * canvas + x) * 4 + 3] > 32 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else {
            measured[name] = 0
            return 0
        }
        let ink = max(CGFloat(maxX - minX + 1), CGFloat(maxY - minY + 1)) / probe
        measured[name] = ink
        return ink
    }
}
