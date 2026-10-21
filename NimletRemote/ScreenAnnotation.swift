import Foundation
import Network
import PencilKit
import SwiftUI
import UIKit

/// Fetches one picture of the Mac's screen, on a connection opened for it and
/// closed after it.
///
/// The answer is one of two shapes, and which one arrives is not known in
/// advance: a length-prefixed binary frame if the screenshot was taken, or a
/// newline-JSON `error` line if it was refused — no Screen Recording grant, no
/// window for that app, a target that has since been removed. Both have to be
/// legible, because "nothing happened" is the one outcome that leaves somebody
/// tapping the button again.
///
/// They are told apart by the first byte. A frame begins with the big-endian
/// high byte of its header length, and a header is never 16 MB, so that byte is
/// always zero; JSON begins with `{`. One sniff, at the head of a response that
/// is only ever one thing.
/// Why a screenshot did not arrive, in the Mac's own words — which are written
/// to be shown to somebody, so they are shown rather than mapped onto a code.
struct StillProblem: Error {
    let message: String
}

/// A screenshot of the Mac, and what it is a screenshot of.
struct Still: Identifiable {
    let id = UUID()
    let image: UIImage
    /// The Mac's own words: a window's application name, or "Screen".
    let title: String
}

@MainActor
final class StillFetcher {

    let id = UUID()

    private enum Shape {
        case undecided
        case frames
        case lines
    }

    private let request: StillRequest
    private let endpoint: NWEndpoint
    private let parameters: NWParameters
    private let onResult: (Result<Still, StillProblem>) -> Void
    private let onFinish: (UUID) -> Void

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.renyicao.mice.remote.still")
    private nonisolated(unsafe) var shape = Shape.undecided
    private nonisolated(unsafe) var frames = StillFrameReader()
    private nonisolated(unsafe) var lines = LineFramer()
    private let readLock = NSLock()
    private var didFinish = false

    init(request: StillRequest,
         endpoint: NWEndpoint,
         parameters: NWParameters,
         onResult: @escaping (Result<Still, StillProblem>) -> Void,
         onFinish: @escaping (UUID) -> Void) {
        self.request = request
        self.endpoint = endpoint
        self.parameters = parameters
        self.onResult = onResult
        self.onFinish = onFinish
    }

    func start() {
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    guard let line = try? NimletCoder.line(ClientMessage.stillHello(self.request)) else {
                        self.finish(.failure(StillProblem(message: "Couldn't ask for the screenshot")))
                        return
                    }
                    connection.send(content: line, completion: .contentProcessed { _ in })
                case .failed(let error):
                    self.finish(.failure(StillProblem(message: error.localizedDescription)))
                case .cancelled:
                    self.finish(.failure(StillProblem(message: "The Mac closed the connection")))
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        receiveLoop(on: connection)
    }

    private nonisolated func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let outcome = self.readLock.withLock { self.absorb(data) }
                if let outcome {
                    Task { @MainActor in self.finish(outcome) }
                    return
                }
            }
            if isComplete || error != nil {
                Task { @MainActor in
                    self.finish(.failure(StillProblem(message: error?.localizedDescription ?? "The screenshot never arrived")))
                }
                return
            }
            self.receiveLoop(on: connection)
        }
    }

    /// Returns nil while the answer is still incomplete. Called under the lock,
    /// off the main actor: a full-screen PNG is a megabyte or two and decoding it
    /// is not work for the thread drawing the canvas.
    private nonisolated func absorb(_ data: Data) -> Result<Still, StillProblem>? {
        if case .undecided = shape {
            shape = data.first == 0x00 ? .frames : .lines
        }
        switch shape {
        case .frames:
            guard let first = frames.append(data).first else { return nil }
            guard let image = UIImage(data: first.payload) else {
                return .failure(StillProblem(message: "That screenshot didn't decode"))
            }
            return .success(Still(image: image, title: first.frame.title))
        case .lines:
            for line in lines.append(data) {
                guard let message = try? NimletCoder.decode(HostMessage.self, from: line) else { continue }
                if case .error(let text) = message { return .failure(StillProblem(message: text)) }
            }
            return nil
        case .undecided:
            return nil
        }
    }

    private func finish(_ result: Result<Still, StillProblem>) {
        guard !didFinish else { return }
        didFinish = true
        connection?.cancel()
        connection = nil
        onResult(result)
        onFinish(id)
    }
}

