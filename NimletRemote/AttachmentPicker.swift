import PhotosUI
import SwiftUI
import UIKit

/// What is attached to the message being composed, and how to take one back off.
///
/// Thumbnails rather than file names: the phone is beside the keyboard and the
/// question being answered at a glance is "is that the right screenshot", which
/// no file name has ever answered.
///
/// Small ones. This strip lives inside the composer, above the message being
/// written, and it used to take 90pt of it — a 72pt tile with the file's size
/// printed underneath — to answer a question that is already answered by a
/// thumbnail half that size. "330 KB" is not the question, and it was the only
/// text on the screen nobody had ever read on purpose. Both the size and the
/// format are still spoken by VoiceOver, where a picture cannot be glanced at.
struct AttachmentStrip: View {
    let attachments: [ImageAttachment]
    let onRemove: (ImageAttachment) -> Void

    private static let side: CGFloat = 46

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: attachment.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: Self.side, height: Self.side)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        // Nudged out over the corner rather than inset into it:
                        // a 44pt target on a 46pt tile would otherwise cover
                        // the picture it is asking about.
                        Button {
                            onRemove(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.65))
                                .frame(width: 26, height: 26)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 7, y: -7)
                        .accessibilityLabel("Remove attachment")
                    }
                    .padding(.top, 5)
                    .padding(.trailing, 5)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Attachment, \(attachment.spoken)")
                }
            }
        }
    }
}

/// The camera, for the thing on the desk rather than the thing on the screen.
///
/// `UIImagePickerController` rather than a `PhotosPicker`: this is a capture, not
/// a selection, and the picker has no camera in it.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let onFinish: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onFinish: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                  didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onCapture(image) }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
}

/// Loads what the photo picker handed back and encodes it for the wire.
enum AttachmentLoader {

    /// Returns what could be prepared, and a message for whatever could not.
    ///
    /// A picked item that fails is not a reason to drop the rest of the batch:
    /// one HEIC the phone cannot decode should cost that one picture, not the
    /// three screenshots beside it.
    static func load(_ items: [PhotosPickerItem]) async -> (attachments: [ImageAttachment], problem: String?) {
        var prepared: [ImageAttachment] = []
        var failures = 0
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                failures += 1
                continue
            }
            // A screenshot arrives as PNG and is mostly flat colour and small
            // text, which JPEG turns to mush; a photograph is the other way
            // round. What the library says it is decides which.
            let lossless = item.supportedContentTypes.contains { $0.conforms(to: .png) }
            guard let attachment = ImagePreparation.prepare(image, lossless: lossless) else {
                failures += 1
                continue
            }
            prepared.append(attachment)
        }
        let problem = failures == 0
            ? nil
            : "\(failures) image\(failures == 1 ? "" : "s") couldn't be prepared"
        return (prepared, problem)
    }
}
