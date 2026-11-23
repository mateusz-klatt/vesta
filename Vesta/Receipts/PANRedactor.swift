import Foundation

/// Masks payment-card data in receipt text **on the device**, before anything is
/// sent to hestia. The server redacts again; this is defence in depth, with the
/// rule that a card number never leaves the phone.
///
/// Decimal Unicode digits are folded and combining marks on digits are dropped
/// on the scan copy. UTF-16 offsets map edits to the original text.
/// 0. **Protected spans** — dates, times, valid labelled NIPs and ordinary
///    decimal amounts are hidden from fallback detection. Short labelled
///    fiscal references also survive the terminal digit fallback.
/// 1. **Luhn** checks 12–19 digits across horizontal spaces, dash variants,
///    slashes, dots and adjacent OCR lines. Wide OCR column gaps beside a
///    date, decimal or postal code separate fields. A run needs real digits
///    and may also use OCR look-alikes O/o, I/l and S/B/Z/G in either case.
///    Trimmed short groups require a plausible card prefix.
/// 2. **Masked PANs** require one mask glyph and a four-character tail with
///    at least two real digits. ASCII dots require a glued 4–6 digit prefix.
///    Card fields may have dotted tails, and masks may span OCR lines.
/// 3. **Terminal block**: on a line with a card label (`NR KARTY`, `KARTA`,
///    `PŁATNOŚĆ KARTĄ`, `VISA`, `AID`, terminal brands, …) and the next three
///    lines, digit runs of at least eight and terminal hex tokens are masked.
///    Terminal identifiers restart the window. A fourth line may carry an
///    explicit `NR:` reference. Contiguous PAN-like punctuation remains visible
///    to the fallback, including decimal commas.
///    Explicit terminal fields also catch short values outside the block.
enum PANRedactor {
    static let placeholder = "[REDACTED]"
    static let panLength = 12...19
    static let labelWindow = 3
    static let blockMinDigits = 8

    private static let lookAlikes = "OoIlSsBbZzGg"
    private static let digitGlyph = "[0-9\(lookAlikes)]"
    private static let separator = #"(?:[\p{Zs}\t]+|[-–—−/])"#
    private static let luhnSeparator = "(?:\(separator)|\\.)"
    private static let blockSeparator = "(?:\(luhnSeparator)|,)"

    // Accepted limitations: without terminal context, a checksum-invalid OCR
    // read cannot safely be distinguished from receipt IDs. A bare last four
    // also looks like an ordinary price or reference. Arbitrary manual
    // obfuscation may destroy both the supported glyphs and the card context.
    // A Luhn-valid EAN or long fiscal identifier can be redacted. Hestia
    // already redacts long fields, so we keep the stronger privacy rule.
    static func redact(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let shadows = lines.map(DigitShadow.init)
        var wrappedHits: [Int: [NSRange]] = [:]
        var result: [String] = []
        result.reserveCapacity(lines.count)
        var windowLeft = 0
        for index in lines.indices {
            let line = shadows[index].text
            let labelled = hasCardLabel(line)
            if labelled && !isLoyaltyCard(line) { windowLeft = labelWindow + 2 }
            let inBlock = windowLeft > 1 || (windowLeft == 1 && hasMatch(terminalReference, in: line))
            addWrappedPANHits(in: shadows, startingAt: index, inBlock: inBlock, to: &wrappedHits)
            let hits = lineHits(line, inBlock: inBlock) + (wrappedHits.removeValue(forKey: index) ?? [])
            var original = lines[index]
            for hit in merged(hits).reversed() {
                original = (original as NSString).replacingCharacters(in: shadows[index].originalRange(hit), with: placeholder)
            }
            result.append(original)
            if windowLeft > 0 { windowLeft -= 1 }
        }
        return result.joined(separator: "\n")
    }

    // MARK: - Line pipeline

