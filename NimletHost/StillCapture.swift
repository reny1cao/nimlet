import AppKit
import ScreenCaptureKit

/// One photograph of the screen, for the phone to draw on.
///
/// `SCScreenshotManager` rather than the mirror's running stream: a still wants
/// the sharpest single frame available, at a moment that has nothing to do with
/// whether the panel is open, and it must not disturb a capture already in
/// flight. It also means the still is a *fresh* picture of what is on the
/// monitor now, not the last frame an encoder happened to produce.
enum StillCapture {

    struct Still {
        var png: Data
        var pixelSize: CGSize
        /// What was photographed, for the phone to put above the canvas.
        var title: String
    }

    enum Refusal: Error {
        case notGranted
        case noWindow(String)
        case noDisplay
        case failed(String)

        var message: String {
            switch self {
            case .notGranted:
                return "Grant Nimlet Screen Recording first — it's in the Nimlet menu"
            case .noWindow(let name):
                return "Couldn't find a window for \(name)"
            case .noDisplay:
                return "Couldn't find a display to photograph"
            case .failed(let reason):
                return "Screenshot failed: \(reason)"
            }
        }
    }

    /// What to photograph, from what the target is.
    ///
    /// An `app` target is a window, and the window is the interesting thing: its
    /// own bounds, without the desktop or whatever is stacked on top of it. A
    /// pane is not a window anybody can name — tmux panes live inside a terminal
    /// Nimlet has no handle on — so for those the answer is the display, which is
    /// also what someone circling something on their monitor actually wants.
    static func capture(_ target: NimletTarget, maxLongEdge: Int) async -> Result<Still, Refusal> {
        ScreenAccess.requestOnceIfNeeded()
        guard ScreenAccess.isGranted else { return .failure(.notGranted) }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false) else {
            return .failure(.failed("ScreenCaptureKit returned nothing"))
        }

        switch target.kind {
        case .app, .frontmost:
            let wanted = target.kind == .app
                ? target.bundleID
                : NSRunningApplication.frontmost?.bundleIdentifier
            guard let wanted, let window = bestWindow(of: wanted, in: content) else {
                // A `frontmost` target with nothing findable in front used to
                // fall back to photographing the whole display — every app's
                // windows, not the one the user had in mind — without saying
                // so anywhere. The pane case documents that fallback and asks
                // for it; this one did neither, so it refuses instead.
                return .failure(.noWindow(target.name))
            }
            let title = window.owningApplication?.applicationName ?? target.name
            return await shoot(filter: SCContentFilter(desktopIndependentWindow: window),
                               points: window.frame.size,
                               title: title,
                               maxLongEdge: maxLongEdge)

        case .tmux:
            return await capture(display: content, maxLongEdge: maxLongEdge)
        }
    }

    private static func capture(display content: SCShareableContent,
                                maxLongEdge: Int) async -> Result<Still, Refusal> {
        // The display the pointer is on, which is the one being looked at.
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
        let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first else {
            return .failure(.noDisplay)
        }
        return await shoot(filter: SCContentFilter(display: display, excludingWindows: []),
                           points: CGSize(width: display.width, height: display.height),
                           title: NSScreen.screens.count > 1 ? "Display \(display.displayID)" : "Screen",
                           maxLongEdge: maxLongEdge)
    }

    private static func shoot(filter: SCContentFilter,
                              points: CGSize,
                              title: String,
                              maxLongEdge: Int) async -> Result<Still, Refusal> {
        let config = SCStreamConfiguration()
        let size = outputSize(points: points, maxLongEdge: maxLongEdge)
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.captureResolution = .best
        config.showsCursor = false

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                  configuration: config)
            guard let png = png(from: image) else {
                return .failure(.failed("couldn't encode the screenshot"))
            }
            return .success(Still(png: png,
                                  pixelSize: CGSize(width: image.width, height: image.height),
                                  title: title))
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    /// Capped at what the phone asked for, and never upscaled: a window smaller
    /// than the ceiling is photographed at its own backing resolution, which is
    /// as much detail as exists.
    private static func outputSize(points: CGSize, maxLongEdge: Int) -> CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = CGSize(width: max(points.width * scale, 1), height: max(points.height * scale, 1))
        let longEdge = max(pixels.width, pixels.height)
        let ceiling = Double(max(maxLongEdge, 320))
        let factor = min(1, ceiling / longEdge)
        return CGSize(width: (pixels.width * factor).rounded(.down),
                      height: (pixels.height * factor).rounded(.down))
    }

    private static func png(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])
    }

    private static func bestWindow(of bundleID: String, in content: SCShareableContent) -> SCWindow? {
        let candidates = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == bundleID
                && window.windowLayer == 0
                && window.frame.width > 120
                && window.frame.height > 120
        }
        // The same preference the mirror uses: the window the user is in, then
        // anything visible, then the biggest — an app's palettes are windows too.
        return candidates.max { lhs, rhs in
            (lhs.isActive ? 1 : 0, lhs.isOnScreen ? 1 : 0, lhs.frame.width * lhs.frame.height)
                < (rhs.isActive ? 1 : 0, rhs.isOnScreen ? 1 : 0, rhs.frame.width * rhs.frame.height)
        }
    }
}

private extension NSRunningApplication {
    /// Nimlet itself is never the answer: it has no window worth photographing and
    /// it is frequently the frontmost thing when the phone is being used.
    static var frontmost: NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return front
    }
}
