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
    private static let priceColumnTolerance: CGFloat = 0.03

    static func lines(from fragments: [TextFragment]) -> [String] {
        let usable = fragments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else { return [] }
        let heights = usable.map(\.box.height).sorted()
        let tolerance = max(heights[heights.count / 2] * bandTolerance, 0.002)
        let text = usable.map { $0.text.trimmingCharacters(in: .whitespaces) }
        let centers = alignRows(usable)
        let rows = discountRows(in: usable, text: text, centers: centers, tolerance: tolerance)
        return rows.map { row in
            row.sorted { usable[$0].box.minX < usable[$1].box.minX }
                .map { text[$0] }
                .joined(separator: " ")
        }
    }

    private static func bands(at centers: [CGFloat], tolerance: CGFloat) -> [[Int]] {
        // Top of the page first: Vision's y grows upwards.
        let sorted = centers.indices.sorted { centers[$0] > centers[$1] }
        var bands: [[Int]] = []
        var bandMid: CGFloat = 0
        for index in sorted {
            if let last = bands.indices.last, abs(centers[index] - bandMid) <= tolerance {
                bands[last].append(index)
                bandMid = bands[last].reduce(0) { $0 + centers[$1] } / CGFloat(bands[last].count)
            } else {
                bands.append([index])
                bandMid = centers[index]
            }
        }
        return bands
    }

    private static func discountRows(
        in fragments: [TextFragment], text: [String], centers: [CGFloat], tolerance: CGFloat
    ) -> [[Int]] {
        var positions = centers
        let originalRows = bands(at: positions, tolerance: tolerance)
        var rows = originalRows
        let signedPrice = #/^[-−][0-9]{1,9}[.,][0-9]{2}(?:\s*PLN)?(?:\s*[A-G])?$/#.ignoresCase()
        let orphanPrices = originalRows.compactMap { row -> Int? in
            guard row.count == 1, text[row[0]].wholeMatch(of: signedPrice) != nil else { return nil }
            return row[0]
        }
        guard !orphanPrices.isEmpty else { return rows }

        let discountPrefix = #/^(?:OPUST|RABAT)\b/#.ignoresCase()
        let amountTail = #/(?:^|\s)[+−-]?[0-9]{1,9}[.,][0-9]{2}(?:\s*PLN)?(?:\s*[A-G])?$/#.ignoresCase()
        let calculation = #/^(?:[0-9]{1,6}(?:[.,][0-9]{1,4})?|I(?=\s*SZT\b))\s*(?:L|SZT|KG|G|M)?\s*[*×X=]\s*[0-9]{1,9}[.,][0-9]{2}\s+[0-9]{1,9}[.,][0-9]{2}(?:\s*PLN)?(?:\s*[A-G])?$/#.ignoresCase()
        let boxes = fragments.map(\.box)
        let discountLabels = text.indices.filter {
            text[$0].firstMatch(of: discountPrefix) != nil && text[$0].firstMatch(of: amountTail) == nil
        }
        func rawAligned(_ label: Int, with amount: Int) -> Bool {
            boxes[label].maxX <= boxes[amount].minX && abs(boxes[amount].midY - boxes[label].midY) <= tolerance
        }

        for row in originalRows where row.count == 2 {
            let ordered = row.sorted { boxes[$0].minX < boxes[$1].minX }
            let label = ordered[0], item = ordered[1]
            guard discountLabels.contains(label),
                  text[item].wholeMatch(of: calculation) != nil,
                  boxes[label].maxX <= boxes[item].minX,
                  abs(boxes[label].midY - boxes[item].midY) > tolerance else { continue }
            let signed = orphanPrices.filter { candidate in
                rawAligned(label, with: candidate)
                    && abs(boxes[candidate].maxX - boxes[item].maxX) <= priceColumnTolerance
            }
            guard signed.count == 1, let discount = signed.first,
                  !discountLabels.contains(where: { $0 != label && rawAligned($0, with: discount) }),
                  rows.contains([discount]) else { continue }

            // The adjusted centers disagree with the raw boxes here. Use the
            // measured offsets from the label for this pair only.
            var proposed = positions
            for index in [item, discount] {
                proposed[index] = positions[label] + (boxes[index].midY - boxes[label].midY)
            }
            let columnAmounts = boxes.indices.filter {
                abs(boxes[$0].maxX - boxes[item].maxX) <= priceColumnTolerance
                    && text[$0].firstMatch(of: amountTail) != nil
            }
            guard columnAmounts.sorted(by: { positions[$0] > positions[$1] }) ==
                    columnAmounts.sorted(by: { proposed[$0] > proposed[$1] }) else { continue }

            let candidate = bands(at: proposed, tolerance: tolerance)
            func otherRows(_ groups: [[Int]]) -> [[Int]] {
                groups.map { row in row.filter { $0 != item && $0 != discount } }.filter { !$0.isEmpty }
            }
            guard candidate.contains(where: { $0.count == 2 && $0.contains(label) && $0.contains(discount) }),
                  let itemRow = candidate.first(where: { $0.contains(item) }),
                  itemRow.allSatisfy({
                      $0 == item || (
                          boxes[$0].maxX <= boxes[item].minX
                              && abs(boxes[$0].midY - boxes[item].midY) <= tolerance
                              && text[$0].firstMatch(of: amountTail) == nil
                              && text[$0].firstMatch(of: discountPrefix) == nil
                      )
                  }),
                  otherRows(rows) == otherRows(candidate) else { continue }
            positions = proposed
            rows = candidate
        }
        return rows
    }

    private static func alignRows(_ fragments: [TextFragment]) -> [CGFloat] {
        // Use long text edges rather than short price boxes, whose corners
        // provide a noisy slope. Give the longer edges more weight.
        let samples = fragments.compactMap { fragment -> (y: CGFloat, slope: CGFloat, weight: CGFloat)? in
            guard fragment.box.width > 0.11, let slope = fragment.rowSlope, abs(slope) < 0.25 else { return nil }
            return (fragment.box.midY, slope, fragment.box.width * fragment.box.width)
        }
        return fragments.map { fragment in
            let nearby = samples.filter { abs($0.y - fragment.box.midY) < slopeNeighborhood }
            let weight = nearby.reduce(0) { $0 + $1.weight }
            guard weight > 0 else { return fragment.box.midY }
            let slope = nearby.reduce(0) { $0 + $1.slope * $1.weight } / weight
            // A single tilted title should not shift otherwise level rows.
            let agreeingEdges = nearby.filter { abs($0.slope) >= 0.01 && $0.slope * slope > 0 }
            guard agreeingEdges.count >= 2 else { return fragment.box.midY }
            // Project centres to a common x. Estimate the slope locally because
            // the text can curve across a crumpled or curled receipt.
            let rise = slope * (fragment.box.midX - 0.5)
            return fragment.box.midY - rise
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

/// Horizontal crops described in source pixels, with y measured from the top.
private struct ReceiptOCRStrip {
    let rows: Range<Int>
    let ownedRows: Range<CGFloat>

    static func plan(width: Int, height: Int) -> [Self] {
        // Ordinary photos use the whole-photo OCR path. Above 3:1, a strip
        // no taller than 3/4 of the width makes small print larger relative
        // to Vision's 1/32 minimum text height fraction at native resolution.
        guard CGFloat(height) / CGFloat(width) > 3 else { return [] }
        let maxStripHeight = max(1, width * 3 / 4)
        let overlap = maxStripHeight / 4
        let halfOverlap = CGFloat(overlap) / 2
        let stripCount = (height - overlap - 1) / (maxStripHeight - overlap) + 1
        // Distribute the rows (counting overlaps twice) evenly among strips
        // so the last strip also has about a quarter of its height in overlap.
        let rowsWithOverlap = height + (stripCount - 1) * overlap
        let stripHeight = rowsWithOverlap / stripCount
        let extraRows = rowsWithOverlap % stripCount
        return (0..<stripCount).map { index in
            let top = index * (stripHeight - overlap) + min(index, extraRows)
            let bottom = top + stripHeight + (index < extraRows ? 1 : 0)
            let ownedTop = index == 0 ? 0 : CGFloat(top) + halfOverlap
            let ownedBottom = index == stripCount - 1 ? CGFloat(height) : CGFloat(bottom) - halfOverlap
            return Self(rows: top..<bottom, ownedRows: ownedTop..<ownedBottom)
        }
    }

    func map(_ fragment: TextFragment, toImageHeight imageHeight: Int) -> TextFragment? {
        let box = fragment.box
        let stripHeight = CGFloat(rows.count)
        let centerFromTop = CGFloat(rows.upperBound) - box.midY * stripHeight
        // Split the overlap at its midpoint, keeping each fragment from the
        // strip whose edge is farther away. The lower strip owns the cut itself.
        guard ownedRows.contains(centerFromTop) else { return nil }

        // Vision measures y from the bottom and normalizes to the crop.
        // Width is unchanged, so both the y coordinates and slope scale by
        // the crop's share of the full image height.
        let scale = stripHeight / CGFloat(imageHeight)
        let offset = CGFloat(imageHeight - rows.upperBound) / CGFloat(imageHeight)
        return TextFragment(
            text: fragment.text,
            box: CGRect(x: box.minX, y: offset + box.minY * scale, width: box.width, height: box.height * scale),
            rowSlope: fragment.rowSlope.map { $0 * scale }
        )
    }
}

/// Vision-backed OCR: accurate level, Polish first, then English. Nothing leaves
/// the device here; the image is dropped by the caller as soon as this returns.
struct VisionReceiptRecognizer: ReceiptTextRecognizing {
    static let preferredLanguages = ["pl-PL", "en-US"]
    private static let renderContext = CIContext()

    private enum ReadingError: Error { case imagePreparationFailed }

    func recognize(_ image: CGImage) async throws -> [TextFragment] {
        try await recognize(image, using: Self.read)
    }

    func recognize(
        _ image: CGImage, using read: @Sendable (CGImage) async throws -> [TextFragment]
    ) async throws -> [TextFragment] {
        let strips = ReceiptOCRStrip.plan(width: image.width, height: image.height)
        let primary = try await Self.readPass(image, strips: strips, using: read, resampling: false)
        // Assess the complete receipt in each pass: its item rows and printed
        // total can be on different strips. Only the retry resamples each crop.
        let assessment = ReceiptOCRAssessment(lines: ReceiptLineOrdering.lines(from: primary))
        try Task.checkCancellation()
        guard assessment.needsRetry else { return primary }

        do {
            let alternate = try await Self.readPass(image, strips: strips, using: read, resampling: true)
            let alternateAssessment = ReceiptOCRAssessment(lines: ReceiptLineOrdering.lines(from: alternate))
            try Task.checkCancellation()
            return alternateAssessment.improves(on: assessment) ? alternate : primary
        } catch let error as CancellationError {
            throw error
        } catch {
            try Task.checkCancellation()
            return primary
        }
    }

    private static func readPass(
        _ image: CGImage, strips: [ReceiptOCRStrip],
        using read: @Sendable (CGImage) async throws -> [TextFragment], resampling: Bool
    ) async throws -> [TextFragment] {
        func readImage(_ image: CGImage) async throws -> [TextFragment] {
            let input: CGImage
            if resampling {
                guard let resized = resampled(image) else { throw ReadingError.imagePreparationFailed }
                input = resized
            } else {
                input = image
            }
            try Task.checkCancellation()
            let fragments = try await read(input)
            try Task.checkCancellation()
            return fragments
        }

        try Task.checkCancellation()
        guard !strips.isEmpty else { return try await readImage(image) }
        var merged: [TextFragment] = []
        for strip in strips {
            try Task.checkCancellation()
            let rect = CGRect(x: 0, y: strip.rows.lowerBound, width: image.width, height: strip.rows.count)
            guard let crop = image.cropping(to: rect) else { throw ReadingError.imagePreparationFailed }
            let fragments = try await readImage(crop)
            merged.append(contentsOf: fragments.compactMap { strip.map($0, toImageHeight: image.height) })
        }
        return merged
    }

    private static func resampled(_ image: CGImage) -> CGImage? {
        // Different sampling can recover a digit or fragment from the same
        // photograph. Preserve the input bounds and cap large inputs.
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
