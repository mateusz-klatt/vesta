import UIKit
import XCTest
@testable import Vesta

@MainActor
final class ReceiptCapturePhotoTests: XCTestCase {
    func testPhotosCanBeReorderedAndAnyPhotoRemoved() throws {
        let image = makeImage()
        let first = try ReceiptCapturePhoto(camera: image)
        let second = try ReceiptCapturePhoto(camera: image)
        let third = try ReceiptCapturePhoto(camera: image)
        var order = ReceiptPhotoOrder()
        try order.append(first)
        try order.append(second)
        try order.append(third)

        order.move(first.id, by: -1)
        order.move(third.id, by: 1)
        XCTAssertEqual(order.photos.map(\.id), [first.id, second.id, third.id])

        order.move(second.id, by: -1)
        order.move(first.id, by: 1)
        XCTAssertEqual(order.photos.map(\.id), [second.id, third.id, first.id])

        order.remove(third.id)
        XCTAssertEqual(order.photos.map(\.id), [second.id, first.id])
    }

    func testStagingStopsAtEightPhotosAndRemovalRestoresPickerSlot() throws {
        let image = makeImage()
        let photos = try (0..<9).map { _ in try ReceiptCapturePhoto(camera: image) }
        var order = ReceiptPhotoOrder()
        XCTAssertEqual(order.remainingSlots, 8)

        for photo in photos.prefix(8) {
            try order.append(photo)
        }
        XCTAssertEqual(order.remainingSlots, 0)
        XCTAssertEqual(order.limit, .count)
        XCTAssertThrowsError(try order.append(photos[8])) {
            XCTAssertEqual($0 as? ReceiptPhotoOrder.Limit, .count)
        }
        XCTAssertEqual(order.photos.count, 8)

        order.remove(photos[2].id)
        XCTAssertEqual(order.remainingSlots, 1)
        XCTAssertNil(order.limit)
        try order.append(photos[8])
        XCTAssertEqual(order.photos.last?.id, photos[8].id)
    }

    func testStageByteBudgetRejectsOversizedAdditionAndRemovalRestoresCapacity() throws {
        let image = makeImage()
        let first = try ReceiptCapturePhoto(camera: image)
        let second = try ReceiptCapturePhoto(camera: image)
        var partial = ReceiptPhotoOrder(byteBudget: first.encodedByteCount + second.encodedByteCount - 1)
        try partial.append(first)
        XCTAssertThrowsError(try partial.append(second)) {
            XCTAssertEqual($0 as? ReceiptPhotoOrder.Limit, .bytes)
        }
        XCTAssertEqual(partial.photos.map(\.id), [first.id])

        var order = ReceiptPhotoOrder(byteBudget: first.encodedByteCount + second.encodedByteCount)
        XCTAssertEqual(ReceiptPhotoOrder().remainingBytes, 60 * 1024 * 1024)

        try order.append(first)
        XCTAssertEqual(order.remainingBytes, second.encodedByteCount)
        XCTAssertThrowsError(try ReceiptCapturePhoto(camera: image, remainingBytes: 0)) {
            XCTAssertEqual($0 as? ReceiptPhotoOrder.Limit, .bytes)
        }
        try order.append(second)
        XCTAssertEqual(order.remainingBytes, 0)
        XCTAssertEqual(order.limit, .bytes)
        XCTAssertThrowsError(try order.append(second)) {
            XCTAssertEqual($0 as? ReceiptPhotoOrder.Limit, .bytes)
        }
        XCTAssertEqual(order.photos.map(\.id), [first.id, second.id])

        order.remove(first.id)
        XCTAssertEqual(order.remainingBytes, first.encodedByteCount)
        XCTAssertNil(order.limit)
    }

    func testGalleryIdentityUsesContentWhenThePickerHasNoIdentifier() {
        let bytes = Data([1, 2, 3])
        let sameBytes = Data([1, 2, 3])
        let differentBytes = Data([1, 2, 4])
        let identify = ReceiptCapturePhoto.LibraryIdentity.init(identifier:data:)

        XCTAssertTrue(identify(nil, bytes).matches(identify(nil, sameBytes)))
        XCTAssertTrue(identify(nil, bytes).matches(identify("asset", sameBytes)))
        XCTAssertTrue(identify("asset", bytes).matches(identify(nil, sameBytes)))
        XCTAssertFalse(identify(nil, bytes).matches(identify(nil, differentBytes)))
        XCTAssertTrue(identify("asset", bytes).matches(identify("asset", differentBytes)))
        XCTAssertFalse(identify("asset", bytes).matches(identify("other", bytes)))
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
