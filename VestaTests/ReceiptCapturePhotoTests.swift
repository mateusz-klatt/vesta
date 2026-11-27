import UIKit
import XCTest
@testable import Vesta

@MainActor
final class ReceiptCapturePhotoTests: XCTestCase {
    func testPhotosCanBeReorderedAndTheNewLastPhotoRemoved() throws {
        let image = makeImage()
        let first = try ReceiptCapturePhoto(camera: image)
        let second = try ReceiptCapturePhoto(camera: image)
        let third = try ReceiptCapturePhoto(camera: image)
        var order = ReceiptPhotoOrder()
        order.append([first, second])
        order.append([third])

        order.move(first.id, by: -1)
        order.move(third.id, by: 1)
        XCTAssertEqual(order.photos.map(\.id), [first.id, second.id, third.id])

        order.move(second.id, by: -1)
        order.move(first.id, by: 1)
        XCTAssertEqual(order.photos.map(\.id), [second.id, third.id, first.id])

        order.removeLast()
        XCTAssertEqual(order.photos.map(\.id), [second.id, third.id])
    }

    func testStagedCameraPhotoKeepsUprightFullResolutionAndSmallThumbnail() async throws {
        let pixels = try XCTUnwrap(makeImage().cgImage)
        let rotated = UIImage(cgImage: pixels, scale: 1, orientation: .right)
        let staged = try ReceiptCapturePhoto(camera: rotated)

        let thumbnail = try XCTUnwrap(staged.thumbnail.cgImage)
        XCTAssertLessThan(thumbnail.width, thumbnail.height)
        XCTAssertLessThanOrEqual(thumbnail.height, 144)

        let image = try await staged.loadImage()
        XCTAssertEqual(image.width, pixels.height)
        XCTAssertEqual(image.height, pixels.width)
    }

    func testCameraCanAcceptTheNextShotAfterIgnoringDuplicateEvents() {
        let image = makeImage()
        let picker = UIImagePickerController()
        let info: [UIImagePickerController.InfoKey: Any] = [.originalImage: image]
        var accepted = 0
        let first = ReceiptCamera.Coordinator { _ in accepted += 1 }
        let second = ReceiptCamera.Coordinator { _ in accepted += 1 }

        first.imagePickerController(picker, didFinishPickingMediaWithInfo: info)
        first.imagePickerController(picker, didFinishPickingMediaWithInfo: info)
        second.imagePickerController(picker, didFinishPickingMediaWithInfo: info)
        second.imagePickerControllerDidCancel(picker)

        XCTAssertEqual(accepted, 2)
    }

    private func makeImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 480, height: 320), format: format).image {
            UIColor.white.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
        }
    }
}
