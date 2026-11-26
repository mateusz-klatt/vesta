import Foundation

// Keep the nullable fields the generator drops from the verbatim confirm schema.
struct ReceiptConfirmRequestWire: Codable, Hashable, Sendable {
    enum PaymentMethodPayload: String, Codable, Hashable, Sendable { case card, blik, cash, mixed, unknown }
    enum ReceiptKindPayload: String, Codable, Hashable, Sendable { case purchase, refund }

    var currency: String
    var expectedVersion: Int
    var lines: [Components.Schemas.BudgetReceiptLineInput]? = nil
    var link: Components.Schemas.BudgetReceiptLinkRequest? = nil
    var paymentMethod: PaymentMethodPayload
    var rawNip: String? = nil
    var rawShopName: String? = nil
    var receiptDate: String
    var receiptId: String
    var receiptKind: ReceiptKindPayload
    var receiptTime: String? = nil
    var totalAmount: String

    private enum CodingKeys: String, CodingKey {
        case currency, expectedVersion = "expected_version", lines, link, paymentMethod = "payment_method"
        case rawNip = "raw_nip", rawShopName = "raw_shop_name", receiptDate = "receipt_date", receiptId = "receipt_id"
        case receiptKind = "receipt_kind", receiptTime = "receipt_time", totalAmount = "total_amount"
    }
}

struct BudgetReceiptListRequestWire: Codable, Hashable, Sendable {
    var cursor: String?
    var documentKind: String?
    var evidence: String
    var limit: Int
    var linked: Bool?
    var month: String?
    var status: String?

    init(cursor: String? = nil, documentKind: String? = nil, evidence: String = "exclude", limit: Int = 200,
         linked: Bool? = nil, month: String? = nil, status: String? = "imported") {
        self.cursor = cursor
        self.documentKind = documentKind
        self.evidence = evidence
        self.limit = limit
        self.linked = linked
        self.month = month
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case cursor, documentKind = "document_kind", evidence, limit, linked, month, status
    }
}

struct BudgetReceiptListResultWire: Codable, Hashable, Sendable {
    var receipts: [Components.Schemas.BudgetReceiptSummary]
    var nextCursor: String?

    init(receipts: [Components.Schemas.BudgetReceiptSummary], nextCursor: String? = nil) {
        self.receipts = receipts
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey { case receipts, nextCursor = "next_cursor" }

    init(from decoder: any Decoder) throws {
        var values = try decoder.container(keyedBy: CodingKeys.self)
        receipts = try values.decode([Components.Schemas.BudgetReceiptSummary].self, forKey: .receipts)
        nextCursor = try values.decode(String?.self, forKey: .nextCursor)
    }
}

struct BudgetReceiptDetailResultWire: Codable, Hashable, Sendable {
    var receipt: Components.Schemas.BudgetReceiptDetail
    var candidates: [Components.Schemas.BudgetReceiptCandidate]?

    init(receipt: Components.Schemas.BudgetReceiptDetail, candidates: [Components.Schemas.BudgetReceiptCandidate]? = nil) {
        self.receipt = receipt
        self.candidates = candidates
    }

    private enum CodingKeys: String, CodingKey { case receipt, candidates }

    init(from decoder: any Decoder) throws {
        var values = try decoder.container(keyedBy: CodingKeys.self)
        receipt = try values.decode(Components.Schemas.BudgetReceiptDetail.self, forKey: .receipt)
        candidates = try values.decodeIfPresent([Components.Schemas.BudgetReceiptCandidate].self, forKey: .candidates)
    }
}

struct ReceiptCandidateWire: Codable, Hashable, Sendable {
    enum CreditDebitIndicatorPayload: String, Codable, Hashable, Sendable { case DBIT, CRDT }
    enum MatchStrengthPayload: String, Codable, Hashable, Sendable { case nip, distinctive, generic, none }

    var accountId: String
    var amount: String
    var bookingDate: String?
    var candidateToken: String
    var creditDebitIndicator: CreditDebitIndicatorPayload
    var currency: String
    var dateDistance: Int
    var entryReference: String
    var matchStrength: MatchStrengthPayload
    var merchantTokenHit: Bool
    var transactionDate: String?
    var valueDate: String?

