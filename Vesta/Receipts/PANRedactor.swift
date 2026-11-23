import Foundation

/// Masks payment-card data in receipt text **on the device**, before anything is
/// sent to hestia. The server redacts again; this is defence in depth, with the
/// rule that a card number never leaves the phone.
///
/// Decimal Unicode digits are folded on a scan copy. Replacements preserve the
/// original text and use UTF-16 offsets, including for supplementary digits.
/// 0. **Protected spans** — money, dates, times and checksum-valid labelled NIPs
///    stay hidden from masked-PAN detection. Dates, times, NIPs and short
///    fiscal references also stay hidden from the terminal digit fallback.
/// 1. **Luhn** checks 12–19 digits across horizontal spaces, dash variants,
///    slashes, dots and adjacent OCR lines. It requires real digits and
///    understands O/o, I/l, S, B, Z and G. It also checks inside glued digit
///    groups, with stricter prefix evidence for short, trimmed candidates.
/// 2. **Masked PANs** include grouped prefixes and tails, short masks with a
///    visible prefix, dot/middle-dot masks and tails split onto a new line.
/// 3. **Terminal block**: on a line with a card label (`NR KARTY`, `KARTA`,
///    `PŁATNOŚĆ KARTĄ`, `VISA`, `AID`, terminal brands, …) and the next three
///    lines, digit runs of at least eight and terminal hex tokens are masked.
///    A terminal identifier label (`TID`) restarts the same window.
///    The fallback uses the same separators and also accepts decimal commas.
///    Explicit terminal fields also catch short values outside the block.
enum PANRedactor {
    static let placeholder = "[REDACTED]"
    static let panLength = 12...19
    static let labelWindow = 3
    static let blockMinDigits = 8

    private static let digitGlyph = #"[0-9OoIlSBZG]"#
    private static let separator = #"(?:[\p{Zs}\t]+|[-–—−/])"#
    private static let luhnSeparator = "(?:\(separator)|\\.)"
    private static let blockSeparator = "(?:\(luhnSeparator)|,)"

