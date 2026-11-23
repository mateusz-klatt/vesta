import Foundation
import Observation

@MainActor
@Observable
final class ReceiptPairing {
    enum Status { case notPaired, paired, pairAgain }

    private(set) var status: Status = .notPaired
    private(set) var revocationNotice: LocalizedStringResource?
    private var isPairing = false
    private var isRevoking = false
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
            await revoke(token, server: server)
            throw CancellationError()
        }
        do {
            try store.save(.init(server: server, credential: token))
            status = .paired
        } catch {
            await revoke(token, server: server)
            throw DevicePairingError.storage
        }
    }

    func unpair() async throws {
        pairingCancelled = true
        guard !isRevoking else { return }
        isRevoking = true
        defer { isRevoking = false }
        if let token = try? store.load() {
            await revoke(token.credential, server: token.server)
        }
        do {
            try store.clear()
            status = .notPaired
        } catch {
            throw DevicePairingError.storage
        }
    }

    private func revoke(_ token: ReceiptDeviceToken, server: URL) async {
        do {
            try await api.revoke(token, server: server)
            revocationNotice = nil
        } catch {
            revocationNotice = "Couldn't reach hestia. Remove this iPhone in hestia's device list."
        }
    }

    func invalidate(_ used: StoredReceiptDeviceToken) {
        // A delayed 401 from an old request must leave a replacement token alone.
        guard !isRevoking, (try? store.load()) == used else { return }
        status = .pairAgain
        try? store.clear()
    }
}