    init(accountId: String, entryReference: String, amount: String = "12.34", currency: String = "PLN",
         creditDebitIndicator: CreditDebitIndicatorPayload = .DBIT, transactionDate: String? = "2026-11-22",
         bookingDate: String? = "2026-11-22", valueDate: String? = nil, merchantTokenHit: Bool = true,
         matchStrength: MatchStrengthPayload = .none, dateDistance: Int = 0, candidateToken: String = "candidate-token") {
        self.accountId = accountId
        self.amount = amount
        self.bookingDate = bookingDate
        self.candidateToken = candidateToken
        self.creditDebitIndicator = creditDebitIndicator
        self.currency = currency
        self.dateDistance = dateDistance
        self.entryReference = entryReference
        self.matchStrength = matchStrength
        self.merchantTokenHit = merchantTokenHit
        self.transactionDate = transactionDate
        self.valueDate = valueDate
    }

    private enum CodingKeys: String, CodingKey {
        case accountId = "account_id", amount, bookingDate = "booking_date", candidateToken = "candidate_token"
        case creditDebitIndicator = "credit_debit_indicator", currency, dateDistance = "date_distance"
        case entryReference = "entry_reference", matchStrength = "match_strength"
        case merchantTokenHit = "merchant_token_hit", transactionDate = "transaction_date", valueDate = "value_date"
    }

    init(from decoder: any Decoder) throws {
        var values = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try values.decode(String.self, forKey: .accountId)
        amount = try values.decode(String.self, forKey: .amount)
        bookingDate = try values.decodeIfPresent(String.self, forKey: .bookingDate)
        candidateToken = try values.decode(String.self, forKey: .candidateToken)
        creditDebitIndicator = try values.decode(CreditDebitIndicatorPayload.self, forKey: .creditDebitIndicator)
        currency = try values.decode(String.self, forKey: .currency)
        dateDistance = try values.decode(Int.self, forKey: .dateDistance)
        entryReference = try values.decode(String.self, forKey: .entryReference)
        matchStrength = try values.decodeIfPresent(MatchStrengthPayload.self, forKey: .matchStrength) ?? .none
        merchantTokenHit = try values.decode(Bool.self, forKey: .merchantTokenHit)
        transactionDate = try values.decodeIfPresent(String.self, forKey: .transactionDate)
        valueDate = try values.decodeIfPresent(String.self, forKey: .valueDate)
    }
}

struct ReceiptLineWire: Codable, Hashable, Sendable {
    enum LineKindPayload: String, Codable, Hashable, Sendable { case item, deposit, basketDiscount = "basket_discount", other }
    enum PtuCodePayload: String, Codable, Hashable, Sendable { case A, B, C, D, E, F, G }

    var discountAmount: String
    var grossLineTotal: String
    var lineKind: LineKindPayload
    var lineNo: Int
    var netLineTotal: String
    var ptuCode: PtuCodePayload?
    var quantity: String
    var rawName: String
    var rawNameKey: String
    var rawUnit: String?
    var unitPriceRaw: String?

    init(discountAmount: String = "0", grossLineTotal: String = "12.34", lineKind: LineKindPayload = .item,
         lineNo: Int = 1, netLineTotal: String = "12.34", ptuCode: PtuCodePayload? = nil,
         quantity: String = "1", rawName: String = "Item", rawNameKey: String = "item",
         rawUnit: String? = nil, unitPriceRaw: String? = "12.34") {
        self.discountAmount = discountAmount
        self.grossLineTotal = grossLineTotal
        self.lineKind = lineKind
        self.lineNo = lineNo
        self.netLineTotal = netLineTotal
        self.ptuCode = ptuCode
        self.quantity = quantity
        self.rawName = rawName
        self.rawNameKey = rawNameKey
        self.rawUnit = rawUnit
        self.unitPriceRaw = unitPriceRaw
    }

    private enum CodingKeys: String, CodingKey {
        case discountAmount = "discount_amount", grossLineTotal = "gross_line_total", lineKind = "line_kind"
        case lineNo = "line_no", netLineTotal = "net_line_total", ptuCode = "ptu_code", quantity
        case rawName = "raw_name", rawNameKey = "raw_name_key", rawUnit = "raw_unit", unitPriceRaw = "unit_price_raw"
    }

