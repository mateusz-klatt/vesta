import CoreGraphics
import Foundation
import Vision

enum ReceiptPhotoRecognition {
    struct Result {
        let text: String
        let needsOverlapReview: Bool
    }

    static func read(
        pageCount: Int, loadPage: @MainActor (Int) async throws -> CGImage,
        recognizer: any ReceiptTextRecognizing
    ) async throws -> Result {
        guard pageCount > 0 else { return Result(text: "", needsOverlapReview: false) }
        var previous = try await readPage(0, loadPage: loadPage, recognizer: recognizer, register: pageCount > 1)
        var pending = previous.lines
        var completed: [String] = []
        var consumedPrefixBottom: CGFloat?
        var needsOverlapReview = false

        for index in 1..<pageCount {
            let current = try await readPage(index, loadPage: loadPage, recognizer: recognizer, register: true)
            try Task.checkCancellation()
            if let registration = Registration.between(previous, and: current),
               registration.overlap / 2 < (consumedPrefixBottom ?? 1) {
                let seam = registration.stitch(upper: pending, lower: current.lines, upperReadings: previous.lines)
                completed += seam.completed.map(\.text)
                pending = seam.pending
                consumedPrefixBottom = nil
            } else {
                // Compare the actual neighboring photos. An earlier seam may
                // already have emitted some of the prior photo's lines.
                let overlap = alignedOverlap(upper: previous.lines, lower: current.lines)
                needsOverlapReview = needsOverlapReview || overlap == 0
                completed += pending.map(\.text)
                pending = Array(current.lines.dropFirst(overlap))
                consumedPrefixBottom = current.lines.prefix(overlap).last?.box.minY
            }
            previous = current
        }

        try Task.checkCancellation()
        return Result(text: (completed + pending.map(\.text)).joined(separator: "\n"),
                      needsOverlapReview: needsOverlapReview)
    }

    private struct Page {
        let lines: [TextFragment]
        let fragments: [TextFragment]
        let preview: CGImage?
    }

    private static func readPage(
        _ index: Int, loadPage: @MainActor (Int) async throws -> CGImage,
        recognizer: any ReceiptTextRecognizing, register: Bool
    ) async throws -> Page {
        try Task.checkCancellation()
        let image = try await loadPage(index)
        try Task.checkCancellation()
        let fragments = try await recognizer.recognize(image)
        try Task.checkCancellation()
        let lines = ReceiptLineOrdering.positionedLines(
            from: fragments, imageAspectRatio: CGFloat(image.height) / CGFloat(image.width)
        )
        // The full-resolution image stays in this call. At most two independent,
        // grayscale registration previews survive while a seam is evaluated.
        let preview = register ? autoreleasepool { registrationPreview(image) } : nil
        return Page(lines: lines, fragments: fragments, preview: preview)
    }

    private static func registrationPreview(_ image: CGImage) -> CGImage? {
        let scale = min(1, 640 / CGFloat(image.width), 1_600 / CGFloat(image.height))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        return context.makeImage()
    }

    private struct Registration {
        let transform: CGAffineTransform
        let overlap: CGFloat

        static func between(_ upper: Page, and lower: Page) -> Self? {
            guard let first = upper.preview, let second = lower.preview,
                  upper.lines.count >= 3, lower.lines.count >= 3,
                  let shift = translation(upper: first, lower: second) else { return nil }
            let width = CGFloat(first.width), height = CGFloat(first.height)
            let scaleX = CGFloat(second.width) / width, scaleY = CGFloat(second.height) / height
            let overlap = 1 + shift.ty / height
            guard (0.1...0.6).contains(overlap), (0.1...0.6).contains(overlap / scaleY),
                  abs(shift.tx) <= 0.15 * min(width, CGFloat(second.width)) else { return nil }

            // Vision's pixel displacement measures the distance between the
            // image tops. Convert it to the upper photo's bottom-left frame.
            let transform = CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY,
                                              tx: shift.tx / width, ty: overlap - scaleY)
            let registration = Self(transform: transform, overlap: overlap)
            guard let rowAgreement = registration.agreement(upper.lines, lower.lines),
                  registration.agreement(upper.fragments, lower.fragments) != nil,
                  !registration.hasSimilarNeighbor(
                    upper: upper.lines, lower: lower.lines, score: rowAgreement
                  ) else { return nil }
            return registration
        }

