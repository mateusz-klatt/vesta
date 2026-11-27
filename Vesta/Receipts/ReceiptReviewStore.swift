import Foundation
import Observation

typealias ImportedReceiptSummary = Components.Schemas.BudgetReceiptSummary

struct ReceiptMerchantGroup: Equatable, Identifiable {
    let id: String
    let name: String?
    var receipts: [ImportedReceiptSummary]

    var canConfirmWithoutLinking: Bool { id != "unknown" && receipts.contains { !$0.linked } }

    static func group(_ receipts: [ImportedReceiptSummary]) -> [ReceiptMerchantGroup] {
        var groups: [String: ReceiptMerchantGroup] = [:]
        var order: [String] = []
        for receipt in receipts {
            let shop = receipt.rawShopName.map(ReceiptForm.matchKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let chain = receipt.chainKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id: String
            if let chain, !chain.isEmpty {
                id = "chain:\(chain)"
            } else if let nip = receipt.rawNip, PANRedactor.validNIP(nip) {
                id = "nip:\(nip)"
            } else if let shop, !shop.isEmpty {
                id = "shop:\(shop.lowercased())"
            } else {
                id = "unknown"
            }
            if groups[id] == nil {
                groups[id] = ReceiptMerchantGroup(id: id, name: shop?.isEmpty == false ? shop : nil, receipts: [])
                order.append(id)
            }
            groups[id]?.receipts.append(receipt)
        }
        return order.compactMap { groups[$0] }
    }
}

struct ReceiptConfirmationOutcome: Equatable, Identifiable {
    enum Status: Equatable { case confirmed, alreadySubmitted, failed }

    let receipt: ImportedReceiptSummary
    let status: Status
    let code: String
    let error: ReceiptError?
    let adjustment: ReceiptTotalAdjustment?

    var id: String { receipt.receiptId }

    static func success(
        _ receipt: ImportedReceiptSummary, alreadySubmitted: Bool = false, adjustment: ReceiptTotalAdjustment? = nil
    ) -> Self {
        .init(receipt: receipt, status: alreadySubmitted ? .alreadySubmitted : .confirmed,
              code: alreadySubmitted ? "already_submitted" : "confirmed", error: nil, adjustment: adjustment)
    }

    static func failure(_ receipt: ImportedReceiptSummary, error: ReceiptError) -> Self {
        .init(receipt: receipt, status: .failed, code: error.reviewCode, error: error, adjustment: nil)
    }
}

@MainActor
@Observable
final class ReceiptReviewStore {
    enum State: Equatable { case loading, loaded, unauthorized, forbidden, failed }

    private let api: any ReceiptReviewAPI
    private let scope: ReceiptSessionScope
    private let allowsMatching: @MainActor () -> Bool
    private let isCurrent: @MainActor () -> Bool
    private var generation = 0
    private var activeTask: Task<Void, Never>?

    private(set) var receipts: [ImportedReceiptSummary] = []
    private(set) var state: State = .loading
    private(set) var failure: ReceiptError?
    private(set) var isBusy = false
    private(set) var isCleared = false
    private(set) var detail: ReceiptDetail?
    private(set) var detailID: String?
    private(set) var candidates: [ReceiptCandidate] = []
    private(set) var selectedCandidate: ReceiptForm.CandidateID?
    private(set) var confirmedReceiptID: String?
    private(set) var outcomes: [ReceiptConfirmationOutcome] = []

    var groups: [ReceiptMerchantGroup] { ReceiptMerchantGroup.group(receipts) }
    var isDenied: Bool { state == .unauthorized || state == .forbidden }
    var canMatchReceipts: Bool { !isCleared && isCurrent() && allowsMatching() }
    var canConfirmSelected: Bool {
        !isBusy && detail != nil && (candidates.isEmpty || hasLinkChoice) && confirmLineError == nil
    }
    var totalAdjustment: ReceiptTotalAdjustment? {
        guard case .success(let plan) = selectedLinePlan else { return nil }
        return plan.adjustment
    }
    var confirmLineError: ReceiptError? {
        guard case .failure(let error) = selectedLinePlan else { return nil }
        return error.receiptError
    }

