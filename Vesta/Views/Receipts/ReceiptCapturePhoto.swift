import ImageIO
import PhotosUI
import SwiftUI
import UIKit

/// Staged photos keep a thumbnail and an encoded camera image or a picker reference.
/// Full-resolution pixels are decoded when the recognition loop requests this photo.
struct ReceiptCapturePhoto: Identifiable {
    let id = UUID()
    let thumbnail: UIImage
    private let source: Source

    private enum Source {
        case camera(Data)
        case library(PhotosPickerItem)
    }

    var libraryIdentifier: String? {
        guard case .library(let item) = source else { return nil }
        return item.itemIdentifier
    }

    init(camera image: UIImage) throws {
        guard let upright = image.uprightReceiptImage,
              let data = UIImage(cgImage: upright).jpegData(compressionQuality: 0.95) else {
            throw ReceiptError.photoUnavailable
        }
        thumbnail = try Self.thumbnail(from: data)
        source = .camera(data)
    }

    @MainActor
    init(library item: PhotosPickerItem) async throws {
        let data = try await Self.data(from: item)
        thumbnail = try Self.thumbnail(from: data)
        source = .library(item)
    }

    @MainActor
    func loadImage() async throws -> CGImage {
        switch source {
        case .camera(let data): try Self.image(from: data)
        case .library(let item): try await Self.loadImage(from: item)
        }
    }

    @MainActor
    static func loadImage(from item: PhotosPickerItem) async throws -> CGImage {
        let data = try await data(from: item)
        return try image(from: data)
    }

    private static func data(from item: PhotosPickerItem) async throws -> Data {
        guard let data = try await item.loadTransferable(type: Data.self) else { throw ReceiptError.photoUnavailable }
        try Task.checkCancellation()
        return data
    }

    private static func image(from data: Data) throws -> CGImage {
        try autoreleasepool {
            guard let image = UIImage(data: data)?.uprightReceiptImage else { throw ReceiptError.photoUnavailable }
            return image
        }
    }

    private static func thumbnail(from data: Data) throws -> UIImage {
        try autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 144,
            ]
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                throw ReceiptError.photoUnavailable
            }
            return UIImage(cgImage: image)
        }
    }
}

struct ReceiptPhotoOrder {
    private(set) var photos: [ReceiptCapturePhoto] = []

    mutating func append(_ newPhotos: [ReceiptCapturePhoto]) { photos.append(contentsOf: newPhotos) }

    mutating func removeLast() { _ = photos.popLast() }

    mutating func move(_ id: ReceiptCapturePhoto.ID, by offset: Int) {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              photos.indices.contains(index + offset) else { return }
        let photo = photos.remove(at: index)
        photos.insert(photo, at: index + offset)
    }
}