    private static func lineHits(_ line: String, inBlock: Bool) -> [NSRange] {
        let scan = masked(line, hiding: protectedRanges(in: line))
        var hits = luhnRanges(in: line) + maskedPANRanges(in: scan)
        hits += terminalFieldRanges(in: line)
        if inBlock {
            hits += maskedPANRanges(in: line, cardField: true)
            let protected = protectedRanges(in: line, inBlock: true) + captureRanges(fiscalReference, in: line)
            hits += blockDigitRanges(in: masked(line, hiding: protected))
            hits += matches(hexToken, in: scan).filter { range in
                (scan as NSString).substring(with: range).contains(where: \.isLetter)
            }
        }
        return hits
    }

    private struct DigitShadow {
        let text: String
        private let offsets: [Int]

        init(_ original: String) {
            guard original.unicodeScalars.contains(where: {
                !$0.isASCII && ($0.properties.numericType == .decimal || CharacterSet.nonBaseCharacters.contains($0))
            }) else {
                text = original
                offsets = []
                return
            }
            var shadow = ""
            var boundaries = [0]
            var offset = 0
            var followsDigit = false
            for scalar in original.unicodeScalars {
                let width = scalar.value > 0xFFFF ? 2 : 1
                offset += width
                if !scalar.isASCII, scalar.properties.numericType == .decimal, let value = scalar.properties.numericValue {
                    shadow.unicodeScalars.append(Unicode.Scalar(48 + Int(value))!)
                } else if followsDigit && CharacterSet.nonBaseCharacters.contains(scalar) {
                    boundaries[boundaries.count - 1] = offset
                    continue
                } else {
                    shadow.unicodeScalars.append(scalar)
                    if width == 2 { boundaries.append(offset - 1) }
                }
                boundaries.append(offset)
                followsDigit = scalar.properties.numericType == .decimal
            }
            text = shadow
            offsets = boundaries.count == offset + 1 ? [] : boundaries
        }

        func originalRange(_ range: NSRange) -> NSRange {
            guard !offsets.isEmpty else { return range }
            return NSRange(location: offsets[range.location], length: offsets[NSMaxRange(range)] - offsets[range.location])
        }
    }

    // MARK: - 0. Protected spans

