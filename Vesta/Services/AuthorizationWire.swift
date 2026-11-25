import Foundation

/// The generator drops required nullable properties expressed as `anyOf`.
struct AuthFeaturesWire: Codable, Hashable, Sendable {
    private let authContract: Int
    private let features: [String]
    private let qrOrigin: String?

    private enum CodingKeys: String, CodingKey {
        case authContract = "auth_contract"
        case features
        case qrOrigin = "qr_origin"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        authContract = try values.decode(Int.self, forKey: .authContract)
        features = try values.decode([String].self, forKey: .features)
        qrOrigin = try values.decode(String?.self, forKey: .qrOrigin)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(authContract, forKey: .authContract)
        try values.encode(features, forKey: .features)
        try values.encode(qrOrigin, forKey: .qrOrigin)
    }

    var serverFeatures: ServerFeatures {
        guard authContract >= 2 else { return .legacy }
        return ServerFeatures(
            authContract: authContract,
            features: Set(features.compactMap(ServerFeature.init(rawValue:))),
            qrOrigin: qrOrigin.flatMap { QRLoginPayload.canonicalOrigin($0[...]) },
            isLegacy: false
        )
    }
}

struct MeCapabilitiesWire: Codable, Hashable, Sendable {
    private let user: String?
    private let actorTag: String?
    private let installationPermissions: [String]
    private let ownBudget: Components.Schemas.OwnBudgetCapabilities?
    private let delegatedReceipts: Components.Schemas.DelegatedReceiptCapabilities?
    private let householdAvailable: Bool

    private enum CodingKeys: String, CodingKey {
        case user
        case actorTag = "actor_tag"
        case installationPermissions = "installation_permissions"
        case ownBudget = "own_budget"
        case delegatedReceipts = "delegated_receipts"
        case householdAvailable = "household_available"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        user = try values.decode(String?.self, forKey: .user)
        actorTag = try values.decode(String?.self, forKey: .actorTag)
        installationPermissions = try values.decode([String].self, forKey: .installationPermissions)
        ownBudget = try values.decode(Components.Schemas.OwnBudgetCapabilities?.self, forKey: .ownBudget)
        delegatedReceipts = try values.decode(Components.Schemas.DelegatedReceiptCapabilities?.self, forKey: .delegatedReceipts)
        householdAvailable = try values.decode(Bool.self, forKey: .householdAvailable)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(user, forKey: .user)
        try values.encode(actorTag, forKey: .actorTag)
        try values.encode(installationPermissions, forKey: .installationPermissions)
        try values.encode(ownBudget, forKey: .ownBudget)
        try values.encode(delegatedReceipts, forKey: .delegatedReceipts)
        try values.encode(householdAvailable, forKey: .householdAvailable)
    }

    var capabilities: Capabilities {
        Capabilities(
            user: user,
            installation: Self.knownPermissions(installationPermissions),
            ownBudget: ownBudget.map {
                Capabilities.OwnBudget(
                    permissions: Self.knownPermissions($0.permissions),
                    canView: $0.canView,
                    canUseReceipts: $0.canUseReceipts,
                    canManageDevices: $0.canManageDevices
                )
            },
            delegatedReceipts: delegatedReceipts.map {
                Capabilities.DelegatedReceipts(permissions: Self.knownPermissions($0.permissions), canUse: $0.canUse)
            },
            householdAvailable: householdAvailable,
            isAuthOff: user == nil
        )
    }

    private static func knownPermissions(_ permissions: [String]) -> Set<Permission> {
        Set(permissions.compactMap(Permission.init(rawValue:)))
    }
}
