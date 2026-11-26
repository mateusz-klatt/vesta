import CoreGraphics
import Foundation
import Vision

/// One recognised text fragment with its Vision bounding box (normalised,
/// origin bottom-left — Vision's convention).
struct TextFragment: Equatable, Sendable {
    let text: String
    let box: CGRect
    /// Rise over run of the upper text edge in normalised image coordinates.
    let rowSlope: CGFloat?

    init(text: String, box: CGRect, rowSlope: CGFloat? = nil) {
        self.text = text
        self.box = box
        self.rowSlope = rowSlope
    }
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
    private static let slopeNeighborhood: CGFloat = 0.075

    static func lines(from fragments: [TextFragment]) -> [String] {
        let usable = fragments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else { return [] }
        let heights = usable.map(\.box.height).sorted()
        let tolerance = max(heights[heights.count / 2] * bandTolerance, 0.002)

        // Top of the page first: Vision's y grows upwards.
        let sorted = alignRows(usable).sorted { $0.box.midY > $1.box.midY }
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

    private static func alignRows(_ fragments: [TextFragment]) -> [TextFragment] {
        // Use long text edges rather than short price boxes, whose corners
        // provide a noisy slope. Give the longer edges more weight.
        let samples = fragments.compactMap { fragment -> (y: CGFloat, slope: CGFloat, weight: CGFloat)? in
            guard fragment.box.width > 0.11, let slope = fragment.rowSlope, abs(slope) < 0.25 else { return nil }
            return (fragment.box.midY, slope, fragment.box.width * fragment.box.width)
        }
        return fragments.map { fragment in
            let nearby = samples.filter { abs($0.y - fragment.box.midY) < slopeNeighborhood }
            let weight = nearby.reduce(0) { $0 + $1.weight }
            guard weight > 0 else { return fragment }
            let slope = nearby.reduce(0) { $0 + $1.slope * $1.weight } / weight
            // A single tilted title should not shift otherwise level rows.
            let agreeingEdges = nearby.filter { abs($0.slope) >= 0.01 && $0.slope * slope > 0 }
            guard agreeingEdges.count >= 2 else { return fragment }
            // Project centres to a common x. Estimate the slope locally because
            // the text can curve across a crumpled or curled receipt.
            let rise = slope * (fragment.box.midX - 0.5)
            return TextFragment(text: fragment.text, box: fragment.box.offsetBy(dx: 0, dy: -rise))
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
            let width = observation.topRight.x - observation.topLeft.x
            let slope = width > 0.10 ? (observation.topRight.y - observation.topLeft.y) / width : nil
            return TextFragment(text: best.string, box: observation.boundingBox.cgRect, rowSlope: slope)
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
