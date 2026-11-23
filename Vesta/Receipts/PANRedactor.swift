import Foundation

/// Masks payment-card data in receipt text **on the device**, before anything is
/// sent to hestia. The server redacts again; this is defence in depth, with the
/// rule that a card number never leaves the phone.
///
/// Per line:
/// 0. **Protected spans** — amounts (`45,99`), dates (`2026-11-23`,
///    `23.11.2026`), times (`18:04`) and a labelled NIP — are hidden from the
///    rules below, so masking never eats a total, a date or the shop's NIP.
/// 1. **Luhn**: any window of 12–19 digits across digit groups (1–2 spaces or a
///    dash between groups, OCR look-alikes `O`→0 and `I`/`l`→1) that passes the
///    Luhn check, anywhere in the text.
/// 2. **Masked PANs** anywhere: `****1234`, `5351********1234`,
///    `XXXX XXXX XXXX 1234`, `**** 12 34`.
/// 3. **Terminal block**: on a line with a card label (`NR KARTY`, `KARTA`,
///    `CARD`, `VISA`, `AID`, `ARQC`, …) and the next ``labelWindow`` lines, any
///    run of ≥ ``blockMinDigits`` digits and any hex token (AID / ARQC).
enum PANRedactor {
    static let placeholder = "[REDACTED]"
    static let panLength = 12...19
    static let labelWindow = 3
    static let blockMinDigits = 8

    static func redact(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var windowLeft = 0
        for index in lines.indices {
            let line = lines[index]
            if hasCardLabel(line) { windowLeft = labelWindow + 1 }
            lines[index] = redactLine(line, inBlock: windowLeft > 0)
            if windowLeft > 0 { windowLeft -= 1 }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Line pipeline

    private static func redactLine(_ line: String, inBlock: Bool) -> String {
        let scan = masked(line, hiding: protectedRanges(in: line))
        var hits = luhnRanges(in: scan) + matches(maskedPAN, in: scan)
        if inBlock {
            hits += blockDigitRanges(in: scan)
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
        pattern: #"(?i)\bNIP\b[\s:.]*((?:\d[\s\-]?){9}\d)"#
    )

    private static func protectedRanges(in line: String) -> [NSRange] {
        var ranges = protectedPatterns.flatMap { matches($0, in: line) }
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
    /// spaces or a dash. A group must not touch a letter or digit outside it.
    private static let groupRun = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\d])[0-9][0-9OoIl]*(?:(?:  ?|-)[0-9OoIl]+)*(?![\p{L}\d])"#
    )
    private static let group = try! NSRegularExpression(pattern: #"[0-9OoIl]+"#)

    private static func luhnRanges(in line: String) -> [NSRange] {
        let ns = line as NSString
        var found: [NSRange] = []
        for run in groupRun.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let groups: [(range: NSRange, digits: String)] = group.matches(in: line, range: run.range).compactMap { match in
                guard let digits = ocrDigits(ns.substring(with: match.range)) else { return nil }
                return (match.range, digits)
            }
            // Longest window first, so a 16-digit PAN wins over a 12-digit prefix.
            var used = IndexSet()
            for length in stride(from: groups.count, through: 1, by: -1) {
                for start in 0...(groups.count - length) {
                    let window = start..<(start + length)
                    guard used.intersection(IndexSet(integersIn: window)).isEmpty else { continue }
                    let digits = groups[window].map(\.digits).joined()
                    guard panLength.contains(digits.count), luhnValid(digits) else { continue }
                    let first = groups[window.lowerBound].range, last = groups[window.upperBound - 1].range
                    found.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
                    used.insert(integersIn: window)
                }
            }
        }
        return found
    }

    /// Map OCR look-alikes to digits; nil if the group has no real digit (a
    /// word like `Il` is not a number).
    private static func ocrDigits(_ token: String) -> String? {
        guard token.contains(where: \.isASCIIDigit) else { return nil }
        return String(token.map { char -> Character in
            switch char {
            case "O", "o": "0"
            case "I", "l": "1"
            default: char
            }
        })
    }

    static func luhnValid(_ digits: String) -> Bool {
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else { return false }
        var sum = 0
        for (offset, char) in digits.reversed().enumerated() {
            var value = Int(String(char))!
            if offset % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
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

    private static func hasCardLabel(_ line: String) -> Bool {
        cardLabel.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// Digit runs (1–2 spaces or a dash between digits) not glued to a letter;
    /// a colon in front is fine (`NR KARTY:53511234`).
    private static let blockRun = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\d])\d(?:(?:  ?|-)?\d)*(?![\p{L}\d])"#
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
