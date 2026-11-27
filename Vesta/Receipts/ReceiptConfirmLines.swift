import Foundation

// The generator drops the required nullable fields from the verbatim anyOf definitions.
// ExplicitNullsMiddleware writes these keys on both confirm transports when nil.
struct ReceiptLineInputWire: Codable, Hashable, Sendable {
    enum LineKindPayload: String, Codable, Hashable, Sendable { case item, deposit, basketDiscount = "basket_discount", other }
    enum PtuCodePayload: String, Codable, Hashable, Sendable { case A, B, C, D, E, F, G }

    var discountAmount: String
    var grossLineTotal: String
    var lineKind: LineKindPayload
    var netLineTotal: String
    var ptuCode: PtuCodePayload? = nil
    var quantity: String
    var rawName: String
    var rawUnit: String? = nil
    var unitPriceRaw: String? = nil

    private enum CodingKeys: String, CodingKey {
        case discountAmount = "discount_amount", grossLineTotal = "gross_line_total", lineKind = "line_kind"
        case netLineTotal = "net_line_total", ptuCode = "ptu_code", quantity
        case rawName = "raw_name", rawUnit = "raw_unit", unitPriceRaw = "unit_price_raw"
    }
}

enum ReceiptTotalAdjustment: Equatable, Sendable {
    case remainder(amount: String)
    case summary

    var message: LocalizedStringResource {
        switch self {
        case .remainder: "Items were read partially — the receipt is confirmed using its total."
        case .summary: "The items could not be used — the receipt is confirmed using its total."
        }
    }
}

enum ReceiptConfirmLineError: Error, Equatable {
    case invalidForm
    case totalMismatch
    case redactedLinesEditBlocked

    var receiptError: ReceiptError {
        switch self {
        case .invalidForm: .rejected("incomplete_receipt")
        case .totalMismatch: .totalMismatch
        case .redactedLinesEditBlocked: .redactedLinesEditBlocked
        }
    }
}

struct ReceiptConfirmLinePlan: Equatable, Sendable {
    let lines: [Components.Schemas.BudgetReceiptLineInput]?
    let adjustment: ReceiptTotalAdjustment?
}

enum ReceiptConfirmLines {
    private typealias LineInput = Components.Schemas.BudgetReceiptLineInput

    private static let maxReceiptLines = 300
    static let maxNameLength = 128
    private static let posix = Locale(identifier: "en_US_POSIX")
    // Match the web input's trim and whitespace collapse, including non-breaking spaces.
    private static let whitespace = CharacterSet(charactersIn:
        "\t\n\u{000B}\u{000C}\r \u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}"
        + "\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"
    )

    static func normalizeDecimalInput(_ raw: String) -> String? {
        let normalized = trim(raw).replacingOccurrences(of: ",", with: ".")
        guard normalized.utf16.count <= 80,
              let match = normalized.wholeMatch(of: /(-?)([0-9]+)(?:\.([0-9]+))?/) else { return nil }
        let whole = String(match.2.drop(while: { $0 == "0" }))
        var fraction = String(match.3 ?? "")
        guard whole.count <= 9, fraction.count <= 4 else { return nil }
        while fraction.hasSuffix("0") { fraction.removeLast() }
        if whole.isEmpty && fraction.isEmpty { return "0" }
        return String(match.1) + (whole.isEmpty ? "0" : whole) + (fraction.isEmpty ? "" : "." + fraction)
    }

