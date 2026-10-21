import CoreGraphics

/// How much of the mirror is on screen, and which part.
///
/// The picture is drawn to fill the card, so at rest the card shows all of the
/// window along its tight axis and loses a little off the other. Zooming in
/// shows less of it; this is the arithmetic for "less of it", kept in one place
/// because three things have to agree about it exactly: what the video layer is
/// drawn at, where a finger on the card lands in the window, and how far a
/// two-finger drag moves the view.
///
/// Everything here is in fractions of the picture, never in points or pixels. A
/// fraction survives the card changing size, the Mac changing the encode
/// resolution and the window being resized, all of which happen while you are
/// looking at it.
struct MirrorFocus: Equatable {
    /// 1 is the whole picture on the card; 4 is a quarter of it in each axis.
    var zoom: CGFloat = 1
    /// The point of the picture sitting at the middle of the card.
    var centre = CGPoint(x: 0.5, y: 0.5)

    /// Where zoom stops being worth offering.
    ///
    /// It used to be 6, chosen when the whole window was the only thing the Mac
    /// ever sent: past about 3x of a fitted window that stream has fewer pixels
    /// for the part on screen than the phone has to draw it with, and the rest
    /// of the range was enlarging blur. Past 3x the Mac is now asked for the
    /// region instead of the window, so the pixels are real that far in and
    /// this is a limit on what is useful rather than on what is sharp.
    static let maximumZoom: CGFloat = 8

    /// How close the mirror opens.
    ///
    /// A Mac window fitted whole onto a phone held in the hand is an honest
    /// picture of it and not a readable one: a 656pt window drawn 402pt wide
    /// is Mac text at two thirds size. So the mirror opens in — far enough to
    /// read, near enough to still tell which window it is — and a two-finger
    /// tap puts the whole window back.
    ///
    /// 2.2 rather than however far it takes to fill the glass: for a window
    /// much wider than the phone, filling means a tenth of it on screen and
    /// no way to tell which tenth.
    static let readingZoom: CGFloat = 2.2

    var isZoomed: Bool { zoom > 1.001 }

    /// The zoom that would fill the card, leaving no bar on either side.
    ///
    /// 1 for a picture that is already the card's shape, and large for a
    /// landscape window on an upright phone.
    static func fillingZoom(card: CGSize, picture: CGSize) -> CGFloat {
        guard card.width > 0, card.height > 0, picture.width > 0, picture.height > 0 else { return 1 }
        let fit = min(card.width / picture.width, card.height / picture.height)
        let fill = max(card.width / picture.width, card.height / picture.height)
        return max(fill / fit, 1)
    }

    /// How the mirror opens: in far enough to read, at the corner the window
    /// starts from.
    ///
    /// Top-left rather than the middle, because that is where a window puts
    /// the things that say what it is — its title, its toolbar, the first line
    /// of whatever is in it — and because text is read from there.
    static func opening(card: CGSize, picture: CGSize) -> MirrorFocus {
        var focus = MirrorFocus()
        guard card.width > 0, card.height > 0, picture.width > 0, picture.height > 0 else { return focus }
        focus.zoom = min(fillingZoom(card: card, picture: picture), readingZoom)
        let size = focus.visible(card: card, picture: picture)
        focus.centre = CGPoint(x: size.width / 2, y: size.height / 2)
        return focus
    }

    /// The size the whole picture is drawn at, in the card's own points.
    ///
    /// At zoom 1 it is the largest box of the picture's shape that fits the
    /// card — the whole window, with a bar wherever the card is the wrong
    /// shape for it. Zooming multiplies that, and the card shows less of it.
    ///
    /// The card is free to be any shape at all, which is the point: the
    /// full-screen mirror hands over the whole screen rather than a box cut to
    /// the window, so that zooming in fills the glass instead of enlarging the
    /// picture inside the same small band.
    func drawn(card: CGSize, picture: CGSize) -> CGSize {
        guard card.width > 0, card.height > 0, picture.width > 0, picture.height > 0 else { return card }
        let fit = min(card.width / picture.width, card.height / picture.height)
        return CGSize(width: picture.width * fit * zoom, height: picture.height * fit * zoom)
    }

