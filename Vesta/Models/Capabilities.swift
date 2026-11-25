enum Permission: String, Hashable, Codable, Sendable, CaseIterable {
    case iocView = "ioc.view", iocControl = "ioc.control", iocConfigure = "ioc.configure"
    case calendarView = "calendar.view", calendarEdit = "calendar.edit"
    case systemAuditView = "system.audit.view", systemManageUsers = "system.manage_users"
    case budgetView = "budget.view", budgetEdit = "budget.edit"
    case budgetReceiptsAdd = "budget.receipts.add", budgetReceiptsView = "budget.receipts.view"
    case budgetReceiptsEdit = "budget.receipts.edit", budgetReceiptsMatch = "budget.receipts.match"
    case householdView = "household.view"

    static let deviceEligibleReceiptIDs: Set<Permission> = [
        .budgetReceiptsAdd, .budgetReceiptsView, .budgetReceiptsEdit, .budgetReceiptsMatch,
    ]
    static let deviceEligibleIDs = deviceEligibleReceiptIDs.union([.budgetView])

    /// Ordinary installation permissions when legacy whoami reports authentication is off.
    static let legacyAuthOffInstallation: Set<Permission> = [
        .iocView, .iocControl, .iocConfigure,
        .calendarView, .calendarEdit,
        .systemAuditView,
    ]
}

struct Capabilities: Equatable, Sendable {
    struct OwnBudget: Equatable, Sendable {
        let permissions: Set<Permission>
        let canView: Bool
        let canUseReceipts: Bool
        let canManageDevices: Bool
    }

    struct DelegatedReceipts: Equatable, Sendable {
        let permissions: Set<Permission>
        let canUse: Bool
    }

    let user: String?
    let installation: Set<Permission>
    let ownBudget: OwnBudget?
    let delegatedReceipts: DelegatedReceipts?
    let isAuthOff: Bool
    let legacyRole: String?

    init(user: String? = nil, installation: Set<Permission> = [], ownBudget: OwnBudget? = nil,
         delegatedReceipts: DelegatedReceipts? = nil, isAuthOff: Bool = false, legacyRole: String? = nil) {
        self.user = user
        self.installation = installation
        self.ownBudget = ownBudget
        self.delegatedReceipts = delegatedReceipts
        self.isAuthOff = isAuthOff
        self.legacyRole = legacyRole
    }

    private var rawReceiptPermissions: Set<Permission> {
        var permissions: Set<Permission> = []
        if let ownBudget, ownBudget.canUseReceipts {
            permissions.formUnion(ownBudget.permissions)
        }
        if let delegatedReceipts, delegatedReceipts.canUse {
            permissions.formUnion(delegatedReceipts.permissions)
        }
        return permissions
    }

    var effectiveDeviceReceiptPermissions: Set<Permission> {
        rawReceiptPermissions.intersection(Permission.deviceEligibleReceiptIDs)
    }

    var effectiveDeviceEligiblePermissions: Set<Permission> {
        guard let ownBudget, ownBudget.canView, ownBudget.permissions.contains(.budgetView) else {
            return effectiveDeviceReceiptPermissions
        }
        return effectiveDeviceReceiptPermissions.union([.budgetView])
    }

    var canUseReceipts: Bool { effectiveDeviceReceiptPermissions.contains(.budgetReceiptsAdd) }
    var canMatchReceipts: Bool { effectiveDeviceReceiptPermissions.contains(.budgetReceiptsMatch) }
    var canViewIOC: Bool { isAuthOff || installation.contains(.iocView) }
    var canControlIOC: Bool { isAuthOff || installation.contains(.iocControl) }
    var canViewCalendar: Bool { isAuthOff || installation.contains(.calendarView) }

    static func fromLegacyRole(role: String?, user: String?) -> Capabilities {
        let viewer: Set<Permission> = [.iocView, .calendarView, .systemAuditView]
        let operatorGrants = viewer.union([.iocControl, .calendarEdit])

        switch role {
        case "viewer":
            return .init(user: user, installation: viewer, legacyRole: role)
        case "operator":
            return .init(user: user, installation: operatorGrants, legacyRole: role)
        case "admin":
            return .init(
                user: user,
                installation: operatorGrants.union([.iocConfigure, .systemManageUsers]),
                ownBudget: .init(permissions: Permission.deviceEligibleIDs.union([.budgetEdit]),
                                 canView: true, canUseReceipts: true, canManageDevices: true),
                legacyRole: role
            )
        case nil where user == nil:
            return .init(installation: Permission.legacyAuthOffInstallation, isAuthOff: true)
        default:
            return .init(user: user, legacyRole: role)
        }
    }
}
