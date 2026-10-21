import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// The QR code a phone scans to pair by key.
///
/// Opening the window opens an invitation, and closing it closes the
/// invitation: a code that is not on screen should not be redeemable, and
/// "while this window is open" is a rule a person can see.
enum PairWindow {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    @MainActor
    static func show() {
        HostTrust.shared.openInvitation(name: HostServer.shared.hostDisplayName,
                                        addresses: RemoteReach.shared.candidates.filter { !$0.isRemote }.map(\.display))
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: PairView())
        let created = NSWindow(contentViewController: controller)
        created.title = "Pair a Phone"
        created.styleMask = [.titled, .closable]
        created.setContentSize(NSSize(width: 360, height: 500))
        created.center()
        created.isReleasedWhenClosed = false
        created.level = .floating
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: created, queue: .main) { _ in
            MainActor.assumeIsolated { HostTrust.shared.closeInvitation() }
        }
        window = created
        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PairView: View {
    @ObservedObject private var trust = HostTrust.shared
    @ObservedObject private var registry = DeviceRegistry.shared
    @ObservedObject private var server = HostServer.shared

    /// The phones the one that just paired may be replacing: approved, not
    /// connected, most recently seen first.
    ///
    /// A new iPhone is a new key whatever Apple Account it is signed in to,
    /// so the old phone stays approved after its replacement pairs — and stays
    /// able to reach this Mac, from away as well, for as long as nobody goes
    /// looking for it in the menu. Right after pairing is when the person
    /// knows which phone that is.
    private var replaceable: [DeviceRegistry.Device] {
        registry.approved
            .filter { $0.id != trust.lastPairedID && $0.name != DeviceRegistry.toolName }
            .filter { device in !server.connectedDevices.contains { $0.id == device.id } }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    var body: some View {
        VStack(spacing: 16) {
            if let name = trust.lastPaired {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56)).foregroundStyle(.green)
                Text("\(name) is paired").font(.title2.bold())
                Text("It can now reach this Mac on this network, and from away if Reachable from away is on.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                if !replaceable.isEmpty { replaceList }
                Spacer()
                Button("Pair Another Phone") { PairWindow.show() }
            } else if let invitation = trust.invitation, let expires = trust.invitationExpires {
                Text("Scan with your iPhone's Camera").font(.headline)
                if let image = QRImage.make(invitation.url.absoluteString) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 260, height: 260)
                        .accessibilityLabel("Pairing QR code")
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(expires.timeIntervalSince(context.date)))
                    Text(left > 0 ? "Works once, for \(left / 60):\(String(format: "%02d", left % 60))"
                                  : "Expired")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(left > 0 ? Color.secondary : Color.orange)
                }
                VStack(spacing: 4) {
                    Text("This Mac's key").font(.caption2.bold()).foregroundStyle(.secondary)
                    Text(invitation.host.shortCode)
                        .font(.system(.body, design: .monospaced)).tracking(2)
                        .textSelection(.enabled)
                }
                .help("The phone shows the same eight characters for the Mac it paired with")
                Text("Keep this window private: anyone who scans it before you can pair.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Show a New Code") { PairWindow.show() }
            } else if trust.identity == nil {
                Text("This Mac's Keychain would not store its key, so phones cannot pair with this Mac. Quit and reopen Nimlet to try again.")
                    .multilineTextAlignment(.center)
            } else {
                Button("Show a Pairing Code") { PairWindow.show() }
            }
        }
        .padding(24)
        .frame(width: 360, height: 500)
    }

    private var replaceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Replacing a phone?").font(.headline)
            Text("A phone you no longer use can still reach this Mac until you remove it.")
                .font(.caption).foregroundStyle(.secondary)
            // Three at most, in a window of fixed size. The rest are in the
            // menu's Devices list, where they always were.
            ForEach(replaceable.prefix(3)) { device in
                HStack {
                    Image(systemName: "iphone").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                        Text("Last seen \(device.lastSeen.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { server.remove(deviceID: device.id) }
                        .help("Revoke \(device.name) and take it off the list")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

enum QRImage {
    /// Rendered to a bitmap once per code and kept: an image backed by a
    /// CIImage runs the filter again every time it is drawn.
    @MainActor private static var last: (text: String, image: NSImage)?

    @MainActor
    static func make(_ text: String) -> NSImage? {
        if let last, last.text == text { return last.image }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let bitmap = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let image = NSImage(cgImage: bitmap, size: output.extent.size)
        last = (text, image)
        return image
    }
}
