import UIKit

/// One picture chosen on the phone, encoded and ready to go.
struct ImageAttachment: Identifiable, Equatable {
    let id: UUID
    /// The encoded bytes, exactly as they will be written on the Mac.
    let data: Data
    let format: AttachmentFrame.Format
    let pixelSize: CGSize
    /// Small enough to keep in a SwiftUI row without holding the full image.
    let thumbnail: UIImage

    init(id: UUID = UUID(), data: Data, format: AttachmentFrame.Format,
         pixelSize: CGSize, thumbnail: UIImage) {
        self.id = id
        self.data = data
        self.format = format
        self.pixelSize = pixelSize
        self.thumbnail = thumbnail
    }

    func frame(index: Int) -> AttachmentFrame {
        AttachmentFrame(index: index,
                        format: format,
                        byteCount: data.count,
                        width: Int(pixelSize.width),
                        height: Int(pixelSize.height))
    }

    /// Just the size, under a 78pt thumbnail. The pixel dimensions were in here
    /// too, and at that width the line truncated mid-number — "2.3 MB · 2576×1…"
    /// is a measurement nobody can read and a second one nobody asked for, since
    /// every attachment is resized to the same ceiling anyway.
    var summary: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    /// The whole of it, for VoiceOver — where there is no column to run out of.
    var spoken: String {
        "\(summary), \(Int(pixelSize.width)) by \(Int(pixelSize.height)) pixels"
    }

    static func == (lhs: ImageAttachment, rhs: ImageAttachment) -> Bool { lhs.id == rhs.id }
}

/// Turns a `UIImage` into something worth sending.
enum ImagePreparation {

    /// Claude's high-resolution tier reads an image at up to a 2576-pixel long
    /// edge and downscales anything larger before it looks at it. So a 12
    /// megapixel photograph is not more detail, it is more waiting: the same
    /// picture arrives at the model either way, having crossed the LAN four
    /// times as slowly and left a file four times the size on the Mac.
    ///
    /// This is a quality decision rather than a transport one — the upload
    /// channel would carry the original — which is why the number is the model's
    /// limit and not a guess at a safe payload size.
    static let maxLongEdge: CGFloat = 2576

    /// JPEG quality for a photograph. High enough that the compression is not
    /// what the agent is looking at.
    private static let jpegQuality: CGFloat = 0.9

    /// `lossless` picks PNG, for a screenshot or an annotation: those are mostly
    /// flat colour and small text, and JPEG spends its bytes turning the text
    /// into mush. A photograph is the other way round.
    static func prepare(_ image: UIImage, lossless: Bool) -> ImageAttachment? {
        let resized = downscaled(image)
        let size = CGSize(width: resized.size.width * resized.scale,
                          height: resized.size.height * resized.scale)

        var format: AttachmentFrame.Format = lossless ? .png : .jpeg
        var data = lossless ? resized.pngData() : resized.jpegData(compressionQuality: jpegQuality)

        // A PNG of a photograph, or of a screenshot of one, can still be huge.
        // Falling back to JPEG keeps a picture sendable rather than refusing it
        // for the sake of a format nobody asked for.
        if let encoded = data, encoded.count > UploadChannel.maxAttachmentBytes, lossless {
            format = .jpeg
            data = resized.jpegData(compressionQuality: jpegQuality)
        }
        guard var encoded = data else { return nil }
        var quality = jpegQuality
        while encoded.count > UploadChannel.maxAttachmentBytes, quality > 0.3 {
            quality -= 0.2
            format = .jpeg
            guard let retried = resized.jpegData(compressionQuality: quality) else { return nil }
            encoded = retried
        }
        guard encoded.count <= UploadChannel.maxAttachmentBytes else { return nil }

        let thumbnail = resized.preparingThumbnail(of: CGSize(width: 240, height: 240)) ?? resized
        return ImageAttachment(data: encoded, format: format, pixelSize: size, thumbnail: thumbnail)
    }

    /// Redrawn at scale 1, so the pixel size is the size: a `UIImage` at scale 3
    /// reports a third of its pixels in `size`, and a long edge measured in
    /// points would send a 7728-pixel screenshot believing it had resized it.
    private static func downscaled(_ image: UIImage) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale,
                            height: image.size.height * image.scale)
        let longEdge = max(pixels.width, pixels.height)
        guard longEdge > 0 else { return image }
        let factor = min(1, maxLongEdge / longEdge)
        let target = CGSize(width: (pixels.width * factor).rounded(.down),
                            height: (pixels.height * factor).rounded(.down))
        guard target.width >= 1, target.height >= 1 else { return image }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            // Drawing rather than transforming: this also resolves the
            // orientation a photograph carries in its metadata, which an agent
            // reading the file would otherwise see sideways.
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