    private var selectedLinePlan: Result<ReceiptConfirmLinePlan, ReceiptConfirmLineError>? {
        guard let detail, let total = detail.summary.totalAmount.flatMap(ReceiptConfirmLines.normalizeConfirmTotal)
        else { return nil }
        return Self.linePlan(for: detail, total: total)
    }

    private(set) var hasLinkChoice = false

    init(api: any ReceiptReviewAPI, scope: ReceiptSessionScope,
         allowsMatching: @escaping @MainActor () -> Bool = { true },
         isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.api = api
        self.scope = scope
        self.allowsMatching = allowsMatching
        self.isCurrent = isCurrent
    }

    func load() async {
        guard let request = reserve() else { return }
        receipts = []
        detail = nil
        detailID = nil
        candidates = []
        selectedCandidate = nil
        hasLinkChoice = false
        confirmedReceiptID = nil
        outcomes = []
        failure = nil
        state = .loading
        await run(request) { await self.performLoad(request) }
    }

    func select(_ receipt: ImportedReceiptSummary) async {
        guard let request = reserve() else { return }
        detail = nil
        detailID = receipt.receiptId
        candidates = []
        selectedCandidate = nil
        hasLinkChoice = false
        confirmedReceiptID = nil
        failure = nil
        await run(request) {
            do {
                let result = try await self.api.receiptDetail(id: receipt.receiptId, scope: self.scope)
                guard self.isCurrent(request) else { return }
                guard try self.canReview(result.receipt.summary, for: receipt, clearDetail: true) else { return }
                self.detail = result.receipt
                let payment = result.receipt.summary.paymentMethod
                let offered = self.canMatchReceipts && payment != "cash" && payment != "mixed" ? result.candidates ?? [] : []
                self.candidates = offered
                self.selectedCandidate = Self.preselectedCandidate(from: offered).map(ReceiptForm.CandidateID.init)
                self.hasLinkChoice = self.selectedCandidate != nil
            } catch {
                self.publish(error, request: request)
            }
        }
    }

    func selectCandidate(_ candidate: ReceiptCandidate?) {
        guard !isBusy, !isCleared else { return }
        if let candidate {
            guard canMatchReceipts, candidates.contains(candidate) else { return }
            selectedCandidate = ReceiptForm.CandidateID(candidate)
        } else {
            selectedCandidate = nil
        }
        hasLinkChoice = true
    }

    func updateMatchAccess() {
        guard !canMatchReceipts else { return }
        candidates = []
        selectedCandidate = nil
        hasLinkChoice = false
    }

    func confirmSelected() async {
        guard canConfirmSelected, let detail, let detailID,
              let summary = receipts.first(where: { $0.receiptId == detailID }) else { return }
        var candidate: ReceiptCandidate?
        if let selectedCandidate {
            guard canMatchReceipts else { return }
            candidate = candidates.first { ReceiptForm.CandidateID($0) == selectedCandidate }
            guard candidate != nil else { return }
        }
        do {
            let confirmation = try Self.confirmation(for: detail, candidate: candidate)
            guard let operation = reserve() else { return }
            await run(operation) {
                await self.performConfirm(confirmation, summary: summary, request: operation, clearDetail: true)
            }
        } catch {
            failure = error
        }
    }

    func confirmMerchant(_ group: ReceiptMerchantGroup) async {
        guard group.canConfirmWithoutLinking, let operation = reserve() else { return }
        outcomes = []
        failure = nil
        await run(operation) {
            for summary in group.receipts where !summary.linked {
                guard self.isCurrent(operation) else { return }
                do {
                    let result = try await self.api.receiptDetail(id: summary.receiptId, scope: self.scope)
                    guard self.isCurrent(operation) else { return }
                    guard try self.canReview(result.receipt.summary, for: summary, clearDetail: false) else { continue }
                    guard result.receipt.summary.version == summary.version else { throw ReceiptError.versionConflict }
                    let confirmation: Confirmation
                    do throws(ReceiptError) {
                        confirmation = try Self.confirmation(for: result.receipt, candidate: nil)
                    } catch {
                        self.record(.failure(summary, error: error))
                        continue
                    }
                    await self.performConfirm(confirmation, summary: summary, request: operation, clearDetail: false)
                    if self.isCleared { return }
                } catch {
                    if self.recordFailure(error, summary: summary, request: operation) { return }
                }
            }
        }
    }