        private static func translation(upper: CGImage, lower: CGImage) -> CGAffineTransform? {
            autoreleasepool {
                let request = VNTranslationalImageRegistrationRequest(targetedCGImage: lower, options: [:])
                let handler = VNImageRequestHandler(cgImage: upper)
                do {
                    try handler.perform([request])
                    return request.results?.first?.alignmentTransform
                } catch {
                    return nil
                }
            }
        }

        private func agreement(_ upper: [TextFragment], _ lower: [TextFragment]) -> CGFloat? {
            let visible = CGRect(x: 0, y: 0, width: 1, height: overlap)
                .intersection(CGRect(x: transform.tx, y: 0, width: transform.a, height: overlap))
            // At a crop edge one reading can be clipped. Use interior boxes to
            // judge whether this is the same printed region in both photos.
            let upperBoxes = upper.map(\.box).filter(visible.contains)
            let lowerBoxes = lower.map { $0.box.applying(transform) }.filter(visible.contains)
            let sampleCount = max(upperBoxes.count, lowerBoxes.count)
            guard min(upperBoxes.count, lowerBoxes.count) >= 3 else { return nil }
            let matches = upperBoxes.enumerated().flatMap { first, upperBox in
                lowerBoxes.enumerated().compactMap { second, lowerBox in
                    ReceiptOCRStrip.overlapScore(upperBox, lowerBox).map { (first, second, $0) }
                }
            }.sorted { $0.2 > $1.2 }

            var usedUpper: Set<Int> = []
            var usedLower: Set<Int> = []
            var score: CGFloat = 0
            for (first, second, confidence) in matches where !usedUpper.contains(first) && !usedLower.contains(second) {
                usedUpper.insert(first)
                usedLower.insert(second)
                score += confidence
            }
            guard usedUpper.count >= 3, usedUpper.count * 10 >= sampleCount * 7 else { return nil }
            return score / CGFloat(sampleCount)
        }

