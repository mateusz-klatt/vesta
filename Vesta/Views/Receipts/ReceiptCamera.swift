import SwiftUI
import UniformTypeIdentifiers

/// The system photo camera returns one accepted image for each presentation.
struct ReceiptCamera: UIViewControllerRepresentable {
    let onComplete: @MainActor (UIImage?) -> Void

    static var isSupported: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let camera = UIImagePickerController()
        camera.sourceType = .camera
        camera.mediaTypes = [UTType.image.identifier]
        camera.cameraCaptureMode = .photo
        camera.delegate = context.coordinator
        return camera
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        // Treat cancel and use-photo as terminal for this presentation.
        private var onComplete: (@MainActor (UIImage?) -> Void)?

        init(onComplete: @escaping @MainActor (UIImage?) -> Void) { self.onComplete = onComplete }

        func imagePickerController(
            _: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            complete(with: info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) { complete(with: nil) }

        private func complete(with image: UIImage?) {
            let handler = onComplete
            onComplete = nil
            handler?(image)
        }
    }
}

extension UIImage {
    /// Vision receives pixels without UIImage's orientation metadata.
    var uprightReceiptImage: CGImage? {
        if imageOrientation == .up { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}