    func clear() {
        generation += 1
        activeTask?.cancel()
        activeTask = nil
        wipe()
        failure = nil
        outcomes = []
        isBusy = false
        isCleared = true
        state = .loading
    }

    nonisolated static func preselectedCandidate(from candidates: [ReceiptCandidate]) -> ReceiptCandidate? {
        guard candidates.count == 1, let candidate = candidates.first,
              candidate.matchStrength == .nip || candidate.matchStrength == .distinctive else { return nil }
        return candidate
    }

    private func canReview(
        _ current: ImportedReceiptSummary, for summary: ImportedReceiptSummary, clearDetail: Bool
    ) throws -> Bool {
        guard current.receiptId == summary.receiptId else { throw ReceiptError.versionConflict }
        if current.status == .confirmed {
            finishConfirmation(summary, alreadySubmitted: true, clearDetail: clearDetail)
            return false
        }
        guard current.status == .imported, !current.linked else { throw ReceiptError.versionConflict }
        return true
    }

    private struct Confirmation {
        let request: ReceiptConfirmRequest
        let adjustment: ReceiptTotalAdjustment?
    }

    private static func linePlan(
        for detail: ReceiptDetail, total: String
    ) -> Result<ReceiptConfirmLinePlan, ReceiptConfirmLineError> {
        Result { () throws(ReceiptConfirmLineError) in
            try ReceiptConfirmLines.planConfirmLines(
                documentKind: detail.summary.documentKind, originalLines: detail.lines,
                draftLines: detail.lines, total: total
            )
        }
    }

    private static func confirmation(
        for detail: ReceiptDetail, candidate: ReceiptCandidate?
    ) throws(ReceiptError) -> Confirmation {
        let summary = detail.summary
        let time = summary.receiptTime == "" ? nil : summary.receiptTime
        let incomplete = ReceiptError.rejected("incomplete_receipt")
        guard let day = summary.receiptDate.flatMap(ReceiptDay.init(iso:)),
              let currency = summary.currency, currency.wholeMatch(of: /[A-Z]{3}/) != nil,
              let total = summary.totalAmount.flatMap(ReceiptConfirmLines.normalizeConfirmTotal),
              time.map(ReceiptForm.validTime) != false else { throw incomplete }
        let payment = summary.paymentMethod.flatMap(ReceiptConfirmRequest.PaymentMethodPayload.init(rawValue:)) ?? .unknown
        guard candidate == nil || (payment != .cash && payment != .mixed) else { throw incomplete }

        let plan: ReceiptConfirmLinePlan
        switch linePlan(for: detail, total: total) {
        case .success(let result): plan = result
        case .failure(let error): throw error.receiptError
        }
        let lines = ReceiptConfirmLines.linesForRequest(
            plan, documentKind: summary.documentKind, originalLines: detail.lines, draftLines: detail.lines,
            invoiceNumber: summary.invoiceNumber, draftShopName: summary.rawShopName ?? "",
            storedShopName: summary.rawShopName, total: total
        )
        let request = ReceiptConfirmRequest(
            currency: currency, expectedVersion: summary.version, lines: lines,
            link: candidate.map { .init(accountId: $0.accountId, candidateToken: $0.candidateToken,
                                        entryReference: $0.entryReference) },
            paymentMethod: payment, receiptDate: day.iso, receiptId: summary.receiptId,
            receiptKind: summary.receiptKind == .refund ? .refund : .purchase,
            receiptTime: time, totalAmount: total
        )
        return Confirmation(request: request, adjustment: plan.adjustment)
    }

