import Foundation

/// Mirrors a tmux pane to the phone as text.
///
/// Text, not pixels, on purpose: a 1512-point window scaled to a 393-point phone
/// is unreadable however smooth the video is, while a pane sent as characters
/// renders at whatever size the phone likes, stays sharp, and costs a few KB.
///
/// It spawns `tmux capture-pane` ten times a second, which looks wasteful beside
/// a long-lived `tmux -C` control client. It isn't a mistake. A control client is
/// an *attached* client, and tmux sizes each window to its smallest attached
/// client — attaching one at 80x24 would resize the user's panes under them
/// mid-session. One-shot command clients take no part in sizing. The spawn costs
/// a couple of milliseconds and only happens while someone is watching.
final class PaneMirror {

    private let queue = DispatchQueue(label: "com.renyicao.mice.host.pane")
    private var timer: DispatchSourceTimer?
    private var lastDigest: Int?
    private let onFrame: (ViewFrame, Data) -> Void

    /// 10 Hz. A terminal is not animation: faster costs spawns and buys nothing
    /// the eye can use, and scrollback arrives in bursts anyway.
    private let interval: DispatchTimeInterval = .milliseconds(100)

    init(onFrame: @escaping (ViewFrame, Data) -> Void) {
        self.onFrame = onFrame
    }

    func start(pane: String, title: String) {
        stop()
        lastDigest = nil
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.poll(pane: pane, title: title) }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Makes the next poll send even if the pane has not changed — a viewer that
    /// just attached has nothing on screen to keep.
    func invalidate() {
        queue.async { self.lastDigest = nil }
    }

    private func poll(pane: String, title: String) {
        let start = Instrumentation.now()
        // One spawn, two commands: tmux treats a bare `;` argument as a
        // separator, so the pane geometry and its contents come back together.
        let result = Tmux.run([
            "display-message", "-p", "-t", pane,
            "-F", "#{pane_width} #{pane_height}",
            ";",
            "capture-pane", "-p", "-e", "-t", pane,
        ])
        Instrumentation.shared.record("view_capture_text", since: start)

        guard result.ok else {
            emitState("tmux: \(result.output)", title: title)
            return
        }
        var lines = result.output.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else {
            emitState("Pane \(pane) is empty", title: title)
            return
        }
        let meta = lines.removeFirst().split(separator: " ").compactMap { Int($0) }
        let body = lines.joined(separator: "\n")

        // Nothing changed: say nothing. This is what keeps an idle agent pane at
        // zero bandwidth instead of 10 redundant frames a second.
        var hasher = Hasher()
        hasher.combine(body)
        hasher.combine(meta)
        let digest = hasher.finalize()
        guard digest != lastDigest else { return }
        lastDigest = digest

        var frame = ViewFrame(kind: .text, title: title, captureTime: Instrumentation.now())
        frame.columns = meta.count > 0 ? meta[0] : nil
        frame.rows = meta.count > 1 ? meta[1] : nil
        onFrame(frame, Data(body.utf8))
    }

    private func emitState(_ reason: String, title: String) {
        var hasher = Hasher()
        hasher.combine(reason)
        let digest = hasher.finalize()
        guard digest != lastDigest else { return }
        lastDigest = digest
        onFrame(ViewFrame.state(reason, title: title), Data())
    }
}
