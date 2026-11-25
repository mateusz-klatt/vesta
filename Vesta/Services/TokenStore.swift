import Foundation
import Security

enum SessionKeychainAccount: String, Sendable {
    case legacy = "backend"
    case authoritative = "backend-session"
    case legacyMigrated = "backend-legacy-migrated"
}

enum SessionKeychainError: Error, Equatable {
    case locked
    case readFailed
    case writeFailed
}

protocol SessionKeychain: Sendable {
    func read(_ account: SessionKeychainAccount) throws -> Data?
    func write(_ data: Data, to account: SessionKeychainAccount) throws
    func delete(_ account: SessionKeychainAccount) throws
}

struct SystemSessionKeychain: SessionKeychain {
    private static let service = "ie.klatt.vesta.bearer"

    func read(_ account: SessionKeychainAccount) throws -> Data? {
        var query = Self.query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed { throw SessionKeychainError.locked }
        guard status == errSecSuccess, let data = item as? Data else { throw SessionKeychainError.readFailed }
        return data
    }

    func write(_ data: Data, to account: SessionKeychainAccount) throws {
        let query = Self.query(account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        // Update the item in place so a failed replacement leaves the previous credential intact.
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else {
            try Self.checkWrite(status)
            return
        }
        let item = query.merging(attributes) { _, value in value }
        let added = SecItemAdd(item as CFDictionary, nil)
        try Self.checkWrite(added == errSecDuplicateItem
            ? SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            : added)
    }

    func delete(_ account: SessionKeychainAccount) throws {
        let status = SecItemDelete(Self.query(account) as CFDictionary)
        if status != errSecItemNotFound { try Self.checkWrite(status) }
    }

    private static func query(_ account: SessionKeychainAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    private static func checkWrite(_ status: OSStatus) throws {
        if status == errSecInteractionNotAllowed { throw SessionKeychainError.locked }
        guard status == errSecSuccess else { throw SessionKeychainError.writeFailed }
    }
}
