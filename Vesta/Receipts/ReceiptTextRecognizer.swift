import CoreGraphics
import Foundation
import Vision

/// One recognised text fragment with its Vision bounding box (normalised,
/// origin bottom-left — Vision's convention).
struct TextFragment: Equatable, Sendable {
    let text: String
    let box: CGRect
}

/// Puts Vision's fragments back into reading order. Vision returns boxes in no
/// particular order, and a receipt line often comes back as several fragments
/// (name on the left, price on the right). hestia's parser is line-based, so we
/// group fragments into horizontal bands by their vertical centre, top band
/// first, and read each band left to right.
enum ReceiptLineOrdering {
    /// Fragments whose centres are within this fraction of the median fragment
    /// height belong to the same line.
    static let bandTolerance: CGFloat = 0.5

    static func lines(from fragments: [TextFragment]) -> [String] {
        let usable = fragments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else { return [] }
        let heights = usable.map(\.box.height).sorted()
        let tolerance = max(heights[heights.count / 2] * bandTolerance, 0.002)

        // Top of the page first: Vision's y grows upwards.
        let sorted = usable.sorted { $0.box.midY > $1.box.midY }
        var bands: [[TextFragment]] = []
        var bandMid: CGFloat = 0
        for fragment in sorted {
            if let last = bands.indices.last, abs(fragment.box.midY - bandMid) <= tolerance {
                bands[last].append(fragment)
                let mids = bands[last].map(\.box.midY)
                bandMid = mids.reduce(0, +) / CGFloat(mids.count)
            } else {
                bands.append([fragment])
                bandMid = fragment.box.midY
            }
        }
        return bands.map { band in
            band.sorted { $0.box.minX < $1.box.minX }
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
        }
    }
}

/// On-device OCR. Abstracted so the capture flow can be tested without Vision.
protocol ReceiptTextRecognizing: Sendable {
    func recognize(_ image: CGImage) async throws -> [TextFragment]
}

/// Vision-backed OCR: accurate level, Polish first, then English. Nothing leaves
/// the device here; the image is dropped by the caller as soon as this returns.
struct VisionReceiptRecognizer: ReceiptTextRecognizing {
    static let preferredLanguages = ["pl-PL", "en-US"]

    func recognize(_ image: CGImage) async throws -> [TextFragment] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = Set(request.supportedRecognitionLanguages.map { $0.maximalIdentifier })
        let wanted = Self.preferredLanguages.map { Locale.Language(identifier: $0) }
        let usable = wanted.filter { supported.contains($0.maximalIdentifier) }
        request.recognitionLanguages = usable.isEmpty ? wanted : usable

        let observations = try await request.perform(on: image)
        return observations.compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            return TextFragment(text: best.string, box: observation.boundingBox.cgRect)
        }
    }

    /// Whether this device's Vision can read Polish (diacritics `ą ę ł ż …`).
    /// Shown as a hint on the edit screen when false.
    static var supportsPolish: Bool {
        let request = RecognizeTextRequest()
        let polish = Locale.Language(identifier: "pl-PL").maximalIdentifier
        return request.supportedRecognitionLanguages.contains { $0.maximalIdentifier == polish }
    }
}