    // Accepted limitations: without terminal context, a checksum-invalid OCR
    // read cannot safely be distinguished from receipt IDs. A bare last four
    // also looks like an ordinary price or reference. Arbitrary manual
    // obfuscation may destroy both the supported glyphs and the card context.
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
            if labelled && !isLoyaltyCard(line) { windowLeft = labelWindow + 1 }
            addWrappedPANHits(in: shadows, startingAt: index, afterLabel: labelled, to: &wrappedHits)
            let hits = lineHits(line, inBlock: windowLeft > 0) + (wrappedHits.removeValue(forKey: index) ?? [])
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
        // Luhn runs on the ORIGINAL line: a real PAN can contain date- or
        // amount-shaped fragments (`4111-11-11 1111 1111`), and a Luhn-valid
        // 12–19 digit window is strong enough evidence to win over protection.
        var hits = luhnRanges(in: line) + maskedPANRanges(in: scan)
        hits += terminalFieldRanges(in: line)
        if inBlock {
            // Amounts are not protected inside a card block: a PAN split by a
            // dot or comma (`NR KARTY: 422222222.2222`) looks like money.
            let protected = protectedRanges(in: line, money: false) + captureRanges(fiscalReference, in: line)
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
            guard original.unicodeScalars.contains(where: { !$0.isASCII && $0.properties.numericType == .decimal }) else {
                text = original
                offsets = []
                return
            }
            var shadow = ""
            var boundaries = [0]
            var offset = 0
            for scalar in original.unicodeScalars {
                let width = scalar.value > 0xFFFF ? 2 : 1
                offset += width
                if !scalar.isASCII, scalar.properties.numericType == .decimal, let value = scalar.properties.numericValue {
                    shadow.unicodeScalars.append(Unicode.Scalar(48 + Int(value))!)
                } else {
                    shadow.unicodeScalars.append(scalar)
                    if width == 2 { boundaries.append(offset - 1) }
                }
                boundaries.append(offset)
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

    private static let protectedPatterns: [NSRegularExpression] = [
        // money: 1–9 integer digits, comma/dot, 2–4 decimals
        try! NSRegularExpression(pattern: #"(?<!\d)\d{1,9}[,.]\d{2,4}(?!\d)"#),
        // ISO date / day-first date
        try! NSRegularExpression(pattern: #"(?<!\d)\d{4}-\d{2}-\d{2}(?!\d)"#),
        try! NSRegularExpression(pattern: #"(?<!\d)\d{2}[-./]\d{2}[-./]\d{4}(?!\d)"#),
        // time
        try! NSRegularExpression(pattern: #"(?<!\d)(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?(?!\d)"#),
    ]
    private static let nipPattern = try! NSRegularExpression(
        pattern: #"(?i)\bNIP\b(?:[ \t]+(?:nabywcy|sprzedawcy)\b)?[ \t:.]*((?:\d[ \t-]?){9}\d)(?!-?\d)"#
    )

    private static func protectedRanges(in line: String, money: Bool = true) -> [NSRange] {
        var ranges = protectedPatterns.dropFirst(money ? 0 : 1).flatMap { matches($0, in: line) }
        let ns = line as NSString
        for match in nipPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let digits = ns.substring(with: match.range(at: 1)).filter(\.isASCIIDigit)
            if validNIP(digits) { ranges.append(match.range(at: 1)) }
        }
        return ranges
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

    // A run may start inside a word when the first character is a real digit
    // (for example VISA4111…). Look-alike-only groups must be separate tokens.
    private static let groupRun = try! NSRegularExpression(
        pattern: "(?:(?<![\\p{L}\\d])\(digitGlyph)+|(?<!\\d)[0-9]\(digitGlyph)*)(?:\(luhnSeparator)\(digitGlyph)+)*"
    )
    private static let group = try! NSRegularExpression(pattern: "\(digitGlyph)+")
    private static let numericBand = try! NSRegularExpression(
        pattern: "\\A\\h*(\(digitGlyph)+(?:\(luhnSeparator)\(digitGlyph)+)*)\\h*\\r?\\z"
    )
    private static let maskBand = try! NSRegularExpression(
        pattern: "\\A\\h*(?:\(maskGlyph)\(separator)?){4,}\\h*\\r?\\z"
    )

    /// Map checksum and masked-card hits on joined OCR bands back to each
    /// physical line. Keep indentation and line breaks in the result.
    private static func addWrappedPANHits(
        in lines: [DigitShadow], startingAt index: Int, afterLabel: Bool, to hits: inout [Int: [NSRange]]
    ) {
        guard index + 1 < lines.count,
              let next = captureRanges(numericBand, in: lines[index + 1].text).first else { return }
        let line = lines[index].text
        let maskOnly = maskBand.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil
        guard afterLabel || maskOnly || !captureRanges(numericBand, in: line).isEmpty
                || !captureRanges(fiscalReference, in: line).isEmpty,
              let end = line.lastIndex(where: { !$0.isWhitespace }) else { return }

        var joined = String(line[...end])
        let firstLineLength = joined.utf16.count
        let firstRange = NSRange(location: 0, length: firstLineLength)
        var bands = [(source: firstRange, joined: firstRange)]
        for offset in 1...min(labelWindow, lines.count - index - 1) {
            let band = lines[index + offset].text
            guard let source = offset == 1 ? next : captureRanges(numericBand, in: band).first else { break }
            let joinedRange = NSRange(location: joined.utf16.count + 1, length: source.length)
            joined += " " + (band as NSString).substring(with: source)
            bands.append((source, joinedRange))
        }

        let candidates = luhnRanges(in: joined) + maskedPANRanges(in: masked(joined, hiding: protectedRanges(in: joined)))
        for match in candidates where match.location < firstLineLength && NSMaxRange(match) > firstLineLength + 1 {
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
        let ns = line as NSString
        let eans = captureRanges(eanField, in: line)
        var hits: [NSRange] = []
        for run in groupRun.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard run.range.length >= panLength.lowerBound else { continue }
            var digits: [ScanDigit] = []
            for group in group.matches(in: line, range: run.range) {
                let token = Array(ns.substring(with: group.range).utf8)
                let end = NSMaxRange(group.range)
                var visibleLength = token.count
                // Do not absorb the start of a glued word when expanding a
                // hit. Still check OCR glyphs there, since a PAN may end in
                // an OCR substitution immediately before the word.
                if end < ns.length, CharacterSet.letters.contains(Unicode.Scalar(ns.character(at: end)) ?? " ") {
                    visibleLength = token.lastIndex(where: isDigit).map { $0 + 1 } ?? 0
                }
                // Retain the previous treatment of single O/I/l tokens,
                // including the common litre unit, as non-digit separators.
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
                // Keep whole-group matches. Only trim unusually long groups,
                // so an interior checksum match cannot eat parts of a date
                // or four-digit group. For short glued runs, also require the
                // leading digit of a common card network.
                guard startsGroup || first.allowsTrim, endsGroup || last.allowsTrim else { continue }
                guard (startsGroup && endsGroup) || first.group.length > panLength.upperBound
                        || last.group.length > panLength.upperBound || (2...6).contains(first.value) else { continue }
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
        case UInt8(ascii: "S"): return 5
        case UInt8(ascii: "B"): return 8
        case UInt8(ascii: "Z"): return 2
        case UInt8(ascii: "G"): return 6
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

    private static let maskGlyph = #"[.*xX•#·]"#
    private static let maskedPAN = try! NSRegularExpression(
        pattern: "(?<!\\d)(?:(?:[0-9]\(separator)?){1,6}(?:\(maskGlyph)\(separator)?){2,}"
            + "|(?:\(maskGlyph)\(separator)?){4,})\(digitGlyph)(?:\(separator)?\(digitGlyph)){1,3}"
            + "(?!\\d|[,.]\\d)"
    )

    private static func maskedPANRanges(in line: String) -> [NSRange] {
        let ns = line as NSString
        return matches(maskedPAN, in: line).filter { ns.substring(with: $0).utf8.contains(where: isDigit) }
    }

    // MARK: - 3. Terminal block

    private static let cardLabel = try! NSRegularExpression(
        pattern: #"(?i)\b(?:NR\s*KARTY|KART[AYĄĘ]|KARCIE|(?:PŁATNOŚĆ|PLATNOSC)\h+KART[AEYĄĘ]?|CARD|VISA|MASTERCARD|MAESTRO|AMEX|VPAY|JCB|DINERS|UNIONPAY|POLCARD|ESERVICE|PAN|AID|ARQC|TVR|ATC|TID)\b"#
    )

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
          | (?:NR\h+TERMINALA|TID|KOD\h+(?:AUTORYZACJI|BLIK))\b
              (?:\h*:\h*|\h+) ([A-Z0-9]{4,16})
          | (?:WAŻNA\h+DO|EXP)\b (?:\h*:\h*|\h+) ((?:0[1-9]|1[0-2])[-/.][0-9]{2})
          | NR\h*KARTY\b (?:\h*:\h*|\h+)
              ((?:[0-9]{1,6}[\h-]?)?(?:[*xX•\x23][\h-]?){4,}[0-9](?:[\h.,-]?[0-9]){3}|[0-9]{4})
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
        cardLabel.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    private static func isLoyaltyCard(_ line: String) -> Bool {
        let ns = line as NSString
        // A complete, Luhn-invalid loyalty ID does not open a terminal block.
        // Keep the fallback for values with OCR separators or other ambiguity.
        guard let loyalty = loyaltyCard.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return false }
        return !luhnValid(ns.substring(with: loyalty.range(at: 1)))
    }

    private static let blockRun = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\d])\(digitGlyph)+(?:\(blockSeparator)\(digitGlyph)+)*(?![\\p{L}\\d])"
    )
    private static let hexToken = try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}\d])[a-f0-9]{10,32}(?![\p{L}\d])"#)

    private static func blockDigitRanges(in line: String) -> [NSRange] {
        let ns = line as NSString
        return matches(blockRun, in: line).filter {
            let bytes = ns.substring(with: $0).utf8
            return bytes.contains(where: isDigit) && bytes.filter { isDigit($0) || "OoIlSBZG".utf8.contains($0) }.count >= blockMinDigits
        }
    }

    // MARK: - Helpers

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
