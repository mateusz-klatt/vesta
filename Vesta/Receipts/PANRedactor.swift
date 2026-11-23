import Foundation

/// Masks payment-card data in receipt text **on the device**, before anything is
/// sent to hestia. The server redacts again; this is defence in depth, with the
/// rule that a card number never leaves the phone.
///
/// Per line:
/// 0. **Protected spans** — amounts (`45,99`), dates (`2026-11-23`,
///    `23.11.2026`), times (`18:04`) and a labelled NIP — are hidden from the
///    masked-PAN and terminal fallback rules below.
/// 1. **Luhn**: any window of 12–19 digits across digit groups (1–2 spaces or a
///    dash between groups, OCR look-alikes `O`→0 and `I`/`l`→1) that passes the
///    Luhn check, including PANs Vision split across adjacent numeric lines.
/// 2. **Masked PANs** anywhere: `****1234`, `5351********1234`,
///    `XXXX XXXX XXXX 1234`, `**** 12 34`.
/// 3. **Terminal block**: on a line with a card label (`NR KARTY`, `KARTA`,
///    `CARD`, `VISA`, `AID`, `ARQC`, …) and the next ``labelWindow`` lines, any
///    run of ≥ ``blockMinDigits`` digits and any hex token (AID / ARQC).
///    Explicit terminal fields also catch short values outside the block.
enum PANRedactor {
    static let placeholder = "[REDACTED]"
    static let panLength = 12...19
    static let labelWindow = 3
    static let blockMinDigits = 8

    static func redact(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var wrappedHits: [Int: [NSRange]] = [:]
        var result: [String] = []
        result.reserveCapacity(lines.count)
        var windowLeft = 0
        for index in lines.indices {
            let line = lines[index]
            let labelled = hasCardLabel(line)
            if labelled && !isLoyaltyCard(line) { windowLeft = labelWindow + 1 }
            addWrappedPANHits(in: lines, startingAt: index, afterLabel: labelled, to: &wrappedHits)
            result.append(redactLine(line, inBlock: windowLeft > 0, wrappedHits: wrappedHits.removeValue(forKey: index) ?? []))
            if windowLeft > 0 { windowLeft -= 1 }
        }
        return result.joined(separator: "\n")
    }

    // MARK: - Line pipeline

