import Foundation
import Observation

@MainActor
@Observable
final class ReceiptPairing {
    enum Status { case notPaired, paired, pairAgain }

    private static let failedRevocationNotice: LocalizedStringResource =
        "Couldn't reach hestia. Remove this iPhone in hestia's device list."

    private(set) var status: Status = .notPaired
    private(set) var revocationNotice: LocalizedStringResource?
    private var isPairing = false
    private var isRevoking = false
    private var isRetryingPendingRevocations = false
    var isBusy: Bool { isPairing || isRevoking }

    private let api: any DevicePairingAPI
    private let store: any DeviceTokenStoring
    private let serverURL: @MainActor () -> URL
    private var pairingCancelled = false

    init(api: any DevicePairingAPI = GeneratedDevicePairingAPI(),
         store: any DeviceTokenStoring = KeychainDeviceTokenStore(),
         serverURL: @escaping @MainActor () -> URL = { AppConfig.serverURL }) {
        self.api = api
        self.store = store
        self.serverURL = serverURL
        refreshStatus()
    }

    func refreshStatus() {
        schedulePendingRevocationRetry()
        guard !isBusy, status != .pairAgain else { return }
        status = credential(for: serverURL()) == nil ? .notPaired : .paired
    }

    func credential(for server: URL) -> StoredReceiptDeviceToken? {
        guard !isRevoking, status != .pairAgain, server == serverURL(),
              let token = try? store.load(), token.server == server else { return nil }
        return token
    }

    func pair(code: ReceiptPairingCode, deviceName: String) async throws {
        guard !isBusy, status != .paired else { return }
        isPairing = true
        pairingCancelled = false
        defer { isPairing = false }
        let server = serverURL()
        let token: ReceiptDeviceToken
        do {
            token = try await api.redeem(code: code, deviceName: deviceName, server: server)
        } catch let error as DevicePairingError {
            throw error
        } catch {
            throw DevicePairingError.redeemFailed
        }
        guard !pairingCancelled, !Task.isCancelled, server == serverURL() else {
            try await revoke(token, server: server)
            throw CancellationError()
        }
        do {
            try store.save(.init(server: server, credential: token))
            status = .paired
        } catch {
            try await revoke(token, server: server)
            throw DevicePairingError.storage
        }
    }

    func unpair() async throws {
        pairingCancelled = true
        guard !isRevoking else { return }
        isRevoking = true
        defer { isRevoking = false }
        if let token = try? store.load() {
            try await revoke(token.credential, server: token.server)
        }
        do {
            try store.clear()
            status = .notPaired
        } catch {
            throw DevicePairingError.storage
        }
    }

    private func revoke(_ token: ReceiptDeviceToken, server: URL) async throws {
        do {
            try await api.revoke(token, server: server)
        } catch {
            if Self.revocationCompleted(error) {
                updateRevocationNotice()
                return
            }
            try store.addPendingRevocation(.init(server: server, credential: token))
            revocationNotice = Self.failedRevocationNotice
            return
        }
        updateRevocationNotice()
    }

    private func schedulePendingRevocationRetry() {
        guard !isRetryingPendingRevocations,
              let pending = try? store.loadPendingRevocations(), !pending.isEmpty else { return }
        revocationNotice = Self.failedRevocationNotice
        isRetryingPendingRevocations = true
        Task { [weak self] in
            await self?.retryPendingRevocations(pending)
        }
    }

    private func retryPendingRevocations(_ pending: [StoredReceiptDeviceToken]) async {
        defer { isRetryingPendingRevocations = false }
        for token in pending {
            do {
                try await api.revoke(token.credential, server: token.server)
                try? store.removePendingRevocation(token)
            } catch {
                if Self.revocationCompleted(error) {
                    try? store.removePendingRevocation(token)
                }
            }
        }
        updateRevocationNotice()
    }

    private func updateRevocationNotice() {
        guard let pending = try? store.loadPendingRevocations() else { return }
        revocationNotice = pending.isEmpty ? nil : Self.failedRevocationNotice
    }

    private static func revocationCompleted(_ error: any Error) -> Bool {
        switch ReceiptError.wrap(error) {
        case .pairAgain, .notFound, .disabled: true
        default: false
        }
    }

    func invalidate(_ used: StoredReceiptDeviceToken) {
        // A delayed 401 from an old request must leave a replacement token alone.
        guard !isRevoking, (try? store.load()) == used else { return }
        status = .pairAgain
        try? store.clear()
    }
}