    init(from decoder: any Decoder) throws {
        var values = try decoder.container(keyedBy: CodingKeys.self)
        discountAmount = try values.decode(String.self, forKey: .discountAmount)
        grossLineTotal = try values.decode(String.self, forKey: .grossLineTotal)
        lineKind = try values.decode(LineKindPayload.self, forKey: .lineKind)
        lineNo = try values.decode(Int.self, forKey: .lineNo)
        netLineTotal = try values.decode(String.self, forKey: .netLineTotal)
        ptuCode = try values.decodeIfPresent(PtuCodePayload.self, forKey: .ptuCode)
        quantity = try values.decode(String.self, forKey: .quantity)
        rawName = try values.decode(String.self, forKey: .rawName)
        rawNameKey = try values.decode(String.self, forKey: .rawNameKey)
        rawUnit = try values.decodeIfPresent(String.self, forKey: .rawUnit)
        unitPriceRaw = try values.decodeIfPresent(String.self, forKey: .unitPriceRaw)
    }
}

struct BudgetReceiptSummaryWire: Codable, Hashable, Sendable, Identifiable {
    var id: String { receiptId }
    enum ReceiptKindPayload: String, Codable, Hashable, Sendable { case purchase, refund }
    enum SourceKindPayload: String, Codable, Hashable, Sendable {
        case liveText = "live_text", localOcr = "local_ocr", cloudAi = "cloud_ai"
        case paste, photo, email, attachment
    }
    enum StatusPayload: String, Codable, Hashable, Sendable { case draft, confirmed, needsReview = "needs_review", imported }
    enum DocumentKindPayload: String, Codable, Hashable, Sendable { case receipt, invoice, paymentConfirmation = "payment_confirmation" }
    enum GatewayStatusPayload: String, Codable, Hashable, Sendable { case registered, paid }

    var chainKey: String?
    var createdAt: Double
    var currency: String?
    var documentKind: DocumentKindPayload?
    var dueDate: String?
    var evidenceForReceiptId: String?
    var feeAmount: String?
    var forwardedManually: Bool
    var forwardedSenderDomain: String?
    var gateway: String?
    var gatewayStatus: GatewayStatusPayload?
    var hasDocument: Bool?
    var imageAvailable: Bool
    var imageExpiresAt: Double?
    var importExpiresAt: Double?
    var invoiceNumber: String?
    var linked: Bool
    var linkedAccountId: String?
    var linkedEntryRef: String?
    var mathDelta: String?
    var payeeHost: String?
    var paymentMethod: String?
    var rawNip: String?
    var rawShopName: String?
    var rawTextExpiresAt: Double?
    var receiptDate: String?
    var receiptId: String
    var receiptKind: ReceiptKindPayload
    var receiptTime: String?
    var shopId: String?
    var sourceKind: SourceKindPayload
    var status: StatusPayload
    var totalAmount: String?
    var updatedAt: Double
    var version: Int