    private func reserve() -> Int? {
        guard !isBusy, !isCleared, !isDenied, isCurrent() else { return nil }
        activeTask?.cancel()
        generation += 1
        isBusy = true
        return generation
    }

    private func run(_ request: Int, _ work: @escaping @MainActor () async -> Void) async {
        guard isCurrent(request) else { return }
        let task = Task { @MainActor in await work() }
        activeTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == request {
            activeTask = nil
            isBusy = false
        }
    }

    private func performLoad(_ request: Int) async {
        var loaded: [ImportedReceiptSummary] = []
        var ids: Set<String> = []
        var cursor: String?
        var cursors: Set<String> = []
        do {
            while true {
                let page = try await api.listImportedReceipts(cursor: cursor, scope: scope)
                guard isCurrent(request) else { return }
                loaded.append(contentsOf: page.receipts.filter {
                    $0.status == .imported && ids.insert($0.receiptId).inserted
                })
                guard let next = page.nextCursor, !next.isEmpty, cursors.insert(next).inserted else { break }
                cursor = next
            }
            receipts = loaded
            state = .loaded
            failure = nil
        } catch {
            publish(error, request: request)
        }
    }

    private func performConfirm(
        _ confirmation: Confirmation, summary: ImportedReceiptSummary, request: Int, clearDetail: Bool
    ) async {
        do {
            _ = try await api.confirmImportedReceipt(confirmation.request, scope: scope)
            guard isCurrent(request) else { return }
            finishConfirmation(summary, clearDetail: clearDetail, adjustment: confirmation.adjustment)
        } catch ReceiptError.alreadySubmitted {
            guard isCurrent(request) else { return }
            finishConfirmation(summary, alreadySubmitted: true, clearDetail: clearDetail)
        } catch {
            recordFailure(error, summary: summary, request: request)
        }
    }

    private func finishConfirmation(
        _ summary: ImportedReceiptSummary, alreadySubmitted: Bool = false, clearDetail: Bool,
        adjustment: ReceiptTotalAdjustment? = nil
    ) {
        record(.success(summary, alreadySubmitted: alreadySubmitted, adjustment: adjustment))
        receipts.removeAll { $0.receiptId == summary.receiptId }
        if clearDetail {
            detail = nil
            detailID = nil
            candidates = []
            selectedCandidate = nil
            hasLinkChoice = false
            confirmedReceiptID = summary.receiptId
        }
    }

    private func record(_ outcome: ReceiptConfirmationOutcome) {
        outcomes.removeAll { $0.id == outcome.id }
        outcomes.append(outcome)
    }

    @discardableResult
    private func recordFailure(_ error: any Error, summary: ImportedReceiptSummary, request: Int) -> Bool {
        guard isCurrent(request), !APIError.isCancellation(error) else { return true }
        let wrapped = ReceiptError.wrap(error)
        if !wrapped.isAccessDenial { record(.failure(summary, error: wrapped)) }
        return publish(wrapped, request: request)
    }

    @discardableResult
    private func publish(_ error: any Error, request: Int) -> Bool {
        guard isCurrent(request) else { return true }
        if APIError.isCancellation(error) { return true }
        let wrapped = ReceiptError.wrap(error)
        failure = wrapped
        if wrapped.isAccessDenial {
            generation += 1
            activeTask?.cancel()
            activeTask = nil
            wipe()
            outcomes = []
            isBusy = false
            isCleared = true
            state = wrapped == .forbidden ? .forbidden : .unauthorized
            return true
        }
        state = .failed
        return false
    }

    private func isCurrent(_ request: Int) -> Bool {
        request == generation && !isCleared && !Task.isCancelled && isCurrent()
    }

    private func wipe() {
        receipts = []
        detail = nil
        detailID = nil
        candidates = []
        selectedCandidate = nil
        hasLinkChoice = false
        confirmedReceiptID = nil
    }
}