    private static func redactLine(_ line: String, inBlock: Bool, wrappedHits: [NSRange]) -> String {
        let scan = masked(line, hiding: protectedRanges(in: line))
        // Luhn runs on the ORIGINAL line: a real PAN can contain date- or
        // amount-shaped fragments (`4111-11-11 1111 1111`), and a Luhn-valid
        // 12–19 digit window is strong enough evidence to win over protection.
        var hits = luhnRanges(in: line) + wrappedHits + matches(maskedPAN, in: scan)
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
        var result = line
        for range in merged(hits).reversed() {
            result = (result as NSString).replacingCharacters(in: range, with: placeholder)
        }
        return result
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

    /// Digit groups (OCR look-alikes allowed inside a group) joined by 1–2
    /// spaces or a dash. Only digits bound a run, so a PAN glued to a label
    /// (`VISA4111…`) is still found.
    private static let groupRun = try! NSRegularExpression(
        pattern: #"(?<!\d)[0-9][0-9OoIl]*(?:(?:  ?|-)[0-9OoIl]+)*(?!\d)"#
    )
    private static let group = try! NSRegularExpression(pattern: #"[0-9OoIl]+"#)

    private static let numericBand = try! NSRegularExpression(
        pattern: #"\A[ \t]*([0-9OoIl]+(?: {1,2}[0-9OoIl]+)*)[ \t\r]*\z"#
    )

    /// Vision can put the end of a PAN on subsequent numeric-only lines.
    /// Reuse Luhn across those boundaries and map each hit back to its line.
    private static func addWrappedPANHits(
        in lines: [String], startingAt index: Int, afterLabel: Bool, to hits: inout [Int: [NSRange]]
    ) {
        guard index + 1 < lines.count, let next = captureRanges(numericBand, in: lines[index + 1]).first else { return }
        let line = lines[index]
        guard afterLabel || !captureRanges(numericBand, in: line).isEmpty || !captureRanges(fiscalReference, in: line).isEmpty,
              let end = line.lastIndex(where: { !$0.isWhitespace }) else { return }

        var joined = String(line[...end])
        let firstLineLength = joined.utf16.count
        var bands: [(source: NSRange, joined: NSRange)] = [
            (NSRange(location: 0, length: firstLineLength), NSRange(location: 0, length: firstLineLength))
        ]
        for offset in 1...min(labelWindow, lines.count - index - 1) {
            let band = lines[index + offset]
            guard let source = offset == 1 ? next : captureRanges(numericBand, in: band).first else { break }
            let joinedRange = NSRange(location: joined.utf16.count + 1, length: source.length)
            joined += " " + (band as NSString).substring(with: source)
            bands.append((source, joinedRange))
        }

        for match in luhnRanges(in: joined) where match.location < firstLineLength && NSMaxRange(match) > firstLineLength + 1 {
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

    private static func luhnRanges(in line: String) -> [NSRange] {
        let ns = line as NSString
        var found: [NSRange] = []
        for run in groupRun.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let groups: [(range: NSRange, digits: [UInt8])] = group.matches(in: line, range: run.range).compactMap { match in
                guard let digits = ocrDigits(ns.substring(with: match.range)) else { return nil }
                return (match.range, digits)
            }
            // A single group longer than a PAN (digits glued together) can still
            // hide one: slide 12–19 digit windows inside it.
            for group in groups where group.digits.count > panLength.upperBound {
                let digits = group.digits
                for start in digits.indices {
                    for length in panLength where start + length <= digits.count {
                        guard luhnValid(digits[start..<(start + length)]) else { continue }
                        found.append(NSRange(location: group.range.location + start, length: length))
                    }
                }
            }
            // Every window of whole groups with 12–19 digits; valid ones are all
            // kept and merged later, so overlapping candidates can't leave a
            // PAN's tail behind. A window stops growing past 19 digits, so the
            // work is linear in the number of groups.
            var window: [UInt8] = []
            window.reserveCapacity(panLength.upperBound + 8)
            for start in groups.indices {
                window.removeAll(keepingCapacity: true)
                for end in start..<groups.count {
                    window += groups[end].digits
                    if window.count > panLength.upperBound { break }
                    guard panLength.contains(window.count), luhnValid(window[...]) else { continue }
                    let first = groups[start].range, last = groups[end].range
                    found.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
                }
            }
        }
        return found
    }

    /// Map OCR look-alikes to digits, even when Vision substitutes the entire
    /// group. Ignore a lone letter such as the Polish receipt unit "l".
    /// The enclosing run always starts with a real digit.
    private static func ocrDigits(_ token: String) -> [UInt8]? {
        var digits: [UInt8] = []
        var sawDigit = false
        for unit in token.utf8 {
            switch unit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digits.append(unit - UInt8(ascii: "0")); sawDigit = true
            case UInt8(ascii: "O"), UInt8(ascii: "o"): digits.append(0)
            case UInt8(ascii: "I"), UInt8(ascii: "l"): digits.append(1)
            default: return nil
            }
        }
        return sawDigit || digits.count > 1 ? digits : nil
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

    private static let maskedPAN = try! NSRegularExpression(
        pattern: #"(?<!\d)(?:\d{1,6}[ \-]?)?(?:[*xX•#][ \-]?){4,}\d(?:[ \-]?\d){1,3}(?!\d|[,.]\d)"#
    )

    // MARK: - 3. Terminal block

    private static let cardLabel = try! NSRegularExpression(
        pattern: #"(?i)\b(?:NR\s*KARTY|KARTA|KARTY|CARD|VISA|MASTERCARD|MAESTRO|AMEX|PAN|AID|ARQC|TVR|ATC)\b"#
    )

    private static let loyaltyCard = try! NSRegularExpression(
        pattern: #"(?i)\A\h*(?:KARTA\h+(?:LOJALNOŚCIOWA|MOJA\h+BIEDRONKA)|NR\h+KARTY\h+LOJALNOŚCIOWEJ)\h*:\h*([0-9]{8,19})\h*\r?\z"#
    )

    /// Short, labelled receipt references may sit beside card fields on the
    /// printout. The exemption is only for the digit fallback, and only when
    /// the entire run is shorter than a PAN.
    private static let fiscalReference = try! NSRegularExpression(
        pattern: #"(?i)\bNR[ \t]+(?:PARAGONU|TRANSAKCJI)\b[ \t:.]*([0-9]{8,11})(?!\d|(?: {1,2}|[-.,])\d)"#
    )

    /// Short or alphanumeric values that the generic terminal fallback misses.
    /// Only the value after an explicit sensitive field name is redacted.
    private static let terminalField = try! NSRegularExpression(
        pattern: #"""
        (?ix)\b(?:
            (?:AID|ARQC|TVR|TSI|ATC)\b (?:\h*:\h*|\h+) ([A-F0-9]{2,32})
          | (?:NR\h+TERMINALA|KOD\h+(?:AUTORYZACJI|BLIK))\b
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

    /// Digit runs (1–2 spaces, a dash, a dot or a comma between digits) not
    /// glued to a letter; a colon in front is fine (`NR KARTY:53511234`).
    private static let blockRun = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\d])\d(?:(?:  ?|[-.,])?\d)*(?![\p{L}\d])"#
    )
    private static let hexToken = try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}\d])[a-f0-9]{10,32}(?![\p{L}\d])"#)

    private static func blockDigitRanges(in line: String) -> [NSRange] {
        let ns = line as NSString
        return matches(blockRun, in: line).filter {
            ns.substring(with: $0).filter(\.isASCIIDigit).count >= blockMinDigits
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