    init(receiptId: String, rawShopName: String? = nil, chainKey: String? = nil, version: Int = 1,
         receiptDate: String? = "2026-11-22", totalAmount: String? = "12.34", currency: String? = "PLN",
         receiptKind: ReceiptKindPayload = .purchase, status: StatusPayload = .imported,
         sourceKind: SourceKindPayload = .email, createdAt: Double = 0, updatedAt: Double = 0,
         rawNip: String? = nil, receiptTime: String? = nil, paymentMethod: String? = "card",
         linked: Bool = false, linkedAccountId: String? = nil, linkedEntryRef: String? = nil,
         imageAvailable: Bool = false, imageExpiresAt: Double? = nil, rawTextExpiresAt: Double? = nil,
         mathDelta: String? = nil, shopId: String? = nil, documentKind: DocumentKindPayload? = nil,
         dueDate: String? = nil, evidenceForReceiptId: String? = nil, feeAmount: String? = nil,
         forwardedManually: Bool = false, forwardedSenderDomain: String? = nil, gateway: String? = nil,
         gatewayStatus: GatewayStatusPayload? = nil, hasDocument: Bool? = nil, importExpiresAt: Double? = nil,
         invoiceNumber: String? = nil, payeeHost: String? = nil) {
        self.chainKey = chainKey
        self.createdAt = createdAt
        self.currency = currency
        self.documentKind = documentKind
        self.dueDate = dueDate
        self.evidenceForReceiptId = evidenceForReceiptId
        self.feeAmount = feeAmount
        self.forwardedManually = forwardedManually
        self.forwardedSenderDomain = forwardedSenderDomain
        self.gateway = gateway
        self.gatewayStatus = gatewayStatus
        self.hasDocument = hasDocument
        self.imageAvailable = imageAvailable
        self.imageExpiresAt = imageExpiresAt
        self.importExpiresAt = importExpiresAt
        self.invoiceNumber = invoiceNumber
        self.linked = linked
        self.linkedAccountId = linkedAccountId
        self.linkedEntryRef = linkedEntryRef
        self.mathDelta = mathDelta
        self.payeeHost = payeeHost
        self.paymentMethod = paymentMethod
        self.rawNip = rawNip
        self.rawShopName = rawShopName
        self.rawTextExpiresAt = rawTextExpiresAt
        self.receiptDate = receiptDate
        self.receiptId = receiptId
        self.receiptKind = receiptKind
        self.receiptTime = receiptTime
        self.shopId = shopId
        self.sourceKind = sourceKind
        self.status = status
        self.totalAmount = totalAmount
        self.updatedAt = updatedAt
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case chainKey = "chain_key", createdAt = "created_at", currency, documentKind = "document_kind"
        case dueDate = "due_date", evidenceForReceiptId = "evidence_for_receipt_id", feeAmount = "fee_amount"
        case forwardedManually = "forwarded_manually", forwardedSenderDomain = "forwarded_sender_domain"
        case gateway, gatewayStatus = "gateway_status", hasDocument = "has_document", imageAvailable = "image_available"
        case imageExpiresAt = "image_expires_at", importExpiresAt = "import_expires_at", invoiceNumber = "invoice_number"
        case linked, linkedAccountId = "linked_account_id", linkedEntryRef = "linked_entry_ref", mathDelta = "math_delta"
        case payeeHost = "payee_host", paymentMethod = "payment_method", rawNip = "raw_nip", rawShopName = "raw_shop_name"
        case rawTextExpiresAt = "raw_text_expires_at", receiptDate = "receipt_date", receiptId = "receipt_id"
        case receiptKind = "receipt_kind", receiptTime = "receipt_time", shopId = "shop_id", sourceKind = "source_kind"
        case status, totalAmount = "total_amount", updatedAt = "updated_at", version
    }

    init(from decoder: any Decoder) throws {
        try self.init(from: decoder, allowsOmittedNullableKeys: false)
    }

