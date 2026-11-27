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

    static func lines(from fragments: [TextFragment], imageAspectRatio: CGFloat = 1) -> [String] {
        positionedLines(from: fragments, imageAspectRatio: imageAspectRatio).map(\.text)
    }

    /// The line's leftmost box anchors its row at a photo seam. A price on a
    /// curved receipt can sit a row lower, so the union of the boxes is not a
    /// reliable estimate of the printed row's height.
    static func positionedLines(from fragments: [TextFragment], imageAspectRatio: CGFloat) -> [TextFragment] {
        let usable = fragments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else { return [] }
        let heights = usable.map(\.box.height).sorted()
        let verticalScale = ReceiptOCRStrip.orderingScale(forAspectRatio: imageAspectRatio)
        let tolerance = max(heights[heights.count / 2] * bandTolerance, 0.002 * verticalScale)
        let text = usable.map { $0.text.trimmingCharacters(in: .whitespaces) }
        let centers = alignRows(usable, verticalScale: verticalScale)
        let discountOrdering = discountRows(in: usable, text: text, centers: centers, tolerance: tolerance)
        // A column fit cannot override an ambiguity found by the discount repair.
        let rows = discountOrdering.hasRefusedRepair ? discountOrdering.rows : curvedRows(
            in: usable, text: text, bands: discountOrdering.rows, tolerance: tolerance, verticalScale: verticalScale
        )
        return rows.map { row in
            let ordered = row.sorted { usable[$0].box.minX < usable[$1].box.minX }
            return TextFragment(text: ordered.map { text[$0] }.joined(separator: " "), box: usable[ordered[0]].box)
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

    private static func isSignedPrice(_ text: String) -> Bool {
        text.wholeMatch(of: #/^[-−][0-9]{1,9}[.,][0-9]{2}(?:\s*PLN)?(?:\s*[A-G])?$/#.ignoresCase()) != nil
    }

    private static func hasAmountTail(_ text: String) -> Bool {
        text.firstMatch(of: #/(?:^|\s)[+−-]?[0-9]{1,9}[.,][0-9]{2}(?:\s*PLN)?(?:\s*[A-G])?$/#.ignoresCase()) != nil
    }

    private static func isBareDiscountLabel(_ text: String) -> Bool {
        text.firstMatch(of: #/^(?:OPUST|RABAT)\b/#.ignoresCase()) != nil && !hasAmountTail(text)
    }

    private static func discountRows(
        in fragments: [TextFragment], text: [String], centers: [CGFloat], tolerance: CGFloat
    ) -> (rows: [[Int]], hasRefusedRepair: Bool) {
        var positions = centers
        let originalRows = bands(at: positions, tolerance: tolerance)
        var rows = originalRows
        var hasRefusedRepair = false
        let signedPrices = text.indices.filter { isSignedPrice(text[$0]) }
        guard !signedPrices.isEmpty else { return (rows, false) }
        let singletonRows = Set(originalRows.filter { $0.count == 1 }.map { $0[0] })

        let discountPrefix = #/^(?:OPUST|RABAT)\b/#.ignoresCase()
        let calculation = #/^(?:[0-9]{1,6}(?:[.,][0-9]{1,4})?|I(?=\s*SZT\b))\s*(?:L|SZT|KG|G|M)?\s*[*×X=]\s*[0-9]{1,9}[.,][0-9]{2}\s+[0-9]{1,9}[.,][0-9]{2}(?:\s*PLN)?(?:\s*[A-G])?$/#.ignoresCase()
        let boxes = fragments.map(\.box)
        let discountLabels = text.indices.filter { isBareDiscountLabel(text[$0]) }
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
            let signedInColumn = signedPrices.filter { candidate in
                rawAligned(label, with: candidate)
                    && abs(boxes[candidate].maxX - boxes[item].maxX) <= priceColumnTolerance
            }
            // A conflict needs raw geometric support. An already grouped signed
            // amount still counts as evidence but cannot be moved by this repair.
            guard !signedInColumn.isEmpty else { continue }
            if signedInColumn.count > 1 { hasRefusedRepair = true }
            let signed = signedInColumn.filter { singletonRows.contains($0) }
            guard signed.count == 1, let discount = signed.first,
                  !discountLabels.contains(where: { $0 != label && rawAligned($0, with: discount) }),
                  rows.contains([discount]) else {
                hasRefusedRepair = true
                continue
            }

            // The adjusted centers disagree with the raw boxes here. Use the
            // measured offsets from the label for this pair only.
            var proposed = positions
            for index in [item, discount] {
                proposed[index] = positions[label] + (boxes[index].midY - boxes[label].midY)
            }
            let columnAmounts = boxes.indices.filter {
                abs(boxes[$0].maxX - boxes[item].maxX) <= priceColumnTolerance
                    && hasAmountTail(text[$0])
            }
            guard columnAmounts.sorted(by: { positions[$0] > positions[$1] }) ==
                    columnAmounts.sorted(by: { proposed[$0] > proposed[$1] }) else {
                hasRefusedRepair = true
                continue
            }

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
                              && !hasAmountTail(text[$0])
                              && text[$0].firstMatch(of: discountPrefix) == nil
                      )
                  }),
                  otherRows(rows) == otherRows(candidate) else {
                hasRefusedRepair = true
                continue
            }
            positions = proposed
            rows = candidate
        }
        return (rows, hasRefusedRepair)
    }

    /// The two columns can drift apart by a full line on a crumpled receipt.
    /// Fit the slope between observations, then test each pair against a local
    /// baseline inferred from its neighbors. Keep the preceding band and
    /// discount repairs when the columns do not support a unique assignment.
    private static func curvedRows(
        in fragments: [TextFragment], text: [String], bands: [[Int]], tolerance: CGFloat, verticalScale: CGFloat
    ) -> [[Int]] {
        let rightAmount = #/^(?=[+−-]?[0-9]|I(?=\s*SZT\b)).*[0-9][.,][0-9]{2}(?:\s*PLN)?(?:\s*[A-G])?$/#.ignoresCase()
        let discountLabel = #/^(?:SUMA\s+)?(?:OPUST|RABAT)/#.ignoresCase()
        let boxes = fragments.map(\.box)
        let ordered = boxes.indices.sorted { boxes[$0].midY > boxes[$1].midY }
        let amounts = ordered.filter { boxes[$0].minX >= 0.45 && text[$0].wholeMatch(of: rightAmount) != nil }
        // Smaller sets do not constrain a fit well enough to revise a band.
        guard amounts.count >= 4 else { return bands }
        let labels = ordered.filter { boxes[$0].minX < 0.45 && text[$0].contains(where: \.isLetter) }
        guard labels.count >= amounts.count else { return bands }

        let amountSet = Set(amounts)
        let labelSet = Set(labels)
        let hasDetachedAmount = bands.contains { row in
            let prices = row.filter { amountSet.contains($0) }
            guard !prices.isEmpty else { return false }
            let names = row.filter { labelSet.contains($0) }
            guard prices.count == 1, names.count == 1 else { return true }
            return abs(boxes[prices[0]].midY - boxes[names[0]].midY) > tolerance
        }
        guard hasDetachedAmount else { return bands }

        let isDiscount = Set(labels.filter { text[$0].firstMatch(of: discountLabel) != nil })
        let candidates = amounts.map { amount in
            let negative = text[amount].first == "-" || text[amount].first == "−"
            return labels.indices.filter { index in
                let label = labels[index]
                let run = boxes[amount].midX - boxes[label].midX
                let rise = boxes[amount].midY - boxes[label].midY
                return boxes[label].maxX <= boxes[amount].minX && abs(rise) <= 0.14 * verticalScale * run
                    && (negative || !isDiscount.contains(label))
            }
        }
        func error(_ amountIndex: Int, _ labelIndex: Int, slope: CGFloat) -> CGFloat {
            let label = boxes[labels[labelIndex]]
            let amount = boxes[amounts[amountIndex]]
            return abs(amount.midY - label.midY - slope * (amount.midX - label.midX))
        }

        func bestLabel(for amountIndex: Int, slope: CGFloat) -> Int? {
            candidates[amountIndex].min { error(amountIndex, $0, slope: slope) < error(amountIndex, $1, slope: slope) }
        }

        // Try different starting tilts to find the column correspondences.
        // A fit is one-to-one and monotone, so a price cannot move past its
        // neighbor or join another purchase sharing the same printed text.
        let assignments = Set((-12...12).compactMap { step -> [Int]? in
            let slope = CGFloat(step) * 0.01 * verticalScale
            let matches = amounts.indices.compactMap { bestLabel(for: $0, slope: slope) }
            guard matches.count == amounts.count,
                  zip(matches, matches.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
            return matches
        })

        typealias Fit = (
            matches: [Int], localSlopes: [CGFloat], residuals: [CGFloat], meanResidual: CGFloat, medianSlope: CGFloat
        )
        func score(_ matches: [Int], for amountIndices: [Int]) -> Fit? {
            guard matches.count >= 3 else { return nil }
            let ys = matches.map { boxes[labels[$0]].midY }
            let observedSlopes = zip(matches, amountIndices).compactMap { labelIndex, amountIndex -> CGFloat? in
                let label = boxes[labels[labelIndex]]
                let amount = boxes[amounts[amountIndex]]
                let run = amount.midX - label.midX
                guard run > 0 else { return nil }
                return (amount.midY - label.midY) / run
            }
            guard observedSlopes.count == matches.count else { return nil }

            var localSlopes: [CGFloat] = []
            var residuals: [CGFloat] = []
            for index in matches.indices {
                // Interpolate using the two adjacent rows, or extrapolate
                // from the two closest rows at either end of the column.
                let (first, second) = switch index {
                case 0: (1, 2)
                case ys.count - 1: (index - 2, index - 1)
                default: (index - 1, index + 1)
                }
                let span = ys[second] - ys[first]
                guard span != 0 else { return nil }
                let slope = observedSlopes[first]
                    + (observedSlopes[second] - observedSlopes[first]) * (ys[index] - ys[first]) / span
                localSlopes.append(slope)
                residuals.append(error(amountIndices[index], matches[index], slope: slope))
            }
            return (matches, localSlopes, residuals, residuals.reduce(0, +) / CGFloat(matches.count),
                    observedSlopes.sorted()[observedSlopes.count / 2])
        }

        // Rank alternatives before checking whether any is safe to apply. A
        // fit with one bad row can still challenge a deceptively smooth shift.
        let allAmounts = Array(amounts.indices)
        let fits = assignments.compactMap { score($0, for: allAmounts) }.sorted { $0.meanResidual < $1.meanResidual }
        let margin = tolerance * 0.25
        guard let best = fits.first, abs(best.medianSlope) >= 0.01 * verticalScale,
              allAmounts.allSatisfy({
                  best.residuals[$0] <= tolerance
                      && bestLabel(for: $0, slope: best.localSlopes[$0]) == best.matches[$0]
              }),
              fits.dropFirst().first.map({ $0.meanResidual - best.meanResidual > margin }) ?? true else { return bands }

        // A one-row shift may never be the nearest match at any of the seed
        // tilts. Fit each shift independently over the same rows it shares
        // with the winner, dropping only an unavailable name at a page edge.
        for offset in [-1, 1] {
            let shared = allAmounts.filter { labels.indices.contains(best.matches[$0] + offset) }
            let referenceMatches = shared.map { best.matches[$0] }
            guard let reference = score(referenceMatches, for: shared),
                  let shifted = score(referenceMatches.map { $0 + offset }, for: shared),
                  shifted.meanResidual - reference.meanResidual > margin else { return bands }
        }

        let labelIndexByFragment = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($0.element, $0.offset) })
        let amountIndexByFragment = Dictionary(uniqueKeysWithValues: amounts.enumerated().map { ($0.element, $0.offset) })
        for row in bands {
            let originalLabels = row.compactMap { labelIndexByFragment[$0] }
            guard originalLabels.count == 1, let label = originalLabels.first else { continue }
            // Moving an already banded amount also needs clear local evidence.
            for amount in row.compactMap({ amountIndexByFragment[$0] }) where best.matches[amount] != label {
                let previousResidual = error(amount, label, slope: best.localSlopes[amount])
                guard previousResidual - best.residuals[amount] > margin else { return bands }
            }
        }

        let signedAmounts = allAmounts.filter { isSignedPrice(text[amounts[$0]]) }
        let discountLabels = labels.indices.filter { isBareDiscountLabel(text[labels[$0]]) }
        for amount in signedAmounts where discountLabels.contains(best.matches[amount]) {
            let label = best.matches[amount]
            let slope = best.localSlopes[amount]
            func aligns(_ labelIndex: Int, with amountIndex: Int) -> Bool {
                boxes[labels[labelIndex]].maxX <= boxes[amounts[amountIndex]].minX
                    && error(amountIndex, labelIndex, slope: slope) <= tolerance
            }
            // The fitted slope supplies the same alignment test used by the
            // legacy repair in raw coordinates.
            let amountRight = boxes[amounts[amount]].maxX
            guard !signedAmounts.contains(where: {
                      $0 != amount && abs(boxes[amounts[$0]].maxX - amountRight) <= priceColumnTolerance
                          && aligns(label, with: $0)
                  }),
                  !discountLabels.contains(where: { $0 != label && aligns($0, with: amount) }) else { return bands }
        }

        let amountByLabel = Dictionary(uniqueKeysWithValues: zip(best.matches.map { labels[$0] }, amounts))
        let leftAndOther = bands.map { $0.filter { !amountSet.contains($0) } }
        // Keep any other already grouped fragments, but leave ambiguous bands
        // untouched if a price would be attached to multiple candidate names.
        guard leftAndOther.allSatisfy({ row in
                  row.filter { labelSet.contains($0) }.count <= 1 || row.allSatisfy { amountByLabel[$0] == nil }
              }),
              bands.allSatisfy({ row in
                  row.allSatisfy { amountSet.contains($0) || labelSet.contains($0) }
                      || row.allSatisfy { !amountSet.contains($0) }
              }) else { return bands }
        let repaired = leftAndOther.filter { !$0.isEmpty }.map { row in
            row + row.compactMap { amountByLabel[$0] }
        }
        // Include amounts outside the fit that already occupy the price
        // column, so moving a fitted amount cannot cross an existing price.
        let priceColumn = Set(boxes.indices.filter { index in
            boxes[index].minX >= 0.45 && hasAmountTail(text[index])
                && amounts.contains { abs(boxes[$0].maxX - boxes[index].maxX) <= priceColumnTolerance }
        })
        func priceOrder(in rows: [[Int]]) -> [Int] {
            rows.flatMap { row in
                row.filter { priceColumn.contains($0) }.sorted { boxes[$0].minX < boxes[$1].minX }
            }
        }
        return priceOrder(in: bands) == priceOrder(in: repaired) ? repaired : bands
    }

    private static func alignRows(_ fragments: [TextFragment], verticalScale: CGFloat) -> [CGFloat] {
        // Use long text edges rather than short price boxes, whose corners
        // provide a noisy slope. Give the longer edges more weight.
        let samples = fragments.compactMap { fragment -> (y: CGFloat, slope: CGFloat, weight: CGFloat)? in
            guard fragment.box.width > 0.11, let slope = fragment.rowSlope,
                  abs(slope) < 0.25 * verticalScale else { return nil }
            return (fragment.box.midY, slope, fragment.box.width * fragment.box.width)
        }
        return fragments.map { fragment in
            let nearby = samples.filter { abs($0.y - fragment.box.midY) < slopeNeighborhood * verticalScale }
            let weight = nearby.reduce(0) { $0 + $1.weight }
            guard weight > 0 else { return fragment.box.midY }
            let slope = nearby.reduce(0) { $0 + $1.slope * $1.weight } / weight
            // A single tilted title should not shift otherwise level rows.
            let agreeingEdges = nearby.filter { abs($0.slope) >= 0.01 * verticalScale && $0.slope * slope > 0 }
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

/// Vision-backed OCR: accurate level, Polish first, then English. Nothing leaves
/// the device here; the image is dropped by the caller as soon as this returns.
struct VisionReceiptRecognizer: ReceiptTextRecognizing {
    static let preferredLanguages = ["pl-PL", "en-US"]
    private static let renderContext = CIContext(options: [.cacheIntermediates: false])

    private enum ReadingError: Error { case imagePreparationFailed }

    func recognize(_ image: CGImage) async throws -> [TextFragment] {
        try await recognize(image, using: nil)
    }

    func recognize(
        _ image: CGImage, using read: (@Sendable (CGImage) async throws -> [TextFragment])?
    ) async throws -> [TextFragment] {
        let strips = ReceiptOCRStrip.plan(width: image.width, height: image.height)
        let aspectRatio = CGFloat(image.height) / CGFloat(image.width)
        let primary = try await Self.readPass(image, strips: strips, using: read, resampling: false)
        // Assess the complete receipt in each pass: its item rows and printed
        // total can be on different strips. Only the retry resamples each crop.
        let assessment = ReceiptOCRAssessment(lines: ReceiptLineOrdering.lines(from: primary, imageAspectRatio: aspectRatio))
        try Task.checkCancellation()
        guard assessment.needsRetry else { return primary }

        do {
            let alternate = try await Self.readPass(image, strips: strips, using: read, resampling: true)
            let alternateAssessment = ReceiptOCRAssessment(
                lines: ReceiptLineOrdering.lines(from: alternate, imageAspectRatio: aspectRatio)
            )
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
        using read: (@Sendable (CGImage) async throws -> [TextFragment])?, resampling: Bool
    ) async throws -> [TextFragment] {
        try Task.checkCancellation()
        if strips.isEmpty {
            let input = try prepare(image, resampling: resampling)
            try Task.checkCancellation()
            let fragments = try await (read ?? Self.read)(input)
            try Task.checkCancellation()
            return fragments
        }
        var mapped: [[TextFragment]] = []
        for strip in strips {
            try Task.checkCancellation()
            let fragments: [TextFragment]
            if let read {
                let input = try autoreleasepool { try prepareStrip(strip, in: image, resampling: resampling) }
                try Task.checkCancellation()
                fragments = try await read(input)
            } else {
                // An autorelease pool is thread-local and cannot span an await.
                // Run the synchronous Vision request with crop and resampling
                // in the same pool so only the text/geometry escapes this strip.
                fragments = try autoreleasepool {
                    let input = try prepareStrip(strip, in: image, resampling: resampling)
                    try Task.checkCancellation()
                    return try readStrip(input)
                }
            }
            try Task.checkCancellation()
            mapped.append(fragments.map { strip.map($0, toImageHeight: image.height) })
        }
        return ReceiptOCRStrip.merge(mapped, strips: strips, imageHeight: image.height)
    }

    private static func prepareStrip(_ strip: ReceiptOCRStrip, in image: CGImage, resampling: Bool) throws -> CGImage {
        let rect = CGRect(x: 0, y: strip.rows.lowerBound, width: image.width, height: strip.rows.count)
        guard let crop = image.cropping(to: rect) else { throw ReadingError.imagePreparationFailed }
        return try prepare(crop, resampling: resampling)
    }

    private static func prepare(_ image: CGImage, resampling: Bool) throws -> CGImage {
        guard resampling else { return image }
        guard let resized = resampled(image) else { throw ReadingError.imagePreparationFailed }
        return resized
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
        request.recognitionLanguages = languages(supported: request.supportedRecognitionLanguages)
            .map { Locale.Language(identifier: $0) }

        let observations = try await request.perform(on: image)
        return observations.compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            let width = observation.topRight.x - observation.topLeft.x
            let slope = width > 0.10 ? (observation.topRight.y - observation.topLeft.y) / width : nil
            return TextFragment(text: best.string, box: observation.boundingBox.cgRect, rowSlope: slope)
        }
    }

    private static func readStrip(_ image: CGImage) throws -> [TextFragment] {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = RecognizeTextRequest().minimumTextHeightFraction
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        request.recognitionLanguages = languages(supported: supported.map { Locale.Language(identifier: $0) })
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            let width = observation.topRight.x - observation.topLeft.x
            let slope = width > 0.10 ? (observation.topRight.y - observation.topLeft.y) / width : nil
            return TextFragment(text: best.string, box: observation.boundingBox, rowSlope: slope)
        }
    }

    private static func languages(supported: [Locale.Language]) -> [String] {
        let identifiers = Set(supported.map(\.maximalIdentifier))
        let usable = preferredLanguages.filter { identifiers.contains(Locale.Language(identifier: $0).maximalIdentifier) }
        return usable.isEmpty ? preferredLanguages : usable
    }

    /// Whether this device's Vision can read Polish (diacritics `ą ę ł ż …`).
    /// Shown as a hint on the edit screen when false.
    static var supportsPolish: Bool {
        let request = RecognizeTextRequest()
        let polish = Locale.Language(identifier: "pl-PL").maximalIdentifier
        return request.supportedRecognitionLanguages.contains { $0.maximalIdentifier == polish }
    }
}
