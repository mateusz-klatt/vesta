import CoreGraphics
import Foundation
import Vision

enum ReceiptPhotoRecognition {
    enum OverlapReview: Equatable, Sendable {
        case textAlignment
        case uncertain
    }

    struct Result {
        let text: String
        let overlapReview: OverlapReview?
    }

    typealias Translation = @Sendable (CGImage, CGImage) -> CGAffineTransform?

    static func read(
        pageCount: Int, loadPage: @MainActor (Int) async throws -> CGImage,
        recognizer: any ReceiptTextRecognizing, translate: Translation = visionTranslation
    ) async throws -> Result {
        guard pageCount > 0 else { return Result(text: "", overlapReview: nil) }
        var previous = try await readPage(0, loadPage: loadPage, recognizer: recognizer, register: pageCount > 1)
        var pending = Array(previous.lines.indices)
        var completed: [String] = []
        var consumedPrefixBottom: CGFloat?
        var review: OverlapReview?

        for index in 1..<pageCount {
            let current = try await readPage(index, loadPage: loadPage, recognizer: recognizer, register: true)
            try Task.checkCancellation()
            if let registration = Registration.between(previous, and: current, translate: translate),
               let seam = registration.stitch(
                   upper: previous.lines, pendingUpper: pending, lower: current.lines,
                   consumedPrefixBottom: consumedPrefixBottom
               ) {
                completed += seam.completed
                pending = seam.pending
                consumedPrefixBottom = seam.consumedPrefixBottom
                if seam.keptUnmatchedRows { review = .uncertain }
            } else {
                // An earlier seam may have published part of the previous photo.
                // Match the actual neighboring photos so that prefix still counts.
                let overlap = alignedOverlap(upper: previous.lines, lower: current.lines)
                if overlap == 0 {
                    review = .uncertain
                } else if review == nil {
                    review = .textAlignment
                }
                completed += pending.map { previous.lines[$0].text }
                pending = Array(current.lines.indices.dropFirst(overlap))
                consumedPrefixBottom = current.lines.prefix(overlap).map(\.box.midY).min()
            }
            previous = current
        }

        try Task.checkCancellation()
        return Result(text: (completed + pending.map { previous.lines[$0].text }).joined(separator: "\n"),
                      overlapReview: review)
    }

    private struct Page {
        let lines: [TextFragment]
        let fragments: [TextFragment]
        let preview: Preview?
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
        // Only compact, independent grayscale previews outlive a full photo.
        let preview = register ? autoreleasepool { Preview(image) } : nil
        return Page(lines: lines, fragments: fragments, preview: preview)
    }

    private struct Preview {
        let image: CGImage
        let sourceSize: CGSize

        init?(_ image: CGImage) {
            let size = CGSize(width: image.width, height: image.height)
            let scaled = Self.scaled(size, by: Self.scale(for: size))
            guard let rendered = Self.render(image, content: scaled, canvas: scaled) else { return nil }
            self.image = rendered
            sourceSize = size
        }

        struct Grid {
            let upper: CGImage
            let lower: CGImage
            let upperContent: CGSize
            let lowerContent: CGSize
        }

        static func commonGrid(_ upper: Self, _ lower: Self) -> Grid? {
            let scale = min(scale(for: upper.sourceSize), scale(for: lower.sourceSize))
            let upperSize = scaled(upper.sourceSize, by: scale)
            let lowerSize = scaled(lower.sourceSize, by: scale)
            let canvas = CGSize(width: max(upperSize.width, lowerSize.width), height: max(upperSize.height, lowerSize.height))
            guard let first = upper.placed(content: upperSize, canvas: canvas),
                  let second = lower.placed(content: lowerSize, canvas: canvas) else { return nil }
            return Grid(upper: first, lower: second, upperContent: upperSize, lowerContent: lowerSize)
        }

        private static func scale(for size: CGSize) -> CGFloat {
            min(1, 640 / size.width, 1_600 / size.height)
        }

