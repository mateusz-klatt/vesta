import Foundation

enum RotationJournalState: String, Codable, Sendable {
    case intent, sent, outcomeUnknown, replaced
}

struct RotationJournalRecord: Codable, Equatable, Sendable {
    var state: RotationJournalState
    let server: URL
    let capturedActor: String
    let expectedOwnerKey: String?
    let slotTokenID: String
    let priorToken: StoredReceiptDeviceToken
    var replacement: StoredReceiptDeviceToken? = nil
    var updatedAt: Date = .now

    var priorProvenance: DeviceTokenProvenance { priorToken.provenance }

    func matchesSession(_ session: BoundSession) -> Bool {
        OriginMatcher.matches(server, session.origin) && capturedActor == session.actor
    }

    var matchesPriorScope: Bool {
        OriginMatcher.matches(server, priorToken.server) && slotTokenID == priorToken.credential.tokenID
            && expectedOwnerKey == priorToken.ownerKey && (priorToken.actor == capturedActor
                || (priorProvenance == .legacyCodeRedeem && priorToken.actor == nil))
    }

    func transitioning(to state: RotationJournalState, replacement: StoredReceiptDeviceToken? = nil) -> Self {
        var record = self
        record.state = state
        record.replacement = replacement
        record.updatedAt = .now
        return record
    }
}

struct DeviceExchangeLimit: Codable, Equatable, Sendable {
    let server: URL
    let actor: String
    let deviceName: String
    let tokenID: String?
    let isOwner: Bool

    func matches(_ session: BoundSession) -> Bool {
        OriginMatcher.matches(server, session.origin) && actor == session.actor
    }
}
