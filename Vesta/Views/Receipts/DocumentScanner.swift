import SwiftUI
import VisionKit

/// VisionKit's document camera: finds the receipt's edges, de-skews, and hands
/// back one image per page. Images go straight to OCR and are not kept.
struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([CGImage]) -> Void
    let onCancel: () -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_: VNDocumentCameraViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish, onCancel: onCancel) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([CGImage]) -> Void
        let onCancel: () -> Void

        init(onFinish: @escaping ([CGImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }

        func documentCameraViewController(_: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).cgImage }
            onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_: VNDocumentCameraViewController) { onCancel() }

        func documentCameraViewController(_: VNDocumentCameraViewController, didFailWithError _: any Error) {
            onCancel()
        }
    }
}