        private func hasSimilarNeighbor(upper: [TextFragment], lower: [TextFragment], score: CGFloat) -> Bool {
            // Vision can land a few rows away on a regular, repetitive pattern.
            // Refuse a result if a nearby row offset explains the boxes
            // nearly as well. Every candidate here uses geometry only.
            let centers = upper.map(\.box.midY).filter { $0 >= 0 && $0 <= overlap }.sorted()
            let pitches = zip(centers, centers.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
            guard !pitches.isEmpty else { return true }
            let pitch = pitches[pitches.count / 2]
            for step in [-3, -2, -1, 1, 2, 3] {
                let shift = CGFloat(step) * pitch
                var neighbor = transform
                neighbor.ty += shift
                let neighboringOverlap = overlap + shift
                guard (0.1...0.6).contains(neighboringOverlap),
                      (0.1...0.6).contains(neighboringOverlap / neighbor.d) else { continue }
                let alternate = Self(transform: neighbor, overlap: neighboringOverlap)
                if let alternateScore = alternate.agreement(upper, lower), alternateScore >= score - 0.04 {
                    return true
                }
            }
            return false
        }

        func stitch(
            upper: [TextFragment], lower: [TextFragment], upperReadings: [TextFragment]
        ) -> (completed: [TextFragment], pending: [TextFragment]) {
            let mapped = lower.map { TextFragment(text: $0.text, box: $0.box.applying(transform)) }
            let heights = (upper + mapped).map(\.box.height).sorted()
            let halfOverlap = overlap / 2
            let ownership = ReceiptOCRStrip.resolveSeam(
                upper: upper, lower: mapped, cut: halfOverlap, halfOverlap: halfOverlap,
                halfLine: heights[heights.count / 2] / 2,
                upperOwnership: upper.map { $0.box.midY > halfOverlap },
                lowerOwnership: mapped.map { $0.box.midY <= halfOverlap },
                score: Self.rowOverlapScore
            )
            // Earlier seams may already have emitted the upper photo's prefix.
            // Those readings still show which lower-photo rows are duplicates.
            let upperBoxes = upperReadings.map(\.box)
            let ownedLower = zip(mapped, ownership.lower).compactMap { $1 ? $0.box : nil }
            let keptUpper = zip(upper, ownership.upper).compactMap { line, owns in
                owns || isUnilateral(line.box, comparedWith: ownedLower) ? line : nil
            }
            let keptLower = lower.indices.compactMap { index in
                ownership.lower[index] || isUnilateral(mapped[index].box, comparedWith: upperBoxes) ? lower[index] : nil
            }

            // Seam-band recovery can leave a lower-photo row above the final
            // kept upper-photo row. Merge only those interleaved rows; preserve
            // each photo's own curved-row ordering otherwise.
            var remainingUpper = keptUpper[...]
            var completed: [TextFragment] = []
            var remainingLower = keptLower[...]
            while let upperLine = remainingUpper.first, let lowerLine = remainingLower.first {
                if upperLine.box.midY > lowerLine.box.applying(transform).midY {
                    completed.append(upperLine)
                    remainingUpper = remainingUpper.dropFirst()
                } else {
                    completed.append(lowerLine)
                    remainingLower = remainingLower.dropFirst()
                }
            }
            completed += remainingUpper
            return (completed, Array(remainingLower))
        }

        private func isUnilateral(_ box: CGRect, comparedWith ownedBoxes: [CGRect]) -> Bool {
            // Inside the shared area each complete row has two opportunities
            // to be read. Preserve a usable row if its owning photo missed it.
            // Leave clipped rows at the crop edges to their assigned owner.
            box.minY > 0 && box.maxY < overlap && ownedBoxes.allSatisfy {
                Self.verticalCoverage(box, $0) < 0.55
            }
        }

        private static func rowOverlapScore(_ first: CGRect, _ second: CGRect) -> CGFloat? {
            // One photo can read the label and price in a single box while
            // the other splits them. The narrower left anchor can still
            // describe the same row when its horizontal span is shared.
            let shared = first.intersection(second)
            guard !shared.isEmpty else { return nil }
            let horizontal = shared.width / min(first.width, second.width)
            let vertical = verticalCoverage(first, second)
            guard horizontal >= 0.6, vertical >= 0.55 else { return nil }
            return horizontal * vertical
        }

        private static func verticalCoverage(_ first: CGRect, _ second: CGRect) -> CGFloat {
            let shared = min(first.maxY, second.maxY) - max(first.minY, second.minY)
            return shared / max(first.height, second.height)
        }
    }

    private struct PricedLine: Hashable {
        let text: String
        let amount: String

        init?(_ line: TextFragment) {
            let normalized = line.text.uppercased().replacingOccurrences(of: "−", with: "-")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let priceTail = #/(?:^|\s)([+-]?[0-9]{1,9}[.,][0-9]{2})(?:\s*PLN)?(?:\s*[A-G])?$/#
            guard let price = normalized.firstMatch(of: priceTail) else { return nil }
            let amount = price.1.replacingOccurrences(of: ",", with: ".")
            self.amount = amount
            text = normalized.replacingCharacters(in: price.1.startIndex..<price.1.endIndex, with: amount)
        }
    }

    private static func alignedOverlap(upper: [TextFragment], lower: [TextFragment]) -> Int {
        let maximum = min(upper.count, lower.count)
        guard maximum >= 3 else { return 0 }
        let upperTail = upper.suffix(maximum).map(PricedLine.init)
        let lowerHead = lower.prefix(maximum).map(PricedLine.init)
        var overlap = 0
        for count in stride(from: maximum, through: 3, by: -1) {
            let prefix = lowerHead.prefix(count)
            guard zip(upperTail.suffix(count), prefix).allSatisfy({ $0 != nil && $0 == $1 }) else { continue }
            // Repeated patterns can support two different seams. Keep both
            // readings when the longest run has no distinctive evidence.
            guard overlap == 0, Set(prefix).count >= 2 else { return 0 }
            overlap = count
        }
        return overlap
    }
}
