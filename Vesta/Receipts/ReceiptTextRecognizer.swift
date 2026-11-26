import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
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

/// Compares what Vision actually read. It never reconstructs an amount from
/// arithmetic: the multiplication and printed total only help rank readings.
struct ReceiptOCRAssessment {
    private static let locale = Locale(identifier: "en_US_POSIX")

    private var fiscalTotal: Decimal?
    private var payableTotal: Decimal?
    private var itemTotal: Decimal = 0
    private var discountTotal: Decimal = 0
    private var balancedRows = 0
    private var namedBalancedRows = 0
    private var inconsistentRows = 0
    private var ambiguousDiscountRows = 0
    private var balancedAmounts: [Decimal: Int] = [:]
    private var discountAmounts: [Decimal: Int] = [:]
    private var unclassifiedAmounts: [Decimal: Int] = [:]

    init(lines: [String]) {
        let itemPattern = #/(?:^|[^0-9.,\p{L}])([0-9]{1,6}(?:[.,][0-9]{1,4})?)\s*(?:L|SZT|KG|G|M)?\s*[*×X=]\s*([0-9]{1,9}[.,][0-9]{2,4})\s+([0-9]{1,9}[.,][0-9]{2}0{0,2})(?![0-9.,])/#.ignoresCase()
        let discountPattern = #/^(?:OPUST|RABAT)\b.*?([+-]?[0-9]{1,9}[.,][0-9]{2})(?:\s+PLN)?(?:\s+[A-G])?$/#
        let discountItemPattern = #/
            ^(?:OPUST|RABAT)\b.*?[^0-9.,\p{L}]
            ([0-9]{1,6}(?:[.,][0-9]{1,4})?|I(?=\s*SZT\b))\s*(?:L|SZT|KG|G|M)?\s*[*×X=]\s*
            ([0-9]{1,9}[.,][0-9]{2,4})\s+([0-9]{1,9}[.,][0-9]{2}0{0,2})(?![0-9.,])
            (?:\s*PLN(?![\p{L}\p{N}]))?(?:\s*[A-G](?!\p{L}))?(.*)$
            /#
        let negativeAmount = #/
            (?:^|[^\p{L}\p{N}.,])[-−–—]\s*([0-9]{1,9}[.,][0-9]{2})(?![0-9.,])
            (?:\s*PLN(?![\p{L}\p{N}]))?(?:\s*[A-G](?![\p{L}\p{N}]))?(?=$|[^\p{L}\p{N}.,])
            /#.ignoresCase()
        let unsignedAmount = #/^\s*\+?([0-9]{1,9}[.,][0-9]{2})(?:\s*PLN)?(?:\s*[A-G])?\s*$/#
        let totalPattern = #/^(SUMA PLN|DO ZAPLATY)\s+([0-9]{1,9}[.,][0-9]{2})\s*(?:PLN)?$/#
        for (index, line) in lines.enumerated() {
            let label = line.uppercased().folding(options: .diacriticInsensitive, locale: Self.locale)
                .replacingOccurrences(of: "Ł", with: "L")
                .trimmingCharacters(in: .whitespaces)
            if let total = label.wholeMatch(of: totalPattern), let amount = Self.amount(total.2) {
                if total.1 == "DO ZAPLATY" { payableTotal = amount } else { fiscalTotal = amount }
            } else if let item = label.wholeMatch(of: discountItemPattern),
                      let quantity = item.1 == "I" ? 1 : Self.amount(item.1),
                      let unitPrice = Self.amount(item.2), let lineTotal = Self.amount(item.3),
                      quantity > 0, unitPrice > 0, lineTotal > 0 {
                ambiguousDiscountRows += 1
                // A joined discount label obscures the positive amount's role.
                if Self.matchesProduct(quantity, unitPrice, lineTotal) {
                    unclassifiedAmounts[lineTotal, default: 0] += 1
                }
                for discount in item.4.matches(of: negativeAmount).compactMap({ Self.amount($0.1) }) {
                    recordDiscount(discount)
                }
                if let unknown = item.4.wholeMatch(of: unsignedAmount), let amount = Self.amount(unknown.1) {
                    unclassifiedAmounts[amount, default: 0] += 1
                }
                // A lone signed amount may be a separate OCR fragment of this discount.
                let next = index + 1
                if lines.indices.contains(next),
                   let discount = lines[next].trimmingCharacters(in: .whitespaces).wholeMatch(of: negativeAmount),
                   let amount = Self.amount(discount.1) {
                    recordDiscount(amount)
                }
            } else if let discount = label.wholeMatch(of: discountPattern), let amount = Self.amount(discount.1) {
                recordDiscount(amount)
            } else if let item = line.firstMatch(of: itemPattern),
                      let quantity = Self.amount(item.1),
                      let unitPrice = Self.amount(item.2),
                      let lineTotal = Self.amount(item.3) {
                if Self.matchesProduct(quantity, unitPrice, lineTotal) {
                    balancedRows += 1
                    balancedAmounts[lineTotal, default: 0] += 1
                    itemTotal += lineTotal
                    if line[..<item.range.lowerBound].contains(where: \.isLetter) { namedBalancedRows += 1 }
                } else {
                    inconsistentRows += 1
                }
            }
        }
    }

