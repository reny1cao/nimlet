import SwiftUI

/// The picture follows connection events independently of surface redraws.
/// Kept separate so the real startup path can run in the connection tests
/// without loading the trackpad, dictation permissions, or the user's targets.
struct PanelLifecycle: ViewModifier {
    @ObservedObject private var pro = ProStore.shared
    let shown: Bool
    @EnvironmentObject private var client: NimletClient
    @EnvironmentObject private var panel: PanelClient
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onReceive(client.$state) { state in
                // @Published emits before state is assigned. The session is
                // already available, so use the emitted connection state.
                reconcile(connected: state.isConnected)
            }
            .onChange(of: pro.hasPro) { _, _ in
                reconcile(connected: client.state.isConnected)
            }
            .onChange(of: shown) { _, _ in
                reconcile(connected: client.state.isConnected)
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                remoteLog.info("view lifecycle: phase=\(String(describing: phase), privacy: .public) control=\(client.state.isConnected, privacy: .public)")
                reconcile(connected: client.state.isConnected)
            }
    }

    private func reconcile(connected: Bool) {
        // Inactive includes Control Centre and the app switcher. Only actual
        // backgrounding stops capture, so a brief overlay keeps the picture.
        let shouldRun = shown && connected && client.hasProAccess && scenePhase != .background
        remoteLog.info("panel lifecycle: run=\(shouldRun, privacy: .public) shown=\(shown, privacy: .public) control=\(connected, privacy: .public) phase=\(String(describing: scenePhase), privacy: .public)")
        if shouldRun { panel.start(control: client) } else { panel.stop() }
    }
}
