import Foundation
import Network

/// One batch of images, on a connection of its own.
///
/// Separate from the control socket for the reason the panel mirror is: TCP
/// delivers in order, so a photograph queued ahead of a pointer delta is a
/// pointer that stops moving until the photograph has arrived. Short-lived as
/// well as separate — dialled for this batch, closed after the Mac's receipt —
/// because the Mac admits eight connections and this phone can already hold
/// three.
///
/// The manifest goes first and nothing else follows until the Mac says to go
/// ahead. That round trip buys two things: a refusal (unapproved device, a
/// target that has since been removed) arrives before the megabytes rather than
/// after them, and the Mac can switch that socket from newline framing to
/// length-prefixed knowing there is nothing behind the manifest to strand.
@MainActor
final class AttachmentUploader: ObservableObject {

    enum Outcome {
        case delivered
        case failed(String)
    }

    let id = UUID()
    /// How many attachments have actually gone out, for a progress readout.
    @Published private(set) var sent = 0

    private let manifest: AttachmentManifest
    private let attachments: [ImageAttachment]
    private let endpoint: NWEndpoint
    private let parameters: NWParameters
    private let onMessage: (HostMessage) -> Void
    private let onFinish: (UUID, Outcome) -> Void

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.renyicao.mice.remote.upload")
    /// Touched only on `queue`, which is serial, and only for host→phone lines:
    /// the Mac speaks JSON on this socket throughout, and the binary frames all
    /// go the other way.
    private nonisolated(unsafe) var framer = LineFramer()
    private let framerLock = NSLock()
    private var receipts = 0
    private var didFinish = false

    init(manifest: AttachmentManifest,
         attachments: [ImageAttachment],
         endpoint: NWEndpoint,
         parameters: NWParameters,
         onMessage: @escaping (HostMessage) -> Void,
         onFinish: @escaping (UUID, Outcome) -> Void) {
        self.manifest = manifest
        self.attachments = attachments
        self.endpoint = endpoint
        self.parameters = parameters
        self.onMessage = onMessage
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
                    remoteLog.info("upload ready: \(self.attachments.count, privacy: .public) attachment(s)")
                    self.sendManifest()
                case .failed(let error):
                    self.finish(.failed(error.localizedDescription))
                case .cancelled:
                    // The Mac closes this socket itself once it has sent the last
                    // receipt, so by the time this arrives the batch has usually
                    // already succeeded. Only an early close is a failure.
                    self.finish(.failed("The Mac closed the upload before it finished"))
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        receiveLoop(on: connection)
    }

    // MARK: - Sending

    private func sendManifest() {
        guard let connection, let line = try? NimletCoder.line(ClientMessage.uploadHello(manifest)) else {
            finish(.failed("Couldn't describe the upload"))
            return
        }
        connection.send(content: line, completion: .contentProcessed { _ in })
    }

    /// One frame at a time, each sent from the previous one's completion.
    ///
    /// Not politeness: `NWConnection` will happily accept eight images at once
    /// and buffer them, which loses both the backpressure and any idea of how
    /// much has actually left the phone.
    private func sendFrame(_ index: Int) {
        guard index < attachments.count else { return }
        guard let connection else { return }
        let attachment = attachments[index]
        guard let data = try? AttachmentFrameWriter.encode(attachment.frame(index: index),
                                                          payload: attachment.data) else {
            finish(.failed("Couldn't encode that image"))
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, !self.didFinish else { return }
                if let error {
                    self.finish(.failed(error.localizedDescription))
                    return
                }
                self.sent = index + 1
                self.sendFrame(index + 1)
            }
        })
    }

    // MARK: - Receiving

    private nonisolated func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let messages = self.framerLock.withLock {
                    self.framer.append(data).compactMap { try? NimletCoder.decode(HostMessage.self, from: $0) }
                }
                Task { @MainActor in
                    for message in messages { self.handle(message) }
                }
            }
            if isComplete || error != nil {
                Task { @MainActor in
                    self.finish(.failed(error?.localizedDescription ?? "The upload connection closed"))
                }
                return
            }
            self.receiveLoop(on: connection)
        }
    }

    private func handle(_ message: HostMessage) {
        switch message {
        case .uploadReady(let batchID):
            remoteLog.info("upload \(batchID, privacy: .public) accepted")
            sendFrame(0)
        case .delivered:
            // Straight through to the control client, so an image lands with the
            // same haptic and the same toast as a sentence does.
            onMessage(message)
            receipts += 1
            if receipts >= max(1, manifest.targetIDs.count) { finish(.delivered) }
        case .error(let text):
            onMessage(message)
            finish(.failed(text))
        default:
            // A status broadcast can land here; this socket is not the place to
            // act on one.
            break
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !didFinish else { return }
        didFinish = true
        connection?.cancel()
        connection = nil
        if case .failed(let reason) = outcome {
            remoteLog.error("upload failed: \(reason, privacy: .public)")
        }
        onFinish(id, outcome)
    }
}
