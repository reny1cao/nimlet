import SwiftUI
import AVFoundation

/// Pairing with a Mac from inside the app: what to do on the Mac, and a
/// scanner for the code it shows.
///
/// The Camera app opens `nimlet://pair` links too, and still does. But "leave
/// this app and point another one at your Mac" is not something anybody
/// guesses, and on a new iPhone the screen that needed to say it was a greyed
/// Mac above "Still looking for others…" with nothing on it to tap.
struct PairingSheet: View {
    /// The Mac being paired with, when the person came here from its row.
    let hostName: String?
    @EnvironmentObject private var client: NimletClient
    @Environment(\.dismiss) private var dismiss
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    /// A code that would replace a different key for the same Mac, waiting
    /// for a yes. Only that one is asked about: the person opened a scanner
    /// to pair, and a code they pointed it at is a yes to everything else.
    @State private var replacing: PairingInvitation?
    @State private var sawOtherCode = false
    @State private var redeemed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        step(1, "On \(hostName ?? "your Mac"), click Nimlet's pointer icon in the menu bar.")
                        step(2, "Choose Pair a Phone. A code appears.")
                        step(3, "Hold this phone up to the code.")
                    }
                    scanner
                    Text("Each iPhone pairs on its own: pairing stays with the phone, not with your Apple Account, so a new or restored iPhone pairs again. The Camera app can read the code too.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(20)
            }
            .navigationTitle(hostName.map { "Pair with \($0)" } ?? "Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Replace the paired Mac?",
                   isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
                   presenting: replacing) { invitation in
                Button("Replace") { pair(invitation) }
                Button("Cancel", role: .cancel) { dismiss() }
            } message: { invitation in
                Text("This phone is already paired with a Mac called “\(invitation.name)” that has a different key. Only replace it if this code is on your own Mac's screen. Its key: \(invitation.host.shortCode).")
            }
        }
        .task {
            guard camera == .notDetermined else { return }
            _ = await AVCaptureDevice.requestAccess(for: .video)
            camera = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    @ViewBuilder
    private var scanner: some View {
        switch camera {
        case .authorized:
            QRScanner(onCode: found)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15))
                }
                .overlay(alignment: .bottom) {
                    if sawOtherCode {
                        Text("That code isn't a Nimlet pairing code")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.7), in: Capsule())
                            .padding(12)
                    }
                }
                .accessibilityLabel("Camera, looking for the pairing code")
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 8) {
                Label("Nimlet can't use the camera", systemImage: "camera.fill")
                    .font(.callout.weight(.semibold))
                Text("Allow it under Settings → Apps → Nimlet → Camera, or open the Camera app and point it at the code instead.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(.callout)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        default:
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.06))
                .aspectRatio(1, contentMode: .fit)
                .overlay { ProgressView() }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.bold).monospacedDigit())
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.12), in: Circle())
            Text(text).font(.callout)
        }
        .accessibilityElement(children: .combine)
    }

    private func found(_ code: String) {
        guard !redeemed, replacing == nil else { return }
        guard let url = URL(string: code), let invitation = PairingInvitation(url: url) else {
            sawOtherCode = true
            return
        }
        if client.replacesPin(invitation) {
            Haptics.attention()
            replacing = invitation
            return
        }
        pair(invitation)
    }

    private func pair(_ invitation: PairingInvitation) {
        guard !redeemed else { return }
        redeemed = true
        Haptics.success()
        client.pair(with: invitation)
        dismiss()
    }
}

/// The back camera, reporting each QR code it reads once.
private struct QRScanner: UIViewRepresentable {
    let onCode: @MainActor (String) -> Void

    func makeUIView(context: Context) -> QRScannerView {
        let view = QRScannerView()
        view.onCode = onCode
        view.start()
        return view
    }

    func updateUIView(_ view: QRScannerView, context: Context) {
        view.onCode = onCode
    }

    static func dismantleUIView(_ view: QRScannerView, coordinator: ()) {
        view.stop()
    }
}

private final class QRScannerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var onCode: (@MainActor (String) -> Void)?
    private let session = AVCaptureSession()
    /// Starting and stopping a session blocks for as long as the camera takes,
    /// which is too long for the main thread.
    private let sessionQueue = DispatchQueue(label: "com.renyicao.mice.pairing-scanner")
    private let reader = MetadataReader()
    /// The same code is read many times a second while it is in view.
    private var lastCode: String?

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        let preview = layer as! AVCaptureVideoPreviewLayer
        preview.session = session
        preview.videoGravity = .resizeAspectFill
        reader.onCode = { [weak self] code in self?.report(code) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func start() {
        let session = session
        let reader = reader
        sessionQueue.async {
            guard session.inputs.isEmpty else {
                if !session.isRunning { session.startRunning() }
                return
            }
            session.beginConfiguration()
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                return
            }
            session.addOutput(output)
            // Only once the output is in a session: before that it supports no
            // types at all, and asking for one throws.
            output.metadataObjectTypes = [.qr]
            output.setMetadataObjectsDelegate(reader, queue: .main)
            session.commitConfiguration()
            session.startRunning()
        }
    }

    func stop() {
        let session = session
        sessionQueue.async { session.stopRunning() }
    }

    private func report(_ code: String) {
        guard code != lastCode else { return }
        lastCode = code
        onCode?(code)
    }
}

private final class MetadataReader: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (@MainActor (String) -> Void)?

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        // Delivered on the main queue, as asked for in `start`.
        MainActor.assumeIsolated {
            for case let code as AVMetadataMachineReadableCodeObject in metadataObjects {
                if let value = code.stringValue { onCode?(value) }
            }
        }
    }
}