    static func normalizeConfirmMoney(_ raw: String) -> String? {
        guard let amount = normalizeDecimalInput(raw) else { return nil }
        let digits = amount.compactMap(\.wholeNumberValue)
        guard digits.count < 12 else { return nil }
        if digits.count == 11 {
            let weights = [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]
            let checksum = zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 }
            guard (10 - checksum % 10) % 10 != digits[10] else { return nil }
        }
        return amount
    }

    static func normalizeConfirmTotal(_ raw: String) -> String? {
        guard let amount = normalizeConfirmMoney(raw), amount != "0", !amount.hasPrefix("-") else { return nil }
        return amount
    }

    static func computeLinesDelta(_ netAmounts: [String], total: String) -> Decimal? {
        guard let normalizedTotal = normalizeDecimalInput(total), let total = decimal(normalizedTotal) else { return nil }
        var sum: Decimal = 0
        for amount in netAmounts {
            guard let normalized = normalizeDecimalInput(amount), let net = decimal(normalized) else { return nil }
            sum += net
        }
        return sum - total
    }

    static func validConfirmLineText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .format, .surrogate: false
            default: (scalar.value >= 32 || [9, 10, 13].contains(scalar.value)) && scalar.value != 127
            }
        }
    }

    static func normalizeConfirmName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func validConfirmLineName(_ name: String) -> Bool {
        guard name.unicodeScalars.count <= maxNameLength else { return false }
        let nameKey = trim(String(name.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            $0.properties.generalCategory != .nonspacingMark
        }))
        return !nameKey.isEmpty && nameKey.unicodeScalars.count <= maxNameLength
    }

    static func cleanConfirmLine(_ input: ReceiptLine) throws(ReceiptConfirmLineError) -> Components.Schemas.BudgetReceiptLineInput {
        let ptuCode = input.ptuCode.flatMap { LineInput.PtuCodePayload(rawValue: $0.rawValue) }
        guard let kind = LineInput.LineKindPayload(rawValue: input.lineKind.rawValue),
              input.ptuCode == nil || ptuCode != nil else { throw .invalidForm }

        let name = cleanText(input.rawName)
        let unit = input.rawUnit.map(cleanText).flatMap(nonempty)
        let unitPrice = input.unitPriceRaw.flatMap(normalizeConfirmMoney)
        guard validConfirmLineName(name),
              validConfirmLineText(input.rawName), (unit?.unicodeScalars.count ?? 0) <= 16,
              input.rawUnit.map(validConfirmLineText) ?? true,
              let quantity = normalizeConfirmMoney(input.quantity), input.unitPriceRaw == nil || unitPrice != nil
        else { throw .invalidForm }

        // hestia redacts either field on its own, and rejects identifiers split across both fields.
        let nameDigits = countDigits(name)
        let unitDigits = unit.map(countDigits) ?? 0
        if nameDigits < 12, unitDigits < 12, nameDigits + unitDigits >= 12 { throw .invalidForm }

        guard let gross = normalizeConfirmMoney(input.grossLineTotal),
              let discount = normalizeConfirmMoney(input.discountAmount),
              let net = normalizeConfirmMoney(input.netLineTotal),
              let grossValue = decimal(gross), let discountValue = decimal(discount),
              let netValue = decimal(net) else { throw .invalidForm }
        guard grossValue - discountValue == netValue else { throw .totalMismatch }

        let validSigns = switch kind {
        case .item: grossValue >= 0 && discountValue >= 0 && netValue >= 0
        case .deposit: grossValue != 0 && discountValue == 0
        case .basketDiscount: grossValue < 0 && discountValue == 0
        case .other: discountValue == 0
        }
        guard validSigns else { throw .totalMismatch }

        return .init(discountAmount: discount, grossLineTotal: gross, lineKind: kind, netLineTotal: net,
                     ptuCode: ptuCode, quantity: quantity,
                     rawName: name, rawUnit: unit, unitPriceRaw: unitPrice)
    }

    static func receiptTotalAdjustment(documentKind: BudgetReceiptSummaryWire.DocumentKindPayload?,
                                       originalLines: [ReceiptLine], draftLines: [ReceiptLine],
                                       total: String) -> ReceiptTotalAdjustment? {
        guard let total = normalizeConfirmTotal(total) else { return nil }
        return (try? planConfirmLines(documentKind: documentKind, originalLines: originalLines,
                                      draftLines: draftLines, total: total))?.adjustment
    }

    static func receiptHasRedactedLines(_ lines: [ReceiptLine]) -> Bool {
        func isRedacted(_ text: String) -> Bool {
            isRedactedValue(trim(text).precomposedStringWithCanonicalMapping)
        }
        return lines.contains { isRedacted($0.rawName) || ($0.rawUnit.map(isRedacted) ?? false) }
    }

    static func haveConfirmLinesChanged(_ original: [ReceiptLine], _ draft: [ReceiptLine]) -> Bool {
        guard original.count == draft.count else { return true }
        return zip(original, draft).contains { old, new in
            old.lineKind != new.lineKind
                || !trim(old.rawName).utf8.elementsEqual(trim(new.rawName).utf8)
                || old.ptuCode != new.ptuCode
                || !trim(old.rawUnit ?? "").utf8.elementsEqual(trim(new.rawUnit ?? "").utf8)
                || normalizeDecimalInput(old.quantity) != normalizeDecimalInput(new.quantity)
                || old.unitPriceRaw.flatMap(normalizeDecimalInput) != new.unitPriceRaw.flatMap(normalizeDecimalInput)
                || normalizeDecimalInput(old.grossLineTotal) != normalizeDecimalInput(new.grossLineTotal)
                || normalizeDecimalInput(old.discountAmount) != normalizeDecimalInput(new.discountAmount)
                || normalizeDecimalInput(old.netLineTotal) != normalizeDecimalInput(new.netLineTotal)
        }
    }

    /// `total` is the positive, normalized amount that will be sent with the request.
    static func planConfirmLines(documentKind: BudgetReceiptSummaryWire.DocumentKindPayload?,
                                 originalLines: [ReceiptLine], draftLines: [ReceiptLine],
                                 total: String) throws(ReceiptConfirmLineError) -> ReceiptConfirmLinePlan {
        let allowsFallback = documentKind != .paymentConfirmation && documentKind != .unknown
        let hasRedactedLines = receiptHasRedactedLines(originalLines) || receiptHasRedactedLines(draftLines)
        let changed = haveConfirmLinesChanged(originalLines, draftLines)
        if hasRedactedLines && changed { throw .redactedLinesEditBlocked }

        let summary = ReceiptConfirmLinePlan(lines: [synthesizeTotalLine("Tylko suma", amount: total, kind: .other)],
                                             adjustment: .summary)
        guard draftLines.count <= maxReceiptLines else {
            if allowsFallback { return summary }
            throw .invalidForm
        }

        var cleanLines: [LineInput] = []
        for line in draftLines {
            do {
                cleanLines.append(try cleanConfirmLine(line))
            } catch {
                if allowsFallback { return summary }
                throw error
            }
        }

        if documentKind == .invoice, originalLines.isEmpty, cleanLines.isEmpty {
            return .init(lines: nil, adjustment: nil)
        }
        let delta = computeLinesDelta(cleanLines.map(\.netLineTotal), total: total)
        if delta == 0 {
            return .init(lines: changed && !hasRedactedLines ? cleanLines : nil, adjustment: nil)
        }
        guard allowsFallback else { throw .totalMismatch }
        if !hasRedactedLines, let delta, delta < 0, cleanLines.count < maxReceiptLines,
           let formatted = formatPositiveRemainder(-delta), let remainder = normalizeConfirmMoney(formatted) {
            cleanLines.append(synthesizeTotalLine("Pozostałe / nierozpoznane pozycje", amount: remainder, kind: .item))
            return .init(lines: cleanLines, adjustment: .remainder(amount: remainder))
        }
        return summary
    }

    /// An empty invoice needs a line for the server's sum check, without an adjustment note.
    static func linesForRequest(
        _ plan: ReceiptConfirmLinePlan, documentKind: BudgetReceiptSummaryWire.DocumentKindPayload?,
        originalLines: [ReceiptLine], draftLines: [ReceiptLine], invoiceNumber: String?,
        draftShopName: String, storedShopName: String?, total: String
    ) -> [Components.Schemas.BudgetReceiptLineInput]? {
        guard plan.lines == nil, documentKind == .invoice, originalLines.isEmpty, draftLines.isEmpty else {
            return plan.lines
        }
        return [synthesizeInvoiceSummaryLine(invoiceNumber: invoiceNumber, draftShopName: draftShopName,
                                             storedShopName: storedShopName, normalizedTotal: total)]
    }

    static func synthesizeInvoiceSummaryLine(
        invoiceNumber: String?, draftShopName: String, storedShopName: String?, normalizedTotal: String,
        summaryFallbackName: String = "Document"
    ) -> Components.Schemas.BudgetReceiptLineInput {
        func usableName(_ text: String) -> String? {
            let name = normalizeConfirmName(text)
            guard !isRedactedValue(name), validConfirmLineText(text), validConfirmLineName(name) else { return nil }
            return name
        }
        func usableNameAfterRedaction(_ text: String) -> String? {
            usableName(PANRedactor.redact(text))
        }
        let name = invoiceNumber.flatMap(usableNameAfterRedaction) ?? usableNameAfterRedaction(draftShopName)
            ?? storedShopName.flatMap(usableNameAfterRedaction) ?? usableName(summaryFallbackName) ?? "Document"
        return synthesizeTotalLine(name, amount: normalizedTotal, kind: .other)
    }

    private static func synthesizeTotalLine(_ name: String, amount: String, kind: LineInput.LineKindPayload) -> LineInput {
        .init(discountAmount: "0", grossLineTotal: amount, lineKind: kind, netLineTotal: amount,
              quantity: "1", rawName: name)
    }

    private static func formatPositiveRemainder(_ amount: Decimal) -> String? {
        guard amount < 1_000_000_000 else { return nil }
        // All inputs have at most four fractional digits. Scaling stays exact and fits in Int64.
        let scale: Int64 = 10_000
        let units = NSDecimalNumber(decimal: amount * Decimal(scale)).int64Value
        let whole = String(units / scale)
        var fraction = units % scale
        guard fraction != 0 else { return whole }
        var formatted = whole + "."
        var place = scale / 10
        while fraction != 0 {
            formatted += String(fraction / place)
            fraction %= place
            place /= 10
        }
        return formatted
    }

    private static func isRedactedValue(_ text: String) -> Bool {
        text == "[usunięto]" || text == PANRedactor.placeholder
    }

    private static func decimal(_ normalized: String) -> Decimal? { Decimal(string: normalized, locale: posix) }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: whitespace) }

    private static func nonempty(_ text: String) -> String? { text.isEmpty ? nil : text }

    private static func cleanText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.components(separatedBy: whitespace)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func countDigits(_ text: String) -> Int {
        text.precomposedStringWithCompatibilityMapping.unicodeScalars.count {
            $0.properties.generalCategory == .decimalNumber
        }
    }
}
