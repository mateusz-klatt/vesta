import Foundation

/// Masks payment-card data in receipt text **on the device**, before anything is
/// sent to hestia. The server redacts again, so this is defence in depth: the
/// rule is that a card number never leaves the phone.
///
/// Three rules:
/// 1. Any 12–19 digit run (single spaces or dashes allowed between digits) that
///    passes the Luhn check, anywhere in the text.
/// 2. Masked PANs anywhere (`****1234`, `5351********1234`, `XXXX XXXX XXXX 1234`).
/// 3. Within a terminal block — the line carrying a card label (`NR KARTY`,
///    `KARTA`, `CARD`, `AID`) and the next ``labelWindow`` lines — long digit
///    runs and hex AIDs. Amounts (`45,99`), times and dates are left alone so
///    the payment and total lines still parse.
enum PANRedactor {
    static let placeholder = "[REDACTED]"
    static let panLength = 12...19
    static let labelWindow = 3

    static func redact(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var windowLeft = 0
        for index in lines.indices {
            var line = redactLuhnRuns(lines[index])
            line = replace(maskedPAN, in: line)
            if hasCardLabel(line) { windowLeft = labelWindow + 1 }
            if windowLeft > 0 {
                line = redactTerminalBlock(line)
                windowLeft -= 1
            }
            lines[index] = line
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Rule 1: Luhn-valid digit runs

    /// A digit run, optionally grouped by single spaces or dashes into groups of
    /// at least 4 (`4111 1111 1111 1111`, Amex `3782 822463 10005`). Requiring
    /// 4-digit groups keeps dates (`2026-11-23`) from fusing with nearby numbers.
    private static let digitRun = try! NSRegularExpression(pattern: #"(?<!\d)\d{4,}(?:[ \-]\d{4,})*(?!\d)"#)

    private static func redactLuhnRuns(_ line: String) -> String {
        let ns = line as NSString
        var result = line
        // Walk matches back to front so earlier ranges stay valid while replacing.
        for match in digitRun.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
            let run = ns.substring(with: match.range)
            let digits = run.filter(\.isASCIIDigit)
            guard panLength.contains(digits.count), luhnValid(digits) else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: placeholder)
        }
        return result
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

    // MARK: - Rule 2: masked PANs

    /// A run of ≥4 mask characters next to digits, e.g. `****1234`,
    /// `5351********1234`, `XXXX XXXX XXXX 1234`, `•••• 1234`.
    private static let maskedPAN = try! NSRegularExpression(
        pattern: #"(?:\d{0,6}[ \-]?)(?:[*xX•#][ \-]?){4,}\d{2,4}"#
    )

    // MARK: - Rule 3: terminal block near a card label

    private static let cardLabel = try! NSRegularExpression(
        pattern: #"(?i)\b(?:NR\s*KARTY|KARTA|CARD|AID)\b"#
    )

    private static func hasCardLabel(_ line: String) -> Bool {
        cardLabel.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// Long digit runs (≥ ``blockMinDigits``, same grouping as rule 1) that
    /// aren't glued to a letter, an amount (`1234,56`) or a clock (`21:37`). An
    /// AID like `A0000000041010` starts with a letter and is left to `hexAID`.
    private static let blockDigits = try! NSRegularExpression(
        pattern: #"(?<![\d\p{L},.:])\d{4,}(?:[ \-]\d{4,})*(?![\d\p{L}]|[,.:]\d)"#
    )
    static let blockMinDigits = 8
    private static let hexAID = try! NSRegularExpression(pattern: #"\b[A-F0-9]{10,32}\b"#)

    private static func redactTerminalBlock(_ line: String) -> String {
        var result = line
        let digitsNS = line as NSString
        for match in blockDigits.matches(in: line, range: NSRange(location: 0, length: digitsNS.length)).reversed() {
            let digits = digitsNS.substring(with: match.range).filter(\.isASCIIDigit)
            guard digits.count >= blockMinDigits else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: placeholder)
        }
        // Only treat hex as an AID if it actually contains a letter; pure digits
        // were handled above with the amount-safe rule.
        let ns = result as NSString
        for match in hexAID.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
            let token = ns.substring(with: match.range)
            guard token.contains(where: \.isLetter) else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: placeholder)
        }
        return result
    }

    private static func replace(_ regex: NSRegularExpression, in line: String) -> String {
        regex.stringByReplacingMatches(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length),
            withTemplate: NSRegularExpression.escapedTemplate(for: placeholder)
        )
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