    private static let money = try! NSRegularExpression(pattern: #"(?<![\d,.])\d{1,9}[,.]\d{2,4}(?![\d,.])"#)
    private static let protectedPatterns: [NSRegularExpression] = [
        // ISO date / day-first date
        try! NSRegularExpression(pattern: #"(?<!\d)\d{4}-\d{2}-\d{2}(?!\d)"#),
        try! NSRegularExpression(pattern: #"(?<!\d)\d{2}[-./]\d{2}[-./]\d{4}(?!\d)"#),
        // time
        try! NSRegularExpression(pattern: #"(?<!\d)(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?(?!\d)"#),
    ]
    private static let nipPattern = try! NSRegularExpression(
        pattern: #"(?i)\bNIP\b(?:[ \t]+(?:nabywcy|sprzedawcy)\b)?[ \t:.]*((?:\d[ \t-]?){9}\d)(?!-?\d)"#
    )

    private static func protectedRanges(in line: String, inBlock: Bool = false) -> [NSRange] {
        var ranges = protectedPatterns.flatMap { matches($0, in: line) }
        // Protect separate money columns. Longer punctuation-joined tokens
        // can be a PAN and remain visible to the terminal fallback.
        ranges += matches(money, in: line).filter { !inBlock || $0.length <= blockMinDigits }
        let ns = line as NSString
        for match in nipPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let digits = ns.substring(with: match.range(at: 1)).filter(\.isASCIIDigit)
            if validNIP(digits) { ranges.append(match.range(at: 1)) }
        }
        return ranges
    }

    private static let dateOrPostalColumn = try! NSRegularExpression(
        pattern: #"(?<![\d./-])(?:(?:19|20)\d{2}-\d{2}-\d{2}|\d{2}[-./]\d{2}[-./](?:19|20)\d{2}|\d{2}-\d{3})(?![\d./-])"#
    )
    private static let columnGap = try! NSRegularExpression(pattern: #"\h{2,}|\h*\t\h*"#)

    private static func separatingFiscalColumns(in line: String) -> String {
        let gaps = matches(columnGap, in: line)
        guard !gaps.isEmpty else { return line }
        let fields = matches(dateOrPostalColumn, in: line)
            + matches(money, in: line).filter { $0.length <= blockMinDigits }
        guard !fields.isEmpty else { return line }
        let starts = Set(fields.map(\.location))
        let ends = Set(fields.map(NSMaxRange))
        return masked(line, hiding: gaps.filter { ends.contains($0.location) || starts.contains(NSMaxRange($0)) })
    }

    /// Same-length copy of `line` with protected ranges replaced by `_`, so the
    /// rules can't see them but every range still maps 1:1 onto the original.
    private static func masked(_ line: String, hiding ranges: [NSRange]) -> String {
        let copy = NSMutableString(string: line)
        for range in ranges {
            copy.replaceCharacters(in: range, with: String(repeating: "_", count: range.length))
        }
        return copy as String
    }

    // MARK: - 1. Luhn windows over digit groups

    // A run may start inside a word at a real digit (VISA4111…) or just after
    // MASTERCARD when OCR also obscures the first digit.
    private static let groupRun = try! NSRegularExpression(
        pattern: "(?:(?<![\\p{L}\\d])\(digitGlyph)+|(?<=(?i:MASTERCARD))\(digitGlyph)+"
            + "|(?<!\\d)[0-9]\(digitGlyph)*)(?:\(luhnSeparator)\(digitGlyph)+)*"
    )
    private static let group = try! NSRegularExpression(pattern: "\(digitGlyph)+")
    private static let bandGlyph = "[0-9\(lookAlikes)*xX•#·]"
    private static let bandFragment = "\(bandGlyph)+(?:\(luhnSeparator)\(bandGlyph)+)*"
    private static let leadingBand = try! NSRegularExpression(
        pattern: "\\A\\h*(\(bandFragment))(?![\\p{L}\\p{M}\\d]|[,.]\\d)"
    )
    private static let trailingBand = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{M}\\d,.])(\(bandFragment))\\h*\\r?\\z"
    )

    /// Join a trailing fragment to leading fragments from adjacent OCR lines.
    /// Project only crossing hits back to the source, retaining other columns.
    private static func addWrappedPANHits(
        in lines: [DigitShadow], startingAt index: Int, inBlock: Bool, to hits: inout [Int: [NSRange]]
    ) {
        guard index + 1 < lines.count,
              let next = captureRanges(leadingBand, in: lines[index + 1].text).first,
              let first = captureRanges(trailingBand, in: lines[index].text).first else { return }

        var joined = (lines[index].text as NSString).substring(with: first)
        let firstLineLength = first.length
        // Outside a terminal, require a meaningful numeric fragment or
        // visible mask glyphs on the first line before crossing a line break.
        guard inBlock || joined.utf8.filter(isDigit).count >= 4
                || joined.contains(where: { "*xX•#·".contains($0) }) else { return }
        var bands = [(source: first, joined: NSRange(location: 0, length: firstLineLength))]
        for offset in 1...min(labelWindow, lines.count - index - 1) {
            let band = lines[index + offset].text as NSString
            guard let source = offset == 1 ? next : captureRanges(leadingBand, in: band as String).first else { break }
            // Treat a line break as a column gap so dates and amounts do not
            // join to unrelated numeric fields on the next line.
            let joinedRange = NSRange(location: joined.utf16.count + 2, length: source.length)
            joined += "  " + band.substring(with: source)
            bands.append((source, joinedRange))
            if !band.substring(from: NSMaxRange(source)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
        }

        let candidates = luhnRanges(in: joined) + maskedPANRanges(in: masked(joined, hiding: protectedRanges(in: joined)))
        for match in candidates where match.location < firstLineLength && NSMaxRange(match) > firstLineLength + 2 {
            for (offset, band) in bands.enumerated() {
                let overlap = NSIntersectionRange(match, band.joined)
                guard overlap.length > 0 else { continue }
                hits[index + offset, default: []].append(NSRange(
                    location: band.source.location + overlap.location - band.joined.location,
                    length: overlap.length
                ))
            }
        }
    }

    private struct ScanDigit {
        let value: Int
        let offset: Int
        let isReal: Bool
        let group: NSRange
        let allowsTrim: Bool
    }

    private static func luhnRanges(in line: String) -> [NSRange] {
        let line = separatingFiscalColumns(in: line)
        let ns = line as NSString
        let eans = captureRanges(eanField, in: line)
        var hits: [NSRange] = []
        for run in groupRun.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard run.range.length >= panLength.lowerBound else { continue }
            var digits: [ScanDigit] = []
            for group in group.matches(in: line, range: run.range) {
                var token = Array(ns.substring(with: group.range).utf8)
                let end = NSMaxRange(group.range)
                var visibleLength = token.count
                // Do not absorb the start of a glued word when expanding a
                // hit. Still check OCR glyphs there, since a PAN may end in
                // an OCR substitution immediately before the word.
                if end < ns.length, let next = Unicode.Scalar(ns.character(at: end)) {
                    if CharacterSet.nonBaseCharacters.contains(next) {
                        // A decomposed letter (for example Z + dot) is a word
                        // character. Keep its base and mark together.
                        token.removeLast()
                        visibleLength = token.count
                    } else if CharacterSet.letters.contains(next) {
                        visibleLength = token.lastIndex(where: isDigit).map { $0 + 1 } ?? 0
                    }
                }
                // Accepted OCR miss: a separated l or S can be a unit or
                // abbreviation. Do not promote such a singleton to a digit.
                // An all-letter prefix glued to a word stays text as well.
                if token.count == 1, let byte = token.first, "OoIl".utf8.contains(byte) { continue }
                guard visibleLength > 0, token.count > 1 || token.first.map(isDigit) == true else {
                    appendLuhnHits(digits, to: &hits)
                    digits.removeAll(keepingCapacity: true)
                    continue
                }
                let range = NSRange(location: group.range.location, length: visibleLength)
                let allowsTrim = token.count > 4 && !(eans.contains(range) && validEAN13(token))
                for (index, byte) in token.enumerated() {
                    digits.append(ScanDigit(
                        value: ocrDigit(byte), offset: range.location + index, isReal: isDigit(byte),
                        group: range, allowsTrim: allowsTrim
                    ))
                }
            }
            appendLuhnHits(digits, to: &hits)
        }
        return hits
    }

    private static func appendLuhnHits(_ digits: [ScanDigit], to hits: inout [NSRange]) {
        guard digits.count >= panLength.lowerBound else { return }
        for start in 0...(digits.count - panLength.lowerBound) {
            let first = digits[start]
            var sum = 0
            var flippedSum = 0
            var hasRealDigit = false
            for end in start..<min(start + panLength.upperBound, digits.count) {
                let last = digits[end]
                let doubled = last.value * 2 - (last.value >= 5 ? 9 : 0)
                // Appending a digit flips the weight of every earlier digit.
                (sum, flippedSum) = (flippedSum + last.value, sum + doubled)
                hasRealDigit = hasRealDigit || last.isReal
                let length = end - start + 1
                guard length >= panLength.lowerBound, hasRealDigit, sum % 10 == 0 else { continue }
                let startsGroup = first.offset == first.group.location
                let endsGroup = last.offset + 1 >= NSMaxRange(last.group)
                // Keep whole-group matches. Accepted miss: trimming a
                // four-digit group can turn a date or product field into a
                // plausible card. Trim longer groups and require a plausible
                // network prefix, including 7 for fleet cards.
                guard startsGroup || first.allowsTrim, endsGroup || last.allowsTrim else { continue }
                guard (startsGroup && endsGroup) || first.group.length > panLength.upperBound
                        || last.group.length > panLength.upperBound || (2...7).contains(first.value) else { continue }
                let endOffset = max(last.offset + 1, NSMaxRange(last.group))
                hits.append(NSRange(location: first.group.location, length: endOffset - first.group.location))
            }
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    // A full Luhn match still wins. A proper subset of an explicitly labelled,
    // checksum-valid EAN-13 is too weak to identify it as a PAN by itself.
    private static let eanField = try! NSRegularExpression(pattern: #"(?i)\bEAN(?:-13)?\h*:?\h*([0-9]{13})(?!\d)"#)

    private static func validEAN13(_ token: [UInt8]) -> Bool {
        token.enumerated().reduce(0) { total, digit in
            total + ocrDigit(digit.element) * (digit.offset.isMultiple(of: 2) ? 1 : 3)
        }.isMultiple(of: 10)
    }

    private static func ocrDigit(_ byte: UInt8) -> Int {
        switch byte {
        case UInt8(ascii: "O"), UInt8(ascii: "o"): return 0
        case UInt8(ascii: "I"), UInt8(ascii: "l"): return 1
        case UInt8(ascii: "S"), UInt8(ascii: "s"): return 5
        case UInt8(ascii: "B"), UInt8(ascii: "b"): return 8
        case UInt8(ascii: "Z"), UInt8(ascii: "z"): return 2
        case UInt8(ascii: "G"), UInt8(ascii: "g"): return 6
        default: return Int(byte - UInt8(ascii: "0"))
        }
    }

    static func luhnValid(_ digits: String) -> Bool {
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else { return false }
        return luhnValid(digits.utf8.map { $0 - UInt8(ascii: "0") }[...])
    }

    static func luhnValid(_ digits: ArraySlice<UInt8>) -> Bool {
        var sum = 0
        var double = false
        for digit in digits.reversed() {
            var value = Int(digit)
            if double {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
            double.toggle()
        }
        return !digits.isEmpty && sum % 10 == 0
    }

    /// Polish NIP checksum (weights 6 5 7 2 3 4 5 6 7, mod 11).
    static func validNIP(_ digits: String) -> Bool {
        guard digits.count == 10, digits.allSatisfy(\.isASCIIDigit) else { return false }
        let values = digits.compactMap { Int(String($0)) }
        let checksum = zip(values.prefix(9), [6, 5, 7, 2, 3, 4, 5, 6, 7]).map(*).reduce(0, +) % 11
        return checksum != 10 && checksum == values[9]
    }

    // MARK: - 2. Masked PANs

    private static func maskRuns(minimum: Int) -> String {
        ["\\*", "[xX]", "•", "#", "·"].map { "(?:\($0)\(separator)?){\(minimum),}" }.joined(separator: "|")
    }

    private static let maskPrefix = "(?<!\\d)(?:(?:\(digitGlyph)\(separator)?){1,6}(?:\(maskRuns(minimum: 2)))"
        + "|\(maskRuns(minimum: 4))|[0-9]{4,6}\\.{4,})"
    private static let maskTailEnd = "(?![\\p{L}\\p{M}\\d%]|[,.]\\d)"
    private static let maskedPAN = try! NSRegularExpression(
        pattern: "\(maskPrefix)(\(digitGlyph)(?:\(separator)?\(digitGlyph)){3})\(maskTailEnd)"
    )
    private static let maskedCardField = try! NSRegularExpression(
        pattern: "(?i)\\A\\h*(?:(?:NR\\h*KARTY|KARTA|CARD|PAN)(?:\\h*:\\h*|\\h+))?"
            + "(\(maskPrefix)(\(digitGlyph){2}[.,]\(digitGlyph){2}))\\h*\\r?\\z"
    )
    private static let cardNumberLabel = try! NSRegularExpression(pattern: #"(?i)\A\h*NR\h*KARTY\b"#)

    private static func maskedPANRanges(in line: String, cardField: Bool = false) -> [NSRange] {
        let ns = line as NSString
        let regex = cardField ? maskedCardField : maskedPAN
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let tail = ns.substring(with: match.range(at: cardField ? 2 : 1))
            guard tail.utf8.filter(isDigit).count >= 2 else { return nil }
            // A comma also precedes grosze. Accept it in a masked tail only
            // when the receipt explicitly names a card-number field.
            guard !tail.contains(",") || hasMatch(cardNumberLabel, in: line) else { return nil }
            return cardField ? match.range(at: 1) : match.range
        }
    }

    // MARK: - 3. Terminal block

    private static let cardLabel = try! NSRegularExpression(
        pattern: #"(?i)\b(?:NR\s*KARTY|KART[AYĄĘ]|KARCIE|(?:PŁATNOŚĆ|PLATNOSC)\h+KART[AEYĄĘ]?|CARD|VISA|MASTERCARD|MAESTRO|AMEX|VPAY|JCB|DINERS|UNIONPAY|POLCARD|ESERVICE|PAN|AID|ARQC|TVR|ATC|TID|MID|NR\h+TERMINALA)\b"#
    )
    private static let terminalReference = try! NSRegularExpression(pattern: #"(?i)\A\h*NR\h*:"#)

    private static let loyaltyCard = try! NSRegularExpression(
        pattern: #"(?i)\A\h*(?:KARTA\h+(?:LOJALNOŚCIOWA|MOJA\h+BIEDRONKA)|NR\h+KARTY\h+LOJALNOŚCIOWEJ)\h*:\h*([0-9]{8,19})\h*\r?\z"#
    )

    /// Short, labelled receipt references may sit beside card fields on the
    /// printout. The exemption is only for the digit fallback, and only when
    /// the entire run is shorter than a PAN.
    private static let fiscalReference = try! NSRegularExpression(
        pattern: "(?i)\\bNR\\h+(?:PARAGONU|TRANSAKCJI)\\b[\\h:.]*([0-9]{8,11})(?!\\d|\(blockSeparator)\\d)"
    )

    /// Short or alphanumeric values that the generic terminal fallback misses.
    /// Only the value after an explicit sensitive field name is redacted.
    private static let terminalField = try! NSRegularExpression(
        pattern: #"""
        (?ix)\b(?:
            (?:AID|ARQC|TVR|TSI|ATC)\b (?:\h*:\h*|\h+) ([A-F0-9]{2,32})
          | (?:NR\h+TERMINALA|TID|MID|KOD\h+(?:AUTORYZACJI|BLIK))\b
              (?:\h*:\h*|\h+) ([A-Z0-9]{4,16})
          | (?:WAŻNA\h+DO|EXP)\b (?:\h*:\h*|\h+) ((?:0[1-9]|1[0-2])[-/.][0-9]{2})
          | NR\h*KARTY\b (?:\h*:\h*|\h+) ([0-9]{4})
        )(?=$|\h|\r)
        """#
    )

    private static func terminalFieldRanges(in line: String) -> [NSRange] {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return terminalField.matches(in: line, range: range).flatMap { match in
            (1..<match.numberOfRanges).map { match.range(at: $0) }.filter { $0.location != NSNotFound }
        }
    }

    private static func hasCardLabel(_ line: String) -> Bool {
        hasMatch(cardLabel, in: line)
    }

    private static func isLoyaltyCard(_ line: String) -> Bool {
        let ns = line as NSString
        // A complete, Luhn-invalid loyalty ID does not open a terminal block.
        // Keep the fallback for values with OCR separators or other ambiguity.
        guard let loyalty = loyaltyCard.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return false }
        return !luhnValid(ns.substring(with: loyalty.range(at: 1)))
    }

    private static let blockRun = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{M}\\d])\(digitGlyph)+(?:\(blockSeparator)\(digitGlyph)+)*(?![\\p{L}\\p{M}\\d])"
    )
    private static let hexToken = try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}\d])[a-f0-9]{10,32}(?![\p{L}\d])"#)

    private static func blockDigitRanges(in line: String) -> [NSRange] {
        let ns = line as NSString
        return matches(blockRun, in: line).filter {
            let bytes = ns.substring(with: $0).utf8
            return bytes.contains(where: isDigit) && bytes.filter { isDigit($0) || lookAlikes.utf8.contains($0) }.count >= blockMinDigits
        }
    }

    // MARK: - Helpers

    private static func hasMatch(_ regex: NSRegularExpression, in line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil
    }

    private static func matches(_ regex: NSRegularExpression, in line: String) -> [NSRange] {
        regex.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)).map(\.range)
    }

    private static func captureRanges(_ regex: NSRegularExpression, in line: String) -> [NSRange] {
        regex.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)).map { $0.range(at: 1) }
    }

    /// Sort and merge overlapping/adjacent ranges.
    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var out: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = out.last, range.location <= NSMaxRange(last) {
                out[out.count - 1] = NSUnionRange(last, range)
            } else {
                out.append(range)
            }
        }
        return out
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