/// PencilKit over the screenshot, for circling the thing you are talking about.
///
/// `drawingPolicy = .anyInput` because the input device here is a finger: the
/// default waits for a pencil on a device that has one, and silently scrolls
/// under a fingertip on one that does not.
struct DrawingCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    /// How many strokes there are now, reported on every change: the toolbar
    /// above has no other way to know whether there is anything to undo.
    let onStrokesChanged: (Int) -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // One tool, and a loud one. A palette of pens is a drawing app; this is
        // a single gesture between seeing something and asking about it.
        canvas.tool = PKInkingTool(.marker, color: .systemRed, width: 14)
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onStrokesChanged: onStrokesChanged) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let onStrokesChanged: (Int) -> Void

        init(onStrokesChanged: @escaping (Int) -> Void) {
            self.onStrokesChanged = onStrokesChanged
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onStrokesChanged(canvasView.drawing.strokes.count)
        }
    }
}

/// Draw on the Mac's screen, then send it.
struct AnnotationSheet: View {
    let still: UIImage
    let title: String
    let onUse: (ImageAttachment) -> Void

    @State private var canvas = PKCanvasView()
    /// The size the screenshot is actually being drawn at, which is the space the
    /// strokes are in. Flattening needs it to map them onto the full-size image.
    @State private var canvasSize: CGSize = .zero
    /// A `PKCanvasView` is not observable, so drawing on it changes nothing
    /// SwiftUI can see. Without this, Undo and Clear are disabled when the sheet
    /// opens and stay disabled however much is drawn.
    @State private var strokeCount = 0
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    let fitted = Self.fit(still.size, into: geometry.size)
                    ZStack {
                        Image(uiImage: still)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                        DrawingCanvas(canvas: canvas) { strokeCount = $0 }
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .onAppear { canvasSize = fitted }
                    .onChange(of: fitted) { _, new in canvasSize = new }
                }
                if let problem {
                    Text(problem).font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(12)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Undo") {
                        var strokes = canvas.drawing.strokes
                        guard !strokes.isEmpty else { return }
                        strokes.removeLast()
                        canvas.drawing = PKDrawing(strokes: strokes)
                        strokeCount = strokes.count
                    }
                    .disabled(strokeCount == 0)
                    Button("Clear") {
                        canvas.drawing = PKDrawing()
                        strokeCount = 0
                    }
                    .disabled(strokeCount == 0)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") { use() }
                }
            }
        }
    }

    private func use() {
        guard let flattened = flattened() else {
            problem = "That annotation couldn't be flattened"
            return
        }
        // Lossless: this is a screenshot of text with a red line over it, and
        // JPEG would spend its bytes on both.
        guard let attachment = ImagePreparation.prepare(flattened, lossless: true) else {
            problem = "That annotation couldn't be prepared"
            return
        }
        onUse(attachment)
        dismiss()
    }

    /// The strokes, drawn over the screenshot at the screenshot's own size.
    ///
    /// The canvas is exactly the rectangle the image is displayed in, so the two
    /// rectangles correspond and the drawing can be stretched onto the full-size
    /// image without any offset arithmetic.
    private func flattened() -> UIImage? {
        let pixels = CGSize(width: still.size.width * still.scale,
                            height: still.size.height * still.scale)
        guard pixels.width >= 1, pixels.height >= 1, canvasSize.width >= 1 else { return nil }
        let strokes = canvas.drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: 1)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixels, format: format).image { _ in
            still.draw(in: CGRect(origin: .zero, size: pixels))
            strokes.draw(in: CGRect(origin: .zero, size: pixels))
        }
    }

    /// Aspect-fit, computed rather than left to `.aspectRatio`, because the
    /// canvas has to be given the same rectangle the image ends up in.
    static func fit(_ size: CGSize, into box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: (size.width * scale).rounded(.down),
                      height: (size.height * scale).rounded(.down))
    }
}
