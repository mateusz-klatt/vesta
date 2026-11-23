import Foundation
import Security

struct StoredReceiptDeviceToken: Codable, Equatable, Sendable {
    let server: URL
    let credential: ReceiptDeviceToken
}

@MainActor
protocol DeviceTokenStoring {
    func load() throws -> StoredReceiptDeviceToken?
    func save(_ token: StoredReceiptDeviceToken) throws
    func clear() throws
    func loadPendingRevocations() throws -> [StoredReceiptDeviceToken]
    func savePendingRevocations(_ tokens: [StoredReceiptDeviceToken]) throws
}

private let pendingRevocationLimit = 5

extension DeviceTokenStoring {
    func addPendingRevocation(_ token: StoredReceiptDeviceToken) throws {
        var pending = try loadPendingRevocations()
        pending.removeAll {
            $0.server == token.server && $0.credential.tokenID == token.credential.tokenID
        }
        pending.append(token)
        try savePendingRevocations(Array(pending.suffix(pendingRevocationLimit)))
    }

    func removePendingRevocation(_ token: StoredReceiptDeviceToken) throws {
        var pending = try loadPendingRevocations()
        pending.removeAll {
            $0.server == token.server && $0.credential.tokenID == token.credential.tokenID
        }
        try savePendingRevocations(pending)
    }
}

struct KeychainDeviceTokenStore: DeviceTokenStoring {
    var account = "receipts"

    private func itemQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ie.klatt.vesta.device-token",
            kSecAttrAccount as String: account,
        ]
    }

    private var query: [String: Any] { itemQuery(account: account) }
    private var pendingQuery: [String: Any] { itemQuery(account: "\(account)-pending-revocations") }

    private func loadData(_ query: [String: Any]) throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw DevicePairingError.storage }
        return data
    }

    private func saveData(_ data: Data, query: [String: Any]) throws {
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw DevicePairingError.storage }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw DevicePairingError.storage }
    }

    private func removeData(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DevicePairingError.storage }
    }

    func load() throws -> StoredReceiptDeviceToken? {
        guard let data = try loadData(query) else { return nil }
        return try JSONDecoder().decode(StoredReceiptDeviceToken.self, from: data)
    }

    func save(_ token: StoredReceiptDeviceToken) throws {
        try saveData(JSONEncoder().encode(token), query: query)
    }

    func clear() throws {
        try removeData(query)
    }

    func loadPendingRevocations() throws -> [StoredReceiptDeviceToken] {
        guard let data = try loadData(pendingQuery) else { return [] }
        return try JSONDecoder().decode([StoredReceiptDeviceToken].self, from: data)
    }

    func savePendingRevocations(_ tokens: [StoredReceiptDeviceToken]) throws {
        guard !tokens.isEmpty else {
            try removeData(pendingQuery)
            return
        }
        try saveData(JSONEncoder().encode(tokens), query: pendingQuery)
    }
}