        private static func scaled(_ size: CGSize, by scale: CGFloat) -> CGSize {
            CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        }

        private func placed(content: CGSize, canvas: CGSize) -> CGImage? {
            if content == canvas, image.width == Int(canvas.width), image.height == Int(canvas.height) { return image }
            return Self.render(image, content: content, canvas: canvas)
        }

        private static func render(_ image: CGImage, content: CGSize, canvas: CGSize) -> CGImage? {
            guard let context = CGContext(
                data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(origin: .zero, size: canvas))
            context.interpolationQuality = .high
            // Shared top-left origin keeps Vision's shift tied to the photo
            // tops, even when one image is padded more than the other.
            context.draw(image, in: CGRect(x: 0, y: canvas.height - content.height,
                                           width: content.width, height: content.height))
            return context.makeImage()
        }
    }

    private static func visionTranslation(upper: CGImage, lower: CGImage) -> CGAffineTransform? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: lower, options: [:])
        let handler = VNImageRequestHandler(cgImage: upper)
        do {
            try handler.perform([request])
            return request.results?.first?.alignmentTransform
        } catch {
            return nil
        }
    }

    private struct Registration {
        // The same center expressed in two normalized frames can differ by
        // rounding. Keep ties in photo order.
        private static let coordinatePrecision: CGFloat = 1e-12

        let transform: CGAffineTransform
        private let visible: CGRect

        private init(transform: CGAffineTransform) {
            self.transform = transform
            let page = CGRect(x: 0, y: 0, width: 1, height: 1)
            visible = page.intersection(page.applying(transform))
        }

        static func between(_ upper: Page, and lower: Page, translate: Translation) -> Self? {
            autoreleasepool {
                guard let first = upper.preview, let second = lower.preview,
                      upper.lines.count >= 3, lower.lines.count >= 3,
                      let grid = Preview.commonGrid(first, second),
                      let shift = translate(grid.upper, grid.lower),
                      shift.tx.isFinite, shift.ty.isFinite else { return nil }
                let width = grid.upperContent.width, height = grid.upperContent.height
                let lowerWidth = grid.lowerContent.width, lowerHeight = grid.lowerContent.height
                let downward = -shift.ty
                guard downward > 0, downward + lowerHeight > height,
                      abs(shift.tx) <= 0.15 * min(width, lowerWidth) else { return nil }

                // Use content sizes rather than the padded canvas when mapping
                // lower-photo boxes from their normalized bottom-left origin.
                let transform = CGAffineTransform(a: lowerWidth / width, b: 0, c: 0, d: lowerHeight / height,
                                                  tx: shift.tx / width, ty: (height - downward - lowerHeight) / height)
                let registration = Self(transform: transform)
                let overlap = registration.visible.height
                guard (0.1...0.6).contains(overlap), (0.1...0.6).contains(overlap / transform.d),
                      let rows = registration.agreement(upper.lines, lower.lines), rows.supportsRegistration,
                      let fragments = registration.agreement(upper.fragments, lower.fragments), fragments.supportsRegistration,
                      !registration.hasSimilarNeighbor(upper: upper.lines, lower: lower.lines, score: rows.score)
                else { return nil }
                return registration
            }
        }

        private struct Agreement {
            let score: CGFloat
            let matches: Int
            let sampleCount: Int
            let relativeHeight: CGFloat

            var supportsRegistration: Bool {
                matches >= 3 && matches * 10 >= sampleCount * 7 && relativeHeight >= 0.85
            }
        }

        private func agreement(_ upper: [TextFragment], _ lower: [TextFragment]) -> Agreement? {
            guard !visible.isEmpty else { return nil }
            // Clipped crop-edge observations are less reliable for confidence.
            let upperBoxes = upper.map(\.box).filter(visible.contains)
            let lowerBoxes = lower.map { $0.box.applying(transform) }.filter(visible.contains)
            let sampleCount = max(upperBoxes.count, lowerBoxes.count)
            let matches = upperBoxes.enumerated().flatMap { first, upperBox in
                lowerBoxes.enumerated().compactMap { second, lowerBox in
                    ReceiptOCRStrip.overlapScore(upperBox, lowerBox).map { (first, second, $0) }
                }
            }.sorted { $0.2 > $1.2 }

            var usedUpper: Set<Int> = []
            var usedLower: Set<Int> = []
            var relativeHeights: [CGFloat] = []
            var score: CGFloat = 0
            for (first, second, confidence) in matches where !usedUpper.contains(first) && !usedLower.contains(second) {
                usedUpper.insert(first)
                usedLower.insert(second)
                score += confidence
                let a = upperBoxes[first].height, b = lowerBoxes[second].height
                relativeHeights.append(min(a, b) / max(a, b))
            }
            guard let relativeHeight = ReceiptPhotoRecognition.median(relativeHeights) else { return nil }
            return Agreement(score: score / CGFloat(sampleCount), matches: usedUpper.count,
                             sampleCount: sampleCount, relativeHeight: relativeHeight)
        }

        private func hasSimilarNeighbor(upper: [TextFragment], lower: [TextFragment], score: CGFloat) -> Bool {
            guard let pitch = ReceiptPhotoRecognition.rowPitch(upper) else { return true }
            for step in [-3, -2, -1, 1, 2, 3] {
                var neighbor = transform
                neighbor.ty += CGFloat(step) * pitch
                // Only the requested translation must satisfy overlap bounds.
                // A similar out-of-range offset can still explain the geometry.
                let alternate = Self(transform: neighbor)
                if let agreement = alternate.agreement(upper, lower), agreement.matches >= 2,
                   agreement.score >= score - 0.04 {
                    return true
                }
            }
            return false
        }

        struct Seam {
            let completed: [String]
            let pending: [Int]
            let consumedPrefixBottom: CGFloat?
            let keptUnmatchedRows: Bool
        }

        func stitch(
            upper: [TextFragment], pendingUpper: [Int], lower: [TextFragment], consumedPrefixBottom: CGFloat?
        ) -> Seam? {
            let mapped = lower.map { $0.box.applying(transform) }
            let upperText = upper.map(NormalizedLine.init)
            let lowerText = lower.map(NormalizedLine.init)
            let upperInOverlap = upper.indices.filter { intersectsVerticalBand(upper[$0].box) }
            let lowerInOverlap = lower.indices.filter { intersectsVerticalBand(mapped[$0]) }
            // A row is a duplicate only when its text and box both match and
            // there is no ambiguous match on either side.
            let candidates = upperInOverlap.map { first in
                (first, lowerInOverlap.filter { second in
                    upperText[first] == lowerText[second] && Self.rowsOverlap(upper[first].box, mapped[second])
                })
            }
            var lowerCandidateCounts: [Int: Int] = [:]
            for (_, matches) in candidates {
                for match in matches { lowerCandidateCounts[match, default: 0] += 1 }
            }
            let matches: [(Int, Int)] = candidates.compactMap { first, matches in
                guard matches.count == 1, let second = matches.first, lowerCandidateCounts[second] == 1 else { return nil }
                return (first, second)
            }
            let matchedUpper = Set(matches.map(\.0)), matchedLower = Set(matches.map(\.1))
            let available = Set(pendingUpper)
            let unmatchedUpper = upperInOverlap.contains { !matchedUpper.contains($0) }
            let unmatchedLower = lowerInOverlap.filter { !matchedLower.contains($0) }
            if let consumedPrefixBottom,
               unmatchedLower.contains(where: { mapped[$0].midY - consumedPrefixBottom > Self.coordinatePrecision }) {
                // The previous seam already emitted this portion of the page.
                // Falling back keeps the new row without inserting it out of order.
                return nil
            }

            var keptUpper = available
            var keptLower = Set(lower.indices)
            for (first, second) in matches {
                if available.contains(first), upper[first].box.midY < visible.midY {
                    keptUpper.remove(first)
                } else {
                    keptLower.remove(second)
                }
            }

            // Merge only the interleaved rows, preserving each photo's local
            // reading order. The un-emitted suffix stays in the lower frame.
            var remainingUpper = pendingUpper.filter(keptUpper.contains)[...]
            var remainingLower = lower.indices.filter(keptLower.contains)[...]
            var completed: [String] = []
            while let first = remainingUpper.first, let second = remainingLower.first {
                if mapped[second].midY - upper[first].box.midY <= Self.coordinatePrecision {
                    completed.append(upper[first].text)
                    remainingUpper = remainingUpper.dropFirst()
                } else {
                    completed.append(lower[second].text)
                    remainingLower = remainingLower.dropFirst()
                }
            }
            completed += remainingUpper.map { upper[$0].text }
            let stillPending = Set(remainingLower)
            let settledBottom = lower.indices.filter { !stillPending.contains($0) }.map { lower[$0].box.midY }.min()
            return Seam(completed: completed, pending: Array(remainingLower), consumedPrefixBottom: settledBottom,
                        keptUnmatchedRows: unmatchedUpper || !unmatchedLower.isEmpty)
        }

        private func intersectsVerticalBand(_ box: CGRect) -> Bool {
            box.minY < visible.maxY && box.maxY > visible.minY
        }

        private static func rowsOverlap(_ first: CGRect, _ second: CGRect) -> Bool {
            let shared = first.intersection(second)
            // A combined name/price box can cover a narrower label anchor.
            return !shared.isEmpty && shared.width >= 0.6 * min(first.width, second.width)
                && shared.height >= 0.55 * max(first.height, second.height)
        }
    }

    static func rowPitch(_ lines: [TextFragment]) -> CGFloat? {
        let boxes = lines.map(\.box).filter { $0.height > 0 }
        guard let lineHeight = median(boxes.map(\.height)) else { return nil }
        // OCR boxes from neighboring rows can overlap slightly on a curved receipt.
        let minimumGap = lineHeight * 0.9
        let centers = boxes.map(\.midY).sorted(by: >)
        var last: CGFloat?
        var gaps: [CGFloat] = []
        for center in centers {
            if let last {
                let gap = last - center
                guard gap >= minimumGap else { continue }
                gaps.append(gap)
            }
            last = center
        }
        return median(gaps)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        let sorted = values.sorted()
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }

    private struct NormalizedLine: Hashable {
        let text: String
        let amount: String?

        init(_ line: TextFragment) {
            let normalized = line.text.uppercased().replacingOccurrences(of: "−", with: "-")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let priceTail = #/(?:^|\s)([+-]?[0-9]{1,9}[.,][0-9]{2})(?:\s*PLN)?(?:\s*[A-G])?$/#
            if let price = normalized.firstMatch(of: priceTail) {
                let canonical = price.1.replacingOccurrences(of: ",", with: ".")
                amount = canonical
                text = normalized.replacingCharacters(in: price.1.startIndex..<price.1.endIndex, with: canonical)
            } else {
                amount = nil
                text = normalized
            }
        }
    }

    private static func alignedOverlap(upper: [TextFragment], lower: [TextFragment]) -> Int {
        let maximum = min(upper.count, lower.count)
        guard maximum >= 3 else { return 0 }
        let first = upper.map(NormalizedLine.init)
        let second = lower.map(NormalizedLine.init)
        var overlap = 0
        for count in stride(from: maximum, through: 3, by: -1) {
            let run = second.prefix(count)
            guard first.suffix(count).elementsEqual(run), run.allSatisfy({ $0.amount != nil }) else { continue }
            guard overlap == 0, Set(run).count == count else { return 0 }
            let repeatsInUpper = (0..<(first.count - count)).contains { first[$0..<($0 + count)].elementsEqual(run) }
            let repeatsInLower = (1..<(second.count - count + 1)).contains { second[$0..<($0 + count)].elementsEqual(run) }
            guard !repeatsInUpper, !repeatsInLower else { return 0 }
            overlap = count
        }
        return overlap
    }
}
