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
}

struct KeychainDeviceTokenStore: DeviceTokenStoring {
    var account = "receipts"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ie.klatt.vesta.device-token",
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> StoredReceiptDeviceToken? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw DevicePairingError.storage }
        return try JSONDecoder().decode(StoredReceiptDeviceToken.self, from: data)
    }

    func save(_ token: StoredReceiptDeviceToken) throws {
        let query = query
        let data = try JSONEncoder().encode(token)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw DevicePairingError.storage }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw DevicePairingError.storage }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DevicePairingError.storage }
    }
}
