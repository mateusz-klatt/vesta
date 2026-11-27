import CryptoKit
import ImageIO
import PhotosUI
import SwiftUI
import UIKit

/// Staged photos keep a thumbnail and an encoded camera image or a picker reference.
/// Full-resolution pixels are decoded when the recognition loop requests this photo.
struct ReceiptCapturePhoto: Identifiable {
    let id = UUID()
    let thumbnail: UIImage
    let encodedByteCount: Int
    let libraryIdentity: LibraryIdentity?
    private let source: Source

    struct LibraryIdentity {
        let identifier: String?
        private let digest: SHA256.Digest

        init(identifier: String?, data: Data) {
            self.identifier = identifier
            digest = SHA256.hash(data: data)
        }

        func matches(_ other: Self) -> Bool {
            if let identifier, let otherIdentifier = other.identifier {
                return identifier == otherIdentifier
            }
            return digest == other.digest
        }
    }

    private enum Source {
        case camera(Data)
        case library(PhotosPickerItem)
    }

    init(camera image: UIImage, remainingBytes: Int = ReceiptPhotoOrder.maxBytes) throws {
        guard let upright = image.uprightReceiptImage,
              let data = UIImage(cgImage: upright).jpegData(compressionQuality: 0.95) else {
            throw ReceiptError.photoUnavailable
        }
        guard data.count <= remainingBytes else { throw ReceiptPhotoOrder.Limit.bytes }
        thumbnail = try Self.thumbnail(from: data)
        encodedByteCount = data.count
        libraryIdentity = nil
        source = .camera(data)
    }

    fileprivate init(library item: PhotosPickerItem, data: Data, identity: LibraryIdentity) throws {
        thumbnail = try Self.thumbnail(from: data)
        encodedByteCount = data.count
        libraryIdentity = identity
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

    fileprivate static func data(from item: PhotosPickerItem) async throws -> Data {
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
    static let maxPhotos = 8
    // Budget the combined encoded sizes, including assets held by reference.
    // Full-resolution pixels are still loaded one at a time for recognition.
    static let maxBytes = 60 * 1024 * 1024

    enum Limit: Error, Equatable {
        case count, bytes

        var message: LocalizedStringResource {
            switch self {
            case .count: "You can add up to 8 receipt photos."
            case .bytes: "Receipt photos can total up to 60 MiB. Remove a photo or choose smaller photos."
            }
        }
    }

    private let byteBudget: Int
    private(set) var photos: [ReceiptCapturePhoto] = []

    init(byteBudget: Int = Self.maxBytes) {
        self.byteBudget = byteBudget
    }

    var remainingSlots: Int { Self.maxPhotos - photos.count }
    var remainingBytes: Int { byteBudget - photos.reduce(0) { $0 + $1.encodedByteCount } }

    var limit: Limit? {
        if remainingSlots == 0 { return .count }
        if remainingBytes == 0 { return .bytes }
        return nil
    }

    mutating func append(_ photo: ReceiptCapturePhoto) throws(Limit) {
        if let limit { throw limit }
        guard photo.encodedByteCount <= remainingBytes else { throw .bytes }
        photos.append(photo)
    }

    @MainActor
    mutating func append(library item: PhotosPickerItem) async throws {
        let identifier = item.itemIdentifier
        if let identifier, photos.contains(where: { $0.libraryIdentity?.identifier == identifier }) {
            return
        }
        if let limit { throw limit }
        let data = try await ReceiptCapturePhoto.data(from: item)
        // An asset larger than the entire budget cannot already be staged.
        guard data.count <= byteBudget else { throw Limit.bytes }
        let identity = ReceiptCapturePhoto.LibraryIdentity(identifier: identifier, data: data)
        guard !photos.contains(where: { $0.libraryIdentity?.matches(identity) == true }) else { return }
        guard data.count <= remainingBytes else { throw Limit.bytes }
        try append(ReceiptCapturePhoto(library: item, data: data, identity: identity))
    }

    mutating func remove(_ id: ReceiptCapturePhoto.ID) {
        photos.removeAll { $0.id == id }
    }

    mutating func move(_ id: ReceiptCapturePhoto.ID, by offset: Int) {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              photos.indices.contains(index + offset) else { return }
        let photo = photos.remove(at: index)
        photos.insert(photo, at: index + offset)
    }
}
