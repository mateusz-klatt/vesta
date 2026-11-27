import CoreGraphics

/// Horizontal crops described in source pixels, with y measured from the top.
struct ReceiptOCRStrip {
    private static let tilingAspectRatio: CGFloat = 3
    private static let maxStripAspectRatio: CGFloat = 0.75
    // Mapping equivalent positions from two crop coordinate systems can
    // introduce rounding error. Keep an exact cut owned by the lower strip.
    private static let coordinatePrecision: CGFloat = 1e-12

    let rows: Range<Int>
    let ownedRows: Range<CGFloat>

    static func plan(width: Int, height: Int) -> [Self] {
        // Ordinary photos use the whole-photo OCR path. Above 3:1, a strip
        // no taller than 3/4 of the width makes small print larger relative
        // to Vision's 1/32 minimum text height fraction at native resolution.
        guard width > 0, CGFloat(height) / CGFloat(width) > tilingAspectRatio else { return [] }
        let maxStripHeight = max(1, Int(CGFloat(width) * maxStripAspectRatio))
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

    static func orderingScale(forAspectRatio aspectRatio: CGFloat) -> CGFloat {
        aspectRatio > tilingAspectRatio ? maxStripAspectRatio / aspectRatio : 1
    }

    func map(_ fragment: TextFragment, toImageHeight imageHeight: Int) -> TextFragment {
        let box = fragment.box
        // Vision measures y from the bottom and normalizes to the crop.
        // Width is unchanged, so both the y coordinates and slope scale by
        // the crop's share of the full image height.
        let scale = CGFloat(rows.count) / CGFloat(imageHeight)
        let offset = CGFloat(imageHeight - rows.upperBound) / CGFloat(imageHeight)
        return TextFragment(
            text: fragment.text,
            box: CGRect(x: box.minX, y: offset + box.minY * scale, width: box.width, height: box.height * scale),
            rowSlope: fragment.rowSlope.map { $0 * scale }
        )
    }

    /// Resolves ownership of fragments whose boxes are already in full-image coordinates.
    static func merge(_ fragmentsByStrip: [[TextFragment]], strips: [Self], imageHeight: Int) -> [TextFragment] {
        let height = CGFloat(imageHeight)
        func normalizedY(at row: CGFloat) -> CGFloat { (height - row) / height }
        let heights = fragmentsByStrip.flatMap { $0.map(\.box.height) }.filter { $0 > 0 }.sorted()
        let halfLine = heights.isEmpty ? 0 : heights[heights.count / 2] / 2
        var keep = zip(strips, fragmentsByStrip).map { strip, fragments in
            let top = normalizedY(at: strip.ownedRows.lowerBound)
            let bottom = normalizedY(at: strip.ownedRows.upperBound)
            return fragments.map { $0.box.midY <= top + coordinatePrecision && $0.box.midY > bottom + coordinatePrecision }
        }

        for upper in strips.indices.dropLast() {
            let lower = upper + 1
            let cut = normalizedY(at: strips[upper].ownedRows.upperBound)
            let halfOverlap = CGFloat(strips[upper].rows.upperBound - strips[lower].rows.lowerBound) / (2 * height)
            let resolved = resolveSeam(
                upper: fragmentsByStrip[upper], lower: fragmentsByStrip[lower],
                cut: cut, halfOverlap: halfOverlap, halfLine: halfLine,
                upperOwnership: keep[upper], lowerOwnership: keep[lower]
            )
            keep[upper] = resolved.upper
            keep[lower] = resolved.lower
        }

        return zip(fragmentsByStrip, keep).flatMap { fragments, owned in
            zip(fragments, owned).compactMap { fragment, keep in keep ? fragment : nil }
        }
    }

    /// Resolves one cut in common coordinates. Each caller supplies ownership
    /// outside the seam band, which can also include a photo or strip's other cut.
    static func resolveSeam(
        upper: [TextFragment], lower: [TextFragment], cut: CGFloat, halfOverlap: CGFloat, halfLine: CGFloat,
        upperOwnership: [Bool], lowerOwnership: [Bool], score: (CGRect, CGRect) -> CGFloat? = overlapScore
    ) -> (upper: [Bool], lower: [Bool]) {
        let halfBand = min(halfLine, halfOverlap)
        guard halfBand > 0 else { return (upperOwnership, lowerOwnership) }
        let upperCandidates = candidates(in: upper, cut: cut, halfBand: halfBand, halfOverlap: halfOverlap)
        let lowerCandidates = candidates(in: lower, cut: cut, halfBand: halfBand, halfOverlap: halfOverlap)
        let nearCut = halfBand + coordinatePrecision
        var keepUpper = upperOwnership
        var keepLower = lowerOwnership

        // Near the cut, a single observation is useful even if its centre
        // is on the neighbouring side. Suppress only matched observations.
        for candidate in upperCandidates where candidate.distance <= nearCut { keepUpper[candidate.index] = true }
        for candidate in lowerCandidates where candidate.distance <= nearCut { keepLower[candidate.index] = true }
        let matches = upperCandidates.flatMap { first in
            lowerCandidates.compactMap { second -> SeamMatch? in
                guard min(first.distance, second.distance) <= nearCut,
                      let overlap = score(upper[first.index].box, lower[second.index].box) else { return nil }
                return SeamMatch(upper: first.index, lower: second.index, score: overlap)
            }
        }.sorted { $0.score > $1.score }

        var matchedUpper: Set<Int> = []
        var matchedLower: Set<Int> = []
        for match in matches where !matchedUpper.contains(match.upper) && !matchedLower.contains(match.lower) {
            matchedUpper.insert(match.upper)
            matchedLower.insert(match.lower)
            let upperY = upper[match.upper].box.midY
            let lowerY = lower[match.lower].box.midY
            let difference = abs(upperY - cut) - abs(lowerY - cut)
            // If the distances tie, both centres above the cut favour the
            // upper image. The lower image breaks all remaining ties.
            let preferUpper = difference > coordinatePrecision
                || (abs(difference) <= coordinatePrecision && min(upperY, lowerY) > cut + coordinatePrecision)
            keepUpper[match.upper] = preferUpper
            keepLower[match.lower] = !preferUpper
        }
        return (keepUpper, keepLower)
    }

    private struct SeamMatch {
        let upper: Int
        let lower: Int
        let score: CGFloat
    }

    private static func candidates(
        in fragments: [TextFragment], cut: CGFloat, halfBand: CGFloat, halfOverlap: CGFloat
    ) -> [(index: Int, distance: CGFloat)] {
        fragments.indices.compactMap { index in
            let box = fragments[index].box
            let distance = abs(box.midY - cut)
            // A box from just outside the band can still match a reading
            // whose centre moved inside it on the neighbouring strip.
            let reach = min(halfOverlap, halfBand + box.height / 2)
            return distance <= reach + coordinatePrecision ? (index, distance) : nil
        }
    }

    static func overlapScore(_ upper: CGRect, _ lower: CGRect) -> CGFloat? {
        let shared = upper.intersection(lower)
        guard !shared.isEmpty else { return nil }
        let horizontal = shared.width / max(upper.width, lower.width)
        let vertical = shared.height / max(upper.height, lower.height)
        guard horizontal >= 0.6, vertical >= 0.55 else { return nil }
        return horizontal * vertical
    }
}
