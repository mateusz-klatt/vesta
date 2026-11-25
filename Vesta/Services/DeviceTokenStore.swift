import Foundation
import Security

enum DeviceTokenProvenance: String, Codable, Equatable, Sendable {
    case exchanged, legacyPasswordLogin, legacyCodeRedeem, legacyMigrated1x
}

struct StoredReceiptDeviceToken: Codable, Equatable, Sendable {
    let server: URL
    let provenance: DeviceTokenProvenance
    let actor: String?
    let owner: String?
    let ownerKey: String?
    let issuedPermissions: [String]?
    let lastUsableCeiling: [String]?
    // A code redeem supplies no identity. Associate it with the session that
    // redeemed it without claiming the credential belongs to that actor.
    let sessionCommitID: UUID?
    let credential: ReceiptDeviceToken

    init(server: URL, provenance: DeviceTokenProvenance = .legacyMigrated1x,
         actor: String? = nil, owner: String? = nil, ownerKey: String? = nil,
         issuedPermissions: [String]? = nil, lastUsableCeiling: [String]? = nil,
         sessionCommitID: UUID? = nil, credential: ReceiptDeviceToken) {
        self.server = server
        self.provenance = provenance
        self.actor = actor
        self.owner = owner
        self.ownerKey = ownerKey
        self.issuedPermissions = issuedPermissions
        self.lastUsableCeiling = lastUsableCeiling
        self.sessionCommitID = sessionCommitID
        self.credential = credential
    }

    private enum CodingKeys: String, CodingKey {
        case server, provenance, actor, owner, ownerKey, issuedPermissions, lastUsableCeiling, sessionCommitID, credential
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        server = try container.decode(URL.self, forKey: .server)
        provenance = try container.decodeIfPresent(DeviceTokenProvenance.self, forKey: .provenance) ?? .legacyMigrated1x
        actor = try container.decodeIfPresent(String.self, forKey: .actor)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        ownerKey = try container.decodeIfPresent(String.self, forKey: .ownerKey)
        issuedPermissions = try container.decodeIfPresent([String].self, forKey: .issuedPermissions)
        lastUsableCeiling = try container.decodeIfPresent([String].self, forKey: .lastUsableCeiling)
        sessionCommitID = try container.decodeIfPresent(UUID.self, forKey: .sessionCommitID)
        credential = try container.decode(ReceiptDeviceToken.self, forKey: .credential)
    }

    func withScope(actor: String?, sessionCommitID: UUID? = nil) -> Self {
        Self(server: server, provenance: provenance, actor: actor, owner: owner, ownerKey: ownerKey,
             issuedPermissions: issuedPermissions, lastUsableCeiling: lastUsableCeiling,
             sessionCommitID: sessionCommitID, credential: credential)
    }

    func matchesDevice(_ other: Self) -> Bool {
        OriginMatcher.matches(server, other.server) && credential.tokenID == other.credential.tokenID
    }

    func matchesBearer(_ other: Self) -> Bool {
        matchesDevice(other) && credential.token == other.credential.token
    }
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
    func addPendingRevocation(_ token: StoredReceiptDeviceToken, preservingExisting: Bool = false) throws {
        var pending = try loadPendingRevocations()
        if pending.contains(token) { return }
        pending.removeAll { $0.matchesDevice(token) }
        pending.append(token)
        try savePendingRevocations(preservingExisting ? pending : Array(pending.suffix(pendingRevocationLimit)))
    }

    func removePendingRevocation(_ token: StoredReceiptDeviceToken) throws {
        var pending = try loadPendingRevocations()
        let originalCount = pending.count
        pending.removeAll { $0.matchesBearer(token) }
        if pending.count != originalCount { try savePendingRevocations(pending) }
    }
}

struct KeychainDeviceTokenStore: DeviceTokenStoring {
    var account = "receipts"

    fileprivate func itemQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ie.klatt.vesta.device-token",
            kSecAttrAccount as String: account,
        ]
    }

    private var query: [String: Any] { itemQuery(account: account) }
    private var pendingQuery: [String: Any] { itemQuery(account: "\(account)-pending-revocations") }

    fileprivate func loadData(_ query: [String: Any]) throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw DevicePairingError.storage }
        return data
    }

    fileprivate func saveData(_ data: Data, query: [String: Any]) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw DevicePairingError.storage }

        let item = query.merging(attributes) { _, value in value }
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

extension KeychainDeviceTokenStore {
    /// A random per-install suffix for the receipts device name. It lives in a
    /// this-device-only Keychain item, so a backup restored onto another phone
    /// gets its own suffix instead of rotating the original phone's token.
    func deviceNameSuffix() -> String {
        let query = itemQuery(account: "\(account)-device-name")
        if let data = try? loadData(query), let stored = String(data: data, encoding: .utf8),
           stored.count == 32, stored.allSatisfy(\.isHexDigit) {
            return stored
        }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try? saveData(Data(suffix.utf8), query: query)
        return suffix
    }
}
