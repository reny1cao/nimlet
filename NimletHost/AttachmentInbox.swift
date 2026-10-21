import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where an uploaded image lands on the Mac, and what has to be true of it first.
///
/// A target is sent the *path*, so the file is the message: it outlives the
/// delivery, an agent opens it whenever it gets round to reading the prompt, and
/// the user may well open it again afterwards. That makes three things this has
/// to own rather than trust.
///
/// The phone never names the file. A name that arrived over the network is a
/// path traversal waiting to happen, and there is nothing a phone could tell us
/// about where to put a file that we would want to hear.
///
/// The bytes are checked before they are written, not after. The header says
/// "this is a PNG"; only ImageIO can say whether it is, and a file that is not
/// the image it claims to be is one an agent will read and misreport.
///
/// And it is pruned. An input surface that silently accumulates every photograph
/// ever sent through it is a disk-space bug with a two-year fuse.
enum AttachmentInbox {

    enum Refusal: Error, Equatable {
        case noDirectory
        case empty
        case tooLarge(bytes: Int)
        case shortRead(expected: Int, got: Int)
        case notAnImage
        case wrongFormat(claimed: String, actual: String)
        case tooManyPixels(width: Int, height: Int)
        case writeFailed(String)

        var message: String {
            switch self {
            case .noDirectory:
                return "Nimlet can't find its Application Support folder"
            case .empty:
                return "That attachment arrived empty"
            case .tooLarge(let bytes):
                return "That attachment is \(bytes / (1 << 20)) MB — the limit is \(UploadChannel.maxAttachmentBytes / (1 << 20)) MB"
            case .shortRead(let expected, let got):
                return "That attachment said \(expected) bytes and delivered \(got)"
            case .notAnImage:
                return "Those bytes aren't an image Nimlet can read"
            case .wrongFormat(let claimed, let actual):
                return "That attachment claimed \(claimed) and is \(actual)"
            case .tooManyPixels(let width, let height):
                return "\(width)×\(height) is past the \(UploadChannel.maxPixelsPerSide)px limit"
            case .writeFailed(let reason):
                return "Couldn't save the attachment: \(reason)"
            }
        }
    }

    /// Kept beside the delivery log, under the same owner-only directory: both
    /// of them describe what somebody was working on and when.
    static let directoryURL: URL? = {
        guard let base = SupportDirectory.url else { return nil }
        let directory = base.appendingPathComponent("inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }()

    /// Files older than this are deleted on the next upload. A week is long
    /// enough that "the screenshot I sent on Monday" is still there and short
    /// enough that a year of them is not.
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    /// And a ceiling regardless of age, because a busy afternoon can outrun any
    /// sensible retention window.
    static let maximumDirectoryBytes = 512 << 20

    private static let lock = NSLock()
    private static let stamps: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Validates and writes one attachment, returning where it landed.
    static func write(_ payload: Data, frame: AttachmentFrame) -> Result<URL, Refusal> {
        guard let directoryURL else { return .failure(.noDirectory) }
        guard !payload.isEmpty else { return .failure(.empty) }
        guard payload.count <= UploadChannel.maxAttachmentBytes else {
            return .failure(.tooLarge(bytes: payload.count))
        }
        // The header's own count, checked against what the framing delivered. The
        // two can only disagree if the stream is desynced, and a desynced stream
        // is exactly when bytes look most like an image and least like one.
        guard frame.byteCount == payload.count else {
            return .failure(.shortRead(expected: frame.byteCount, got: payload.count))
        }

        guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else {
            return .failure(.notAnImage)
        }
        guard type == frame.format.uniformTypeIdentifier else {
            return .failure(.wrongFormat(claimed: frame.format.uniformTypeIdentifier, actual: type))
        }
        // Properties rather than a decode: the dimensions are in the header of
        // every format we accept, and decoding 25 MB of pixels to learn them
        // would be the one place this is worth being slow about.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return .failure(.notAnImage)
        }
        guard width <= UploadChannel.maxPixelsPerSide, height <= UploadChannel.maxPixelsPerSide else {
            return .failure(.tooManyPixels(width: width, height: height))
        }

        lock.lock()
        defer { lock.unlock() }
        let url = availableURL(in: directoryURL, index: frame.index, format: frame.format)
        guard FileManager.default.createFile(atPath: url.path, contents: payload,
                                            attributes: [.posixPermissions: 0o600]) else {
            return .failure(.writeFailed(url.lastPathComponent))
        }
        return .success(url)
    }

    /// `nimlet-20260925-140233-1.png`, and a suffix if that exists.
    ///
    /// Named by the Mac's clock and the position in the batch, which between
    /// them are what a person is looking for in a Finder window a day later.
    /// Nothing from the phone is in here, on purpose.
    private static func availableURL(in directory: URL, index: Int, format: AttachmentFrame.Format) -> URL {
        let stamp = stamps.string(from: Date())
        let base = "nimlet-\(stamp)-\(index + 1)"
        var candidate = directory.appendingPathComponent("\(base).\(format.fileExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).\(format.fileExtension)")
            suffix += 1
        }
        return candidate
    }

    /// Deletes what is too old, then what is over the ceiling, oldest first.
    static func prune() {
        guard let directoryURL else { return }
        let manager = FileManager.default
        lock.lock()
        defer { lock.unlock() }
        guard let names = try? manager.contentsOfDirectory(at: directoryURL,
                                                           includingPropertiesForKeys: [.contentModificationDateKey,
                                                                                        .fileSizeKey],
                                                           options: [.skipsHiddenFiles]) else { return }
        var files: [(url: URL, date: Date, bytes: Int)] = names.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = values.contentModificationDate else { return nil }
            return (url, date, values.fileSize ?? 0)
        }

        let cutoff = Date().addingTimeInterval(-retention)
        files.removeAll { file in
            guard file.date < cutoff else { return false }
            try? manager.removeItem(at: file.url)
            return true
        }

        var total = files.reduce(0) { $0 + $1.bytes }
        guard total > maximumDirectoryBytes else { return }
        for file in files.sorted(by: { $0.date < $1.date }) {
            try? manager.removeItem(at: file.url)
            total -= file.bytes
            if total <= maximumDirectoryBytes { break }
        }
    }

    static func reveal() {
        guard let directoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
    }
}