    private var printedTotal: Decimal? { payableTotal ?? fiscalTotal }
    private var calculationRows: Int { balancedRows + inconsistentRows + ambiguousDiscountRows }

    private var reconciles: Bool {
        guard let printedTotal, balancedRows > 0, inconsistentRows == 0, ambiguousDiscountRows == 0 else { return false }
        return itemTotal - discountTotal == printedTotal
    }

    var needsRetry: Bool {
        printedTotal != nil && calculationRows > 0 && !reconciles
    }

    func improves(on original: Self) -> Bool {
        // Additional names alone cannot account for an ambiguous amount.
        guard original.ambiguousDiscountRows == 0 || reconciles,
              original.printedTotal != nil,
              printedTotal == original.printedTotal,
              original.payableTotal.map({ $0 == payableTotal }) ?? true,
              original.fiscalTotal.map({ $0 == fiscalTotal }) ?? true,
              inconsistentRows <= original.inconsistentRows,
              ambiguousDiscountRows == 0,
              calculationRows >= original.calculationRows,
              namedBalancedRows >= original.namedBalancedRows,
              original.balancedAmounts.allSatisfy({ balancedAmounts[$0.key, default: 0] >= $0.value }),
              original.discountAmounts.allSatisfy({ discountAmounts[$0.key, default: 0] >= $0.value }),
              original.unclassifiedAmounts.allSatisfy({ amount, count in
                  let classified = original.balancedAmounts[amount, default: 0] + original.discountAmounts[amount, default: 0]
                  return balancedAmounts[amount, default: 0] + discountAmounts[amount, default: 0] >= classified + count
              }) else { return false }
        return (reconciles && !original.reconciles) || namedBalancedRows > original.namedBalancedRows
            || (balancedRows > original.balancedRows && inconsistentRows < original.inconsistentRows)
    }

    private static func amount(_ value: Substring) -> Decimal? {
        Decimal(string: value.replacingOccurrences(of: ",", with: "."), locale: locale)
    }

    private mutating func recordDiscount(_ amount: Decimal) {
        let magnitude = abs(amount)
        discountAmounts[magnitude, default: 0] += 1
        discountTotal += magnitude
    }

    private static func matchesProduct(_ quantity: Decimal, _ unitPrice: Decimal, _ lineTotal: Decimal) -> Bool {
        // Fuel and other fractional quantities are rounded to cents.
        var product = quantity * unitPrice
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 2, .plain)
        return rounded == lineTotal
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
    private static let renderContext = CIContext()

    func recognize(_ image: CGImage) async throws -> [TextFragment] {
        let primary = try await Self.read(image)
        let assessment = ReceiptOCRAssessment(lines: ReceiptLineOrdering.lines(from: primary))
        guard assessment.needsRetry else { return primary }
        try Task.checkCancellation()
        guard let alternateImage = Self.resampled(image) else { return primary }
        let alternate = try? await Self.read(alternateImage)
        try Task.checkCancellation()
        guard let alternate else { return primary }
        let alternateAssessment = ReceiptOCRAssessment(lines: ReceiptLineOrdering.lines(from: alternate))
        return alternateAssessment.improves(on: assessment) ? alternate : primary
    }

    private static func resampled(_ image: CGImage) -> CGImage? {
        // Different sampling can recover a digit or fragment from the same
        // photograph. Keep the whole image and cap the working resolution.
        let longEdge = max(image.width, image.height)
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = CIImage(cgImage: image)
        switch longEdge {
        case ..<850: filter.scale = 1.5
        case ..<2_000: filter.scale = 1.35
        default: filter.scale = Float(1_600) / Float(longEdge)
        }
        guard let output = filter.outputImage else { return nil }
        return renderContext.createCGImage(output, from: output.extent)
    }

    private static func read(_ image: CGImage) async throws -> [TextFragment] {
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
