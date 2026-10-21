import Foundation

/// One batch of attachments arriving on its own connection.
///
/// Holds the whole batch before delivering any of it. A prompt that says "compare
/// these two" and arrives with one of them is worse than one that does not
/// arrive: the agent answers the question it was asked about the picture it can
/// see, and nobody finds out. So a connection that dies halfway delivers
/// nothing, and takes its half-written files with it.
final class UploadSession {

    enum Progress {
        /// More frames expected.
        case receiving
        /// Over, and nothing was delivered. The files are already gone.
        case refused(String)
        /// Every attachment is on disk, in the order the phone sent them.
        case complete([TargetRouter.Attachment])
    }

    let manifest: AttachmentManifest
    /// Only ever shown in the log and echoed to the phone, so it can say which
    /// upload a refusal belongs to.
    let batchID: String

    private var reader = AttachmentFrameReader()
    private var written: [Int: TargetRouter.Attachment] = [:]
    private var isOver = false

    init(manifest: AttachmentManifest, batchID: String = UUID().uuidString) {
        self.manifest = manifest
        self.batchID = batchID
    }

    /// Whatever is a well-formed count for a batch. Checked by the host before a
    /// session is made at all, and stated here because the answer is about the
    /// batch rather than about the socket.
    static func refusal(for manifest: AttachmentManifest) -> String? {
        guard NimletProtocol.supports(clientVersion: manifest.protocolVersion) else {
            return NimletProtocol.versionRefusal(clientVersion: manifest.protocolVersion)
        }
        guard manifest.count > 0 else { return "That upload has no attachments in it" }
        guard manifest.count <= UploadChannel.maxAttachments else {
            return "\(manifest.count) attachments at once — the limit is \(UploadChannel.maxAttachments)"
        }
        guard !manifest.targetIDs.isEmpty else { return "That upload names no target" }
        return nil
    }

    func append(_ data: Data) -> Progress {
        guard !isOver else { return .receiving }
        for (frame, payload) in reader.append(data) {
            // An index outside the batch, or a second copy of one already
            // written, means the stream is not what the manifest described.
            // Either way this is not an upload to guess at the intent of.
            guard frame.index >= 0, frame.index < manifest.count else {
                return refuse("Attachment \(frame.index + 1) isn't part of a batch of \(manifest.count)")
            }
            guard written[frame.index] == nil else {
                return refuse("Attachment \(frame.index + 1) arrived twice")
            }
            switch AttachmentInbox.write(payload, frame: frame) {
            case .failure(let refusal):
                return refuse(refusal.message)
            case .success(let url):
                written[frame.index] = TargetRouter.Attachment(url: url, format: frame.format)
            }
        }
        guard written.count == manifest.count else { return .receiving }
        isOver = true
        return .complete((0..<manifest.count).compactMap { written[$0] })
    }

    /// Called when the socket goes away with the batch unfinished. Nothing was
    /// delivered, so nothing should be left behind either.
    func abandon() {
        guard !isOver else { return }
        isOver = true
        discard()
    }

    private func refuse(_ message: String) -> Progress {
        isOver = true
        discard()
        return .refused(message)
    }

    private func discard() {
        for attachment in written.values {
            try? FileManager.default.removeItem(at: attachment.url)
        }
        written.removeAll()
    }
}
