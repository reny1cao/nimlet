import SwiftUI
import AVFoundation
import UIKit

/// The panel filling the screen, for when the tile is not enough.
struct PanelViewer: View {
    @EnvironmentObject private var panel: PanelClient
    /// Closed by the screen that owns it rather than by the modal machinery.
    ///
    /// It used to be a `fullScreenCover`, and inside that cover SwiftUI's hit
    /// testing did not work: neither the header's buttons nor a plain
    /// `onTapGesture` on a coloured square ever fired, while the raw UIKit
    /// touch surface over the picture received everything. Verified twice by
    /// tapping the header and reading the Mac's pointer, which did not move
    /// either — the touches were reaching neither side. A view in the screen's
    /// own stack has none of that: the same controls work.
    let onClose: () -> Void
    /// Closes this and opens the window shelf. Offered only when the mirror
    /// has stopped and there is a target whose windows can be listed.
    var onPickWindow: (() -> Void)?
    /// Brings back the window this target is pointed at. Offered only when the
    /// Mac says the state is one that opening would clear — which today means
    /// the window is minimised.
    var onOpenWindow: (() -> Void)?

    @State private var rotated = false
    /// The mirror's zoom, held here rather than inside the picture, so the
    /// header's fit button and the fingers on the glass move the same thing.
    @State private var mirror = MirrorState()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                // The header rides inside the rotation so it stays at the top of
                // the panel whichever way the phone is held.
                // The header rides inside the rotation so it stays at the top
                // of the panel whichever way the phone is held.
                Rotator(rotated: rotated) {
                    VStack(spacing: 0) {
                        header
                        content
                    }
                }
            }
            .onAppear { panel.setViewport(points: geometry.size) }
        }
        .statusBarHidden()
        .onChange(of: panel.title) { _, _ in
            mirror.focus.reset()
            mirror.anchor = mirror.focus.centre
        }
        .onDisappear {
            // The tile shows the whole panel; a crop left over from zooming in
            // here would follow it back out.
            panel.setCrop(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// A picture is driven; anything else is only read.
    @ViewBuilder private var content: some View {
        if panel.message == nil, panel.isVideo {
            DetailMirror(mirror: $mirror)
        } else {
            PanelContent(compact: false,
                         onPickWindow: onPickWindow.map { pick in { onClose(); pick() } },
                         // Opening leaves the viewer up: the whole point is
                         // that the picture comes back, and closing to show
                         // the tile would hide the thing just asked for.
                         onOpenWindow: onOpenWindow)
                .environmentObject(panel)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // 44pt of target under a 22pt glyph, here and on the rotate
            // button beside it. They were the glyph's own size, which is about
            // half of what a thumb aims with — and a miss on the way out of a
            // full-screen view feels like the view is stuck.
            Button(action: onClose) {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(panel.title.isEmpty ? "Panel" : panel.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Spacer()
            // The whole window, and back to reading it. This was a two-finger
            // tap on the picture, which is the trackpad's right click — the
            // same gesture meaning two things depending on which half of the
            // app you were in. It is a button now, and the gesture means right
            // click in both places.
            if panel.isVideo, mirror.canZoom {
                Button {
                    mirror.toggleZoom()
                } label: {
                    Image(systemName: mirror.focus.isZoomed
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mirror.focus.isZoomed ? "Show the whole window" : "Zoom in to read")
            }
            // Turning the panel is a choice, not a guess. Opening it sideways
            // because the window happens to be wider than it is tall is wrong as
            // often as it is right, and it is jarring either way.
            Button {
                withAnimation(.spring(duration: 0.3)) { rotated.toggle() }
            } label: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.ultraThinMaterial.opacity(0.85))
    }
}

/// Latency and frame rate: the two numbers that say whether this is a mirror or
/// a video call, and both invisible unless shown.
struct PanelStats: View {
    @EnvironmentObject private var panel: PanelClient

    var body: some View {
        HStack(spacing: 6) {
            if panel.framesPerSecond >= 1 {
                Text("\(Int(panel.framesPerSecond.rounded())) fps")
                    .foregroundStyle(.white.opacity(0.35))
            }
            if let latency = panel.latencyMillis {
                Text("\(Int(latency.rounded())) ms")
                    .foregroundStyle(latency < 80 ? .white.opacity(0.4)
                                     : latency < 200 ? Palette.caution.opacity(0.8)
                                     : Palette.attention)
            }
        }
        .font(.caption2.monospacedDigit())
    }
}

// MARK: - Shared content

/// What a panel actually looks like, at either size.
///
/// The picture and nothing else. It carries no card, no border and no corner
/// of its own: whatever is being mirrored already has corners, and they are in
/// the frames — the Mac captures the window opaque, so the rounded corner and
/// the black outside it arrive as pixels. Drawing a second rounded rectangle
/// over that is the double corner you can see on any tile that tries it, and
/// clipping to a guessed radius trims real pixels off a real window.
///
/// `resizeAspect`, everywhere. The box this is given is cut to the picture's
/// own shape by whoever placed it, so fit and fill agree — and where they
/// disagree by a rounding error, fit shows all of the window with a hairline
/// of black rather than filling by cutting a column of it away.
struct PanelContent: View {
    @EnvironmentObject private var panel: PanelClient
    let compact: Bool
    /// The way out of a stopped mirror, where the screen that placed this can
    /// offer one: it opens the focused target's window shelf. Nil where there
    /// is no target to open it for.
    ///
    /// Without this the message was a cul-de-sac. "Chrome is minimised" is a
    /// true sentence about a window you chose on a shelf you can no longer
    /// see, and the tile's only gesture — tap to open — led to the same
    /// sentence at three times the size. Every route out of it ran through
    /// the Mac.
    var onPickWindow: (() -> Void)?
    /// Brings back the window this target is pointed at.
    var onOpenWindow: (() -> Void)?

    var body: some View {
        if let message = panel.message {
            unavailable(message)
        } else if panel.isVideo {
            VideoLayerView(decoder: panel.decoder, gravity: .resizeAspect)
        } else if let screen = panel.screen {
            PanelTextView(screen: screen, compact: compact)
        } else {
            // Waiting and connecting are passing states that fix themselves,
            // so they get no button: an action offered for a second and then
            // withdrawn is worse than none. Past a few seconds they have
            // stopped passing, and the one cause a person can fix is named.
            VStack(spacing: 8) {
                unavailable(panel.isConnected ? "Waiting for the first frame…" : "Connecting…",
                            offersEscape: false)
                StalledHint(after: 8,
                            message: panel.isConnected
                                ? "No picture yet. On the Mac, give Nimlet Screen Recording permission in System Settings → Privacy & Security, then quit and reopen Nimlet there."
                                : "Taking longer than usual. Check that Nimlet on the Mac is still running and both devices are on the same network.")
            }
        }
    }

    private var canOpen: Bool { panel.messageCanOpen }

    private func escapeButton(_ title: String,
                              action: @escaping () -> Void,
                              isPrimary: Bool) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isPrimary ? .semibold : .medium))
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(isPrimary ? Color.accentColor.opacity(0.22)
                                      : Color.white.opacity(0.1),
                            in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isPrimary ? Color.accentColor : .white.opacity(0.85))
    }

    private func unavailable(_ text: String, offersEscape: Bool = true) -> some View {
        VStack(spacing: compact ? 7 : 12) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: compact ? 20 : 28, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            // Dynamic Type, both sizes. The compact one was 8 points flat —
            // under the legibility floor at the default setting, and deaf to
            // Larger Text, so the one person who most needed it read it
            // smallest. There is room: this band is the width of the screen.
            Text(text)
                .font(compact ? .caption2 : .footnote)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(compact ? 3 : nil)
            if offersEscape, onPickWindow != nil || canOpen {
                HStack(spacing: 8) {
                    // The direct answer first. "Chrome is minimised" has one
                    // obvious reply and it is not "pick a different window" —
                    // that was the only offer here, and it made the phone the
                    // one place that could see the problem and not fix it.
                    if canOpen, let onOpenWindow {
                        escapeButton("Open it", action: onOpenWindow, isPrimary: true)
                    }
                    if let onPickWindow {
                        escapeButton("Pick another window", action: onPickWindow,
                                     isPrimary: !canOpen)
                    }
                }
            }
        }
        .padding(.horizontal, compact ? 16 : 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Rotation

/// The app stays portrait — locking the whole UI to landscape for one screen is
/// a lot of plumbing — so the panel turns instead. Turn the phone and a wide
/// window is upright.
private struct Rotator<Content: View>: View {
    let rotated: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let box = rotated
                ? CGSize(width: geometry.size.height, height: geometry.size.width)
                : geometry.size
            content()
                .frame(width: box.width, height: box.height)
                .rotationEffect(.degrees(rotated ? 90 : 0))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

// MARK: - Video

/// Shared with the stage band, which draws the same decoder into a box of its
/// own — one decoder, two places it can be on screen, never both at once.
struct VideoLayerView: UIViewRepresentable {
    let decoder: VideoDecoder
    /// Fit, which is what the full-screen viewer wants — it does its own
    /// scaling and needs the picture where it says it is — or fill, which is
    /// what the stage wants.
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> DisplayLayerView {
        let view = DisplayLayerView()
        view.displayLayer.videoGravity = gravity
        view.decoder = decoder
        decoder.layer = view.displayLayer
        return view
    }

    func updateUIView(_ uiView: DisplayLayerView, context: Context) {
        uiView.displayLayer.videoGravity = gravity
        uiView.decoder = decoder
        decoder.layer = uiView.displayLayer
    }
}

/// The mirror at full size, and the surface the Mac is driven from.
///
/// This is where the pointer work happens now. The thumbnail above the pad is
/// a picture of the whole window and nothing else — you tap it to come here —
/// so everything the finger used to do up there does it down here instead, on
/// a picture that is four times the size and where a 10pt target is a 10pt
/// target rather than a 3pt one.
///
/// One finger is the Mac: where you touch is where the pointer goes, and what
/// you do there is what it does — tap to click, tap twice to double click,
/// press to hold, drag to drag. Two fingers are the phone's own: pinch to
/// enlarge the picture, drag to move it around, tap to go between the whole
/// window and the part of it you were reading. Nothing the two fingers do
/// reaches the Mac, and nothing the one finger does moves the picture.
///
/// Opens fitted so the whole window stays visible while the Mac adopts the
/// area's shape. The header and a pinch can enlarge it afterward.
private struct DetailMirror: View {
    @EnvironmentObject private var panel: PanelClient
    @EnvironmentObject private var client: NimletClient
    @Binding var mirror: MirrorState
    /// What the scroll strip is doing — a thumb on it, and how much of a flick
    /// is left after the thumb has gone. Only the strip's own ink cares.
    @State private var scrolling = ScrollStripState.idle

    var body: some View {
        GeometryReader { geometry in
            // The card is the whole of the screen below the header, whatever
            // shape the window is. Cutting it to the window's shape instead —
            // which is what this did — meant zooming in enlarged the picture
            // inside the same letterboxed band, so a wide window stayed a
            // third of the glass however far you pinched.
            let card = geometry.size
            // The whole window at this zoom, in the card's own points, whether
            // or not the Mac is currently sending all of it. Every other
            // rectangle here is placed inside this one, and every fraction the
            // fingers produce is a fraction of it.
            let drawn = mirror.focus.drawn(card: card, picture: mirror.picture)
            let origin = mirror.focus.origin(card: card, picture: mirror.picture)
            // And where the frames that have actually arrived sit inside it.
            // Past about 3x the Mac stops sending the window and starts sending
            // the part being read, at the resolution that part deserves; those
            // frames are a rectangle of the window, and drawing them as though
            // they were the window is a picture at the wrong scale in the wrong
            // place. Undone here, once, which is what lets everything else —
            // the touches, the pan, the zoom — keep speaking about the window.
            let stream = panel.streamCrop
            let picture = CGSize(width: drawn.width * stream.width,
                                 height: drawn.height * stream.height)
            let pictureOrigin = CGPoint(x: origin.x + stream.minX * drawn.width,
                                        y: origin.y + stream.minY * drawn.height)
            // Overlays rather than a stack, and that is not a style choice: a
            // ZStack takes the size of its largest child, so the moment the
            // picture is drawn wider than the screen the stack grows with it
            // and the frame around it re-centres the whole thing — which puts
            // the left edge of the window off the left of the glass and quietly
            // undoes every offset computed above. An overlay is laid out
            // against its host and is allowed to overflow it.
            Color.black
                .frame(width: card.width, height: card.height)
                .overlay(alignment: .topLeading) {
                    VideoLayerView(decoder: panel.decoder, gravity: .resizeAspect)
                        .frame(width: picture.width, height: picture.height)
                        // The window's own corner, in the points the window is
                        // being drawn at — so it holds at every zoom, and at
                        // the zooms where the corner is off the card the clip
                        // simply has nothing to do. Square while the stream is
                        // cropped: the window's corner is not in those pixels,
                        // so rounding them would cut a curve out of the middle
                        // of the window.
                        .clipShape(RoundedRectangle(cornerRadius: stream == MirrorCrop.whole ? cornerRadius(of: drawn) : 0,
                                                    style: .continuous))
                        .offset(x: pictureOrigin.x, y: pictureOrigin.y)
                }
                .clipped()
                .overlay { touches(in: card) }
            // Measured from the screen and the zoom, and never from the
            // picture's own size. Asking the Mac for a viewport changes what it
            // encodes, which changes the size of the frames, which changes the
            // shape of this box by a hair — and publishing *that* asks for a
            // new viewport. The loop is invisible except that it re-lays the
            // view out continuously, and a SwiftUI button whose view is rebuilt
            // between the finger going down and coming up never fires: the
            // header's controls were dead for exactly as long as this was
            // wired to the picture.
            .onAppear { settle(card) }
            .onChange(of: geometry.size) { _, new in settle(new) }
            .onChange(of: panel.videoSize) { _, _ in settle(card) }
            // A crop arriving changes what the frames are of, and so what the
            // window's shape has to be derived from.
            .onChange(of: panel.streamCrop) { _, _ in settle(card) }
            .task(id: settled) {
                // Only what a gesture settles on is ever asked for. Both of
                // these re-decide the encode on the Mac, and re-deciding it per
                // frame of a pinch spends the whole gesture tearing the capture
                // down and building it again.
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }
                panel.setWindowFit(points: card)
                publishCrop()
                publishViewport(card: card)
            }
        }
    }

    private func touches(in card: CGSize) -> some View {
        MirrorTouchLayer(onPoint: { point in
                             client.sendPanelPoint(mirror.panelPoint(at: point), shownGeneration: panel.shownGeneration)
                         },
                         onPress: { down, count in
                             client.send(.click(button: .left,
                                                phase: down ? .down : .up,
                                                clickCount: count))
                         },
                         onPan: { translation in mirror.pan(by: translation) },
                         onZoom: { factor in mirror.magnify(by: factor) },
                         onAnchor: { point in
                             mirror.anchor = mirror.focus.picturePoint(at: point,
                                                                       card: mirror.card,
                                                                       picture: mirror.picture)
                         },
                         onSecondaryTap: { point in
                             // The mirror is an absolute surface, so a right
                             // click has a place and has to be sent to it
                             // before it is sent at all.
                             client.sendPanelPoint(mirror.panelPoint(at: point), shownGeneration: panel.shownGeneration)
                             client.send(.click(button: .right, phase: .click, clickCount: 1))
                         },
                         onScroll: { delta in
                             client.sendScroll(dx: Double(delta.x), dy: Double(delta.y))
                         },
                         onScrollStripChanged: { scrolling = $0 },
                         onScrollPhase: { client.sendScroll(phase: $0) },
                         // No bleed here, unlike the pad. The strip sits on the
                         // picture, and the picture's own edge is the thing it
                         // marks — a target running out past it into whatever
                         // black happens to be beside a tall window would catch
                         // touches in a place with nothing drawn in it.
                         scrollStripRect: ScrollStripGeometry.rect(in: card),
                         accepts: { mirror.isOnPicture($0) })
            .frame(width: card.width, height: card.height)
            .overlay(alignment: .trailing) {
                ScrollStrip(state: scrolling)
                    .frame(maxHeight: .infinity)
            }
    }

    private func cornerRadius(of drawn: CGSize) -> CGFloat {
        guard let fraction = panel.cornerFraction, fraction > 0, drawn.width > 0 else { return 0 }
        return min(CGFloat(fraction) * drawn.width, drawn.height / 2)
    }

    private func settle(_ card: CGSize) {
        mirror.card = card
        // The window, not the frames: past 3x the frames are a crop of it, and
        // every fraction on `MirrorState` is a fraction of the window.
        mirror.picture = panel.windowSize ?? .zero
        publishViewport(card: card)
    }

    // MARK: - What the Mac is asked for

    /// The region on screen, quantised.
    ///
    /// What the Mac is asked for is re-decided when this changes rather than on
    /// every frame of a gesture: a pinch moves the region continuously, and each
    /// decision can cost the capture a reconfigure and a keyframe.
    private struct Settled: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        var card: CGSize
    }

    private var settled: Settled {
        let region = mirror.focus.region(card: mirror.card, picture: mirror.picture)
        func step(_ value: CGFloat) -> Int { Int((value * 40).rounded()) }
        return Settled(x: step(region.minX), y: step(region.minY),
                       width: step(region.width), height: step(region.height), card: mirror.card)
    }

    /// Ask for the region once zooming has gone past what the whole window can
    /// serve, and for the window again on the way back out. `MirrorCrop` holds
    /// the judgement and the reasons for it.
    private func publishCrop() {
        let region = mirror.focus.region(card: mirror.card, picture: mirror.picture)
        guard let crop = MirrorCrop.wanted(showing: region, streaming: panel.streamCrop) else { return }
        panel.setCrop(crop)
    }

    /// The box of pixels the Mac is asked to encode into.
    ///
    /// Cropped, the region arrives filling the card, so the card is the whole of
    /// what has to be resolved. Uncropped, the Mac is sending the whole window
    /// and the part on screen is a fraction of it, so it has to be asked for
    /// that many times more pixels than the window is drawn at.
    private func publishViewport(card: CGSize) {
        guard panel.streamCrop == MirrorCrop.whole else {
            panel.setViewport(points: card)
            return
        }
        // Codec rounding changes the arriving picture's aspect slightly. The
        // available card stays fixed, so it cannot feed those changes back.
        guard card.width > 0, card.height > 0 else { return }
        let step = CGFloat(detailStep)
        panel.setViewport(points: CGSize(width: card.width * step, height: card.height * step))
    }

    /// Whole steps, because the size decides the encode and a step is what a
    /// pinch settles on. Capped at 3: past that the crop takes over, and asking
    /// for the whole window at four times the size it is drawn spends the
    /// encoder on pixels of the window nobody is looking at.
    private var detailStep: Int {
        min(max(Int(mirror.focus.zoom.rounded()), 1), 3)
    }
}


final class DisplayLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    /// Claimed when this view is the one on screen.
    ///
    /// There are two of these — the thumbnail's and the full-screen mirror's —
    /// and one decoder between them. Handing the decoder over in `makeUIView`
    /// is not enough: the thumbnail stays in the hierarchy while the detail
    /// view is up, so when the detail view goes away nothing re-evaluates the
    /// thumbnail, and the decoder keeps drawing into a layer that is no longer
    /// in any window. The picture is black and the Mac has no idea.
    ///
    /// Moving into a window is the moment that cannot be missed, so that is
    /// where the claim happens. The decoder asks for a keyframe when its layer
    /// changes, so the picture comes back by itself.
    weak var decoder: VideoDecoder?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, let decoder else { return }
        decoder.layer = displayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    /// Core Animation animates a layer's bounds and position by default, over a
    /// quarter of a second. Under a pinch that turns every frame of the gesture
    /// into a little animation chasing the last one, which is exactly the lurch
    /// you feel instead of a zoom that tracks your fingers.
    override func action(for layer: CALayer, forKey event: String) -> CAAction? {
        NSNull()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - Text

/// A tmux pane, rendered as characters rather than pixels.
///
/// The font is sized so the pane's own column count fits the width — the one
/// thing a video mirror can never do, and the reason a terminal target is worth
/// treating separately at all. In the tile there is no room for that, so it
/// shows the newest lines instead: what the agent just said, not all of it.
private struct PanelTextView: View {
    let screen: PanelClient.TextScreen
    let compact: Bool

    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    /// Measured once: the advance width of the monospaced system font, per point
    /// of size. Guessing 0.6 is close but drifts by a column or two over 120.
    private static let advanceRatio: CGFloat = {
        let probe = UIFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: probe]).width / 100
    }()

    private static let compactFontSize: CGFloat = 7

    var body: some View {
        if compact { tail } else { full }
    }

    // MARK: Tile

    private var tail: some View {
        GeometryReader { geometry in
            let lineHeight = Self.compactFontSize * 1.22
            let rows = max(Int(geometry.size.height / lineHeight), 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visibleTail(rows: rows).enumerated()), id: \.offset) { _, line in
                    Text(line.characters.isEmpty ? AttributedString(" ") : line)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .font(.system(size: Self.compactFontSize, design: .monospaced))
            .padding(.horizontal, 4)
            // The newest line is the last one; without this it sits on the
            // tile's edge and loses its descenders.
            .padding(.bottom, 3)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
            .clipped()
        }
    }

    /// Trailing blank rows are just where the cursor is resting; showing them
    /// would push the newest output out of a tile this short.
    private func visibleTail(rows: Int) -> [AttributedString] {
        var lines = screen.lines
        while let last = lines.last,
              last.characters.allSatisfy({ $0 == " " }) {
            lines.removeLast()
        }
        return Array(lines.suffix(rows))
    }

    // MARK: Full screen

    private var full: some View {
        GeometryReader { geometry in
            let columns = max(screen.columns, 1)
            let fitted = geometry.size.width / (CGFloat(columns) * Self.advanceRatio)
            let size = min(max(fitted * zoom * pinch, 3.5), 30)

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(screen.lines.enumerated()), id: \.offset) { _, line in
                        // An empty AttributedString lays out as zero height and
                        // the blank lines in a pane collapse, shifting
                        // everything below them up.
                        Text(line.characters.isEmpty ? AttributedString(" ") : line)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .font(.system(size: size, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 6)
                // Both minimums, and topLeading: without the height a scroll
                // view with two axes centres content shorter than the viewport,
                // which floats a half-empty pane in the middle of the screen.
                .frame(minWidth: geometry.size.width,
                       minHeight: geometry.size.height,
                       alignment: .topLeading)
            }
            .gesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in
                        zoom = min(max(zoom * value.magnification, 0.4), 6)
                    }
            )
        }
    }
}