    /// How much of the picture fits the card, per axis, at this zoom.
    ///
    /// All of it along an axis the drawing does not overflow — that axis has a
    /// bar rather than a crop.
    func visible(card: CGSize, picture: CGSize) -> CGSize {
        let drawn = drawn(card: card, picture: picture)
        guard drawn.width > 0, drawn.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: min(card.width / drawn.width, 1),
                      height: min(card.height / drawn.height, 1))
    }

    /// That much of the picture, positioned — clamped so the card never shows
    /// past an edge into nothing.
    func region(card: CGSize, picture: CGSize) -> CGRect {
        let size = visible(card: card, picture: picture)
        let x = min(max(centre.x - size.width / 2, 0), 1 - size.width)
        let y = min(max(centre.y - size.height / 2, 0), 1 - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Where the picture's top-left corner lands on the card: whatever puts
    /// the middle of the visible region in the middle of the card.
    func origin(card: CGSize, picture: CGSize) -> CGPoint {
        let drawn = drawn(card: card, picture: picture)
        let region = region(card: card, picture: picture)
        return CGPoint(x: card.width / 2 - region.midX * drawn.width,
                       y: card.height / 2 - region.midY * drawn.height)
    }

    /// Whether a point on the card is on the picture at all.
    ///
    /// The card is the whole screen; the picture is a rectangle somewhere
    /// inside it with black around it wherever the window is the wrong shape
    /// for the glass. Only the rectangle is the Mac.
    func contains(_ point: CGPoint, card: CGSize, picture: CGSize) -> Bool {
        let drawn = drawn(card: card, picture: picture)
        guard drawn.width > 0, drawn.height > 0 else { return false }
        let origin = origin(card: card, picture: picture)
        return point.x >= origin.x && point.x <= origin.x + drawn.width
            && point.y >= origin.y && point.y <= origin.y + drawn.height
    }

    /// Where a point on the card is in the picture.
    ///
    /// Clamped, because this is also asked about a drag that began on the
    /// window and has been pulled off the edge of it — which the Mac should
    /// see running along that edge. A touch that *starts* outside never gets
    /// here; `contains` refuses it.
    func picturePoint(at point: CGPoint, card: CGSize, picture: CGSize) -> CGPoint {
        let drawn = drawn(card: card, picture: picture)
        guard drawn.width > 0, drawn.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let origin = origin(card: card, picture: picture)
        return CGPoint(x: min(max((point.x - origin.x) / drawn.width, 0), 1),
                       y: min(max((point.y - origin.y) / drawn.height, 0), 1))
    }

    /// Where a point of the picture falls on the card: the inverse of
    /// `picturePoint`, and exactly the placement the view performs.
    func pointOnCard(_ inPicture: CGPoint, card: CGSize, picture: CGSize) -> CGPoint {
        let drawn = drawn(card: card, picture: picture)
        let origin = origin(card: card, picture: picture)
        return CGPoint(x: origin.x + inPicture.x * drawn.width,
                       y: origin.y + inPicture.y * drawn.height)
    }

    /// Zoom, holding one point of the picture still on the glass.
    ///
    /// The anchor is the point between the fingers, so what you are pinching
    /// stays where your fingers are. Zooming about the middle instead would
    /// carry whatever you had picked out off the side of the card.
    ///
    /// Framed as "where is it on the glass, and what centre puts it back
    /// there", because the shorter version of this — hold its position within
    /// the visible *region* — is only the same thing when the region fills the
    /// card, and it does not. A landscape Mac window on an upright phone has a
    /// bar above and below it and its vertical axis is entirely visible, so the
    /// region's own coordinates and the glass's are offset by the bar; pinching
    /// such a window slid it by the height of that bar on the first frame of
    /// every gesture. Which is every gesture, on the commonest window there is.
    mutating func magnify(by factor: CGFloat, about anchor: CGPoint,
                          card: CGSize, picture: CGSize) {
        guard factor.isFinite, factor > 0 else { return }
        let held = pointOnCard(anchor, card: card, picture: picture)
        zoom = min(max(zoom * factor, 1), Self.maximumZoom)
        let after = drawn(card: card, picture: picture)
        guard after.width > 0, after.height > 0 else { return }
        // Whatever puts the anchor back under the same point of the glass. The
        // clamp below overrules it at an edge, which is the right way round:
        // holding a point still is worth less than never showing past the
        // window into nothing.
        centre = CGPoint(x: anchor.x + (card.width / 2 - held.x) / after.width,
                         y: anchor.y + (card.height / 2 - held.y) / after.height)
        clamp(card: card, picture: picture)
    }

    /// Two fingers on the mirror, moving the picture with them.
    mutating func pan(by translation: CGSize, card: CGSize, picture: CGSize) {
        guard card.width > 0, card.height > 0 else { return }
        let size = visible(card: card, picture: picture)
        centre.x -= translation.width / card.width * size.width
        centre.y -= translation.height / card.height * size.height
        clamp(card: card, picture: picture)
    }

    /// Keep a point of the picture in view, moving as little as possible.
    ///
    /// A camera that follows rather than one that centres. The view does not
    /// move at all while the point is comfortably inside it, and pans only once
    /// the point comes within `margin` of an edge — and then only far enough to
    /// put it back on the margin.
    ///
    /// Centring on the point instead would be simpler and unusable: the pointer
    /// is never still, so the picture would slide continuously under a cursor
    /// that is only twitching, and a zoomed mirror would be a thing you cannot
    /// read while your thumb is on the pad.
    ///
    /// - Parameter margin: how close to the edge the point may come, as a
    ///   fraction of what is visible. 0.2 leaves a fifth of the view as the band
    ///   that triggers a pan.
    mutating func keep(_ point: CGPoint, inViewWithin margin: CGFloat,
                       card: CGSize, picture: CGSize) {
        guard isZoomed else { return }
        let size = visible(card: card, picture: picture)
        guard size.width > 0, size.height > 0 else { return }
        let region = region(card: card, picture: picture)
        let inset = CGSize(width: size.width * margin, height: size.height * margin)

        if point.x < region.minX + inset.width {
            centre.x -= region.minX + inset.width - point.x
        } else if point.x > region.maxX - inset.width {
            centre.x += point.x - (region.maxX - inset.width)
        }
        if point.y < region.minY + inset.height {
            centre.y -= region.minY + inset.height - point.y
        } else if point.y > region.maxY - inset.height {
            centre.y += point.y - (region.maxY - inset.height)
        }
        clamp(card: card, picture: picture)
    }

    /// Back to the whole picture.
    mutating func reset() {
        zoom = 1
        centre = CGPoint(x: 0.5, y: 0.5)
    }

    private mutating func clamp(card: CGSize, picture: CGSize) {
        let size = visible(card: card, picture: picture)
        centre.x = min(max(centre.x, size.width / 2), 1 - size.width / 2)
        centre.y = min(max(centre.y, size.height / 2), 1 - size.height / 2)
    }
}

/// Everything the mirror's picture is doing, in one value.
///
/// Held together rather than spread across the view because four things have to
/// agree about it exactly, and disagree invisibly when they do not: the size the
/// video layer is drawn at, where inside the window a finger on the glass lands,
/// how far a two-finger drag moves the view, and what the Mac is asked to send.
///
/// `picture` is the window, never the frames. See `panelPoint`.
struct MirrorState: Equatable {
    var focus = MirrorFocus()
    /// The part of the picture last touched — what the zoom holds still, and
    /// where the Mac's pointer now is.
    var anchor = CGPoint(x: 0.5, y: 0.5)
    /// Measured by the card as it lays out.
    var card = CGSize.zero
    /// The whole window being mirrored, in whatever units describe it — only
    /// its shape is ever used, so the frames' pixels and the window's points
    /// are equally good numbers to put here. Not the size of the arriving
    /// frames: those are a crop of this once the zoom has gone far enough.
    var picture = CGSize.zero

    var canZoom: Bool { card.width > 0 && card.height > 0 && picture.width > 0 && picture.height > 0 }

    mutating func magnify(by factor: CGFloat) {
        guard canZoom else { return }
        focus.magnify(by: factor, about: anchor, card: card, picture: picture)
    }

    mutating func pan(by translation: CGSize) {
        guard canZoom else { return }
        focus.pan(by: translation, card: card, picture: picture)
    }

    /// The whole picture, and back to reading it.
    ///
    /// Here rather than in the view because two places ask for it — a button in
    /// the mirror's header, and whatever else ever wants "show me all of it" —
    /// and because "back to reading it" is a decision with a reason (see
    /// `MirrorFocus.opening`) rather than a number to retype.
    mutating func toggleZoom() {
        guard canZoom else { return }
        if focus.isZoomed {
            focus.reset()
        } else {
            focus = MirrorFocus.opening(card: card, picture: picture)
        }
        anchor = focus.centre
    }

    /// Whether a point on the card is on the window at all.
    func isOnPicture(_ point: CGPoint) -> Bool {
        guard canZoom else { return false }
        return focus.contains(point, card: card, picture: picture)
    }

    /// Where a point on the card is in the window being mirrored.
    ///
    /// One step, not two, and that is a property of what `picture` holds: the
    /// size of the whole window, not the size of the frames. The Mac sends a
    /// crop of its own once a viewer has zoomed far enough to need the pixels,
    /// and the crop is undone where the picture is placed rather than here — so
    /// everything on this type speaks in fractions of the window, and a touch
    /// resolves to one of them directly. It used to be composed of the two
    /// croppings, which meant the same crop was applied twice whenever the
    /// placement had already accounted for it.
    func panelPoint(at point: CGPoint) -> CGPoint {
        focus.picturePoint(at: point, card: card, picture: picture)
    }
}

/// What the Mac should be asked to send: the whole window, or the part of it
/// being read.
///
/// Its own type because the decision is a judgement rather than a calculation,
/// and the judgement was arrived at by measurement. Cropping is not free: every
/// change re-fits the capture, which costs a keyframe, and panning around while
/// cropped measured 24 fps against 50 otherwise. It is also not what makes a
/// zoomed mirror sharp at ordinary zooms — that is the Mac resampling before it
/// encodes, which happens whether or not anything is cropped. Built both ways
/// and compared at 3x on a 1668-pixel window: indistinguishable.
///
/// So it earns its place only past the point where the whole-window stream has
/// fewer pixels for the region on screen than the phone has to draw it with.
/// Three separate things keep it from flapping around that point, and all three
/// are needed: the gap between the two thresholds, the margin added around the
/// region so that panning inside what is already arriving asks for nothing, and
/// the slack in the containment test, because the Mac rounds a crop to whole
/// points of the window and what comes back is never quite what was asked for.
public enum MirrorCrop {
    /// All of it: the crop that means "no crop".
    public static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Past this much zoom the whole-window stream runs out of pixels for the
    /// region on screen. The lower number applies once a crop is already
    /// running, so that zooming back out has to cross a different line from the
    /// one zooming in crossed.
    static let cropAbove: CGFloat = 3.2
    static let keepAbove: CGFloat = 2.5
    /// How much wider than the region the crop is asked for, so that a small
    /// pan needs nothing from the Mac.
    static let margin: CGFloat = 1.4
    /// How much larger than needed a running crop may be before it is worth
    /// asking for a tighter one.
    static let slack: CGFloat = 2.5
    /// How much of the region may fall outside the running crop before it
    /// counts as outside it at all — the Mac's own rounding, in other words.
    static let rounding: CGFloat = 0.01

    /// The crop to ask for, or nil when what is already arriving will do.
    ///
    /// - Parameters:
    ///   - region: the part of the window on screen, as fractions of it.
    ///   - stream: the part of the window now arriving, as fractions of it.
    public static func wanted(showing region: CGRect, streaming stream: CGRect) -> CGRect? {
        let tightest = min(region.width, region.height)
        guard tightest > 0, region.width > 0, region.height > 0 else { return nil }
        let zoom = 1 / tightest
        let cropped = stream != whole
        guard zoom > (cropped ? keepAbove : cropAbove) else {
            return cropped ? whole : nil
        }
        if cropped,
           stream.surrounds(region, slack: rounding),
           stream.width <= region.width * slack,
           stream.height <= region.height * slack {
            return nil
        }
        return region.grown(by: margin)
    }
}

extension CGRect {
    /// Contains, with room for the far end having rounded it.
    func surrounds(_ other: CGRect, slack: CGFloat) -> Bool {
        other.minX >= minX - slack && other.minY >= minY - slack
            && other.maxX <= maxX + slack && other.maxY <= maxY + slack
    }

    /// The same rectangle, larger about its own centre, kept inside the unit
    /// square.
    func grown(by factor: CGFloat) -> CGRect {
        let width = Swift.min(self.width * factor, 1)
        let height = Swift.min(self.height * factor, 1)
        return CGRect(x: Swift.min(Swift.max(midX - width / 2, 0), 1 - width),
                      y: Swift.min(Swift.max(midY - height / 2, 0), 1 - height),
                      width: width,
                      height: height)
    }
}
