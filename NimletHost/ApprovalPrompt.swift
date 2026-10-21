import SwiftUI
import AppKit
import Combine

/// Something has sent the pairing code and is waiting to be approved — in
/// practice a copy of the nimlet tool, since phones pair by key.
///
/// A small floating panel with its name and the two buttons. It does not take
/// focus from whatever they were doing, and it goes away by itself the moment
/// the tool is approved from anywhere. It does not go away when the socket
/// closes: the tool is connected for a moment per command, and a prompt tied
/// to that was gone before it could be read.
@MainActor
final class ApprovalPrompt {
    static let shared = ApprovalPrompt()
    private var subscription: AnyCancellable?
    private var panels: [String: NSPanel] = [:]
    private init() {}

    func begin() {
        subscription = HostServer.shared.$awaitingApproval
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in self?.reconcile(devices) }
    }

    private func reconcile(_ devices: [HostServer.ConnectedDevice]) {
        for (id, panel) in panels where !devices.contains(where: { $0.id == id }) {
            panel.close()
            panels[id] = nil
        }
        for device in devices where panels[device.id] == nil {
            show(device)
        }
    }

    private func show(_ device: HostServer.ConnectedDevice) {
        let view = ApprovalPromptView(device: device,
                                      approve: { HostServer.shared.approve(device) },
                                      later: { HostServer.shared.dismissWaiting(deviceID: device.id) })
        let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
        panel.title = "Nimlet"
        panel.styleMask = [.titled, .closable, .nonactivatingPanel, .utilityWindow]
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 360, height: 150))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 360 - 16, y: frame.maxY - 16))
        }
        panel.orderFrontRegardless()
        panels[device.id] = panel
        miceLog.info("approval prompt shown for \(device.name, privacy: .private)")
    }
}

private struct ApprovalPromptView: View {
    let device: HostServer.ConnectedDevice
    let approve: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(device.name)” wants to control this Mac")
                        .font(.headline)
                    Text("It knows this Mac's pairing code. Approved, it can type into your targets and send alerts to your phone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Not now", action: later)
                Button("Approve", action: approve)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