    init(from decoder: any Decoder, allowsOmittedNullableKeys: Bool) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func nullable<T: Decodable>(_ type: T.Type, _ key: CodingKeys) throws -> T? {
            if allowsOmittedNullableKeys {
                return try values.decodeIfPresent(type, forKey: key)
            }
            return try values.decode(T?.self, forKey: key)
        }
        chainKey = try nullable(String.self, .chainKey)
        createdAt = try values.decode(Double.self, forKey: .createdAt)
        currency = try nullable(String.self, .currency)
        documentKind = try values.decodeIfPresent(DocumentKindPayload.self, forKey: .documentKind)
        dueDate = try values.decodeIfPresent(String.self, forKey: .dueDate)
        evidenceForReceiptId = try values.decodeIfPresent(String.self, forKey: .evidenceForReceiptId)
        feeAmount = try values.decodeIfPresent(String.self, forKey: .feeAmount)
        forwardedManually = try values.decodeIfPresent(Bool.self, forKey: .forwardedManually) ?? false
        forwardedSenderDomain = try values.decodeIfPresent(String.self, forKey: .forwardedSenderDomain)
        gateway = try values.decodeIfPresent(String.self, forKey: .gateway)
        gatewayStatus = try values.decodeIfPresent(GatewayStatusPayload.self, forKey: .gatewayStatus)
        hasDocument = try values.decodeIfPresent(Bool.self, forKey: .hasDocument)
        imageAvailable = try values.decode(Bool.self, forKey: .imageAvailable)
        imageExpiresAt = try nullable(Double.self, .imageExpiresAt)
        importExpiresAt = try values.decodeIfPresent(Double.self, forKey: .importExpiresAt)
        invoiceNumber = try values.decodeIfPresent(String.self, forKey: .invoiceNumber)
        linked = try values.decode(Bool.self, forKey: .linked)
        linkedAccountId = try nullable(String.self, .linkedAccountId)
        linkedEntryRef = try nullable(String.self, .linkedEntryRef)
        mathDelta = try nullable(String.self, .mathDelta)
        payeeHost = try values.decodeIfPresent(String.self, forKey: .payeeHost)
        paymentMethod = try nullable(String.self, .paymentMethod)
        rawNip = try nullable(String.self, .rawNip)
        rawShopName = try nullable(String.self, .rawShopName)
        rawTextExpiresAt = try nullable(Double.self, .rawTextExpiresAt)
        receiptDate = try nullable(String.self, .receiptDate)
        receiptId = try values.decode(String.self, forKey: .receiptId)
        receiptKind = try values.decode(ReceiptKindPayload.self, forKey: .receiptKind)
        receiptTime = try nullable(String.self, .receiptTime)
        shopId = try nullable(String.self, .shopId)
        sourceKind = try values.decode(SourceKindPayload.self, forKey: .sourceKind)
        status = try values.decode(StatusPayload.self, forKey: .status)
        totalAmount = try nullable(String.self, .totalAmount)
        updatedAt = try values.decode(Double.self, forKey: .updatedAt)
        version = try values.decode(Int.self, forKey: .version)
    }
}

struct ReceiptDetailWire: Codable, Hashable, Sendable {
    var summary: BudgetReceiptSummaryWire
    var lines: [Components.Schemas.BudgetReceiptLine]
    var paymentEvidence: [Components.Schemas.BudgetReceiptPaymentEvidence]

    init(summary: BudgetReceiptSummaryWire, lines: [Components.Schemas.BudgetReceiptLine],
         paymentEvidence: [Components.Schemas.BudgetReceiptPaymentEvidence] = []) {
        self.summary = summary
        self.lines = lines
        self.paymentEvidence = paymentEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case lines, paymentEvidence = "payment_evidence"
    }

    init(from decoder: any Decoder) throws {
        // Older scan/confirm responses may omit nullable fields from the shared summary.
        summary = try BudgetReceiptSummaryWire(from: decoder, allowsOmittedNullableKeys: true)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lines = try values.decode([Components.Schemas.BudgetReceiptLine].self, forKey: .lines)
        paymentEvidence = try values.decodeIfPresent(
            [Components.Schemas.BudgetReceiptPaymentEvidence].self, forKey: .paymentEvidence
        ) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        try summary.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(lines, forKey: .lines)
        try values.encode(paymentEvidence, forKey: .paymentEvidence)
    }
}

struct ReceiptPaymentEvidenceWire: Codable, Hashable, Sendable {
    enum GatewayStatusPayload: String, Codable, Hashable, Sendable { case registered, paid }

    var feeAmount: String?
    var gateway: String?
    var gatewayStatus: GatewayStatusPayload?
    var receiptDate: String?
    var receiptId: String
    var totalAmount: String?

    private enum CodingKeys: String, CodingKey {
        case feeAmount = "fee_amount", gateway, gatewayStatus = "gateway_status"
        case receiptDate = "receipt_date", receiptId = "receipt_id", totalAmount = "total_amount"
    }

    init(from decoder: any Decoder) throws {
        var values = try decoder.container(keyedBy: CodingKeys.self)
        feeAmount = try values.decode(String?.self, forKey: .feeAmount)
        gateway = try values.decode(String?.self, forKey: .gateway)
        gatewayStatus = try values.decode(GatewayStatusPayload?.self, forKey: .gatewayStatus)
        receiptDate = try values.decode(String?.self, forKey: .receiptDate)
        receiptId = try values.decode(String.self, forKey: .receiptId)
        totalAmount = try values.decode(String?.self, forKey: .totalAmount)
    }
}
