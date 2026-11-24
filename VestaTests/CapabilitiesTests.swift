import XCTest
@testable import Vesta

final class CapabilitiesTests: XCTestCase {
    func testLegacyAuthOffExcludesManageUsersAndSeparatesBudgetViewFromReceipts() {
        let authOff = Capabilities.fromLegacyRole(role: nil, user: nil)
        XCTAssertEqual(authOff.installation, [
            .iocView, .iocControl, .iocConfigure, .calendarView, .calendarEdit, .systemAuditView,
        ])
        XCTAssertTrue(authOff.isAuthOff)
        XCTAssertTrue(authOff.canViewIOC)
        XCTAssertTrue(authOff.canControlIOC)
        XCTAssertFalse(authOff.installation.contains(.systemManageUsers))
        XCTAssertNil(authOff.ownBudget)
        XCTAssertFalse(authOff.canUseReceipts)
        XCTAssertFalse(authOff.canMatchReceipts)

        let admin = Capabilities.fromLegacyRole(role: "admin", user: "u")
        XCTAssertTrue(admin.installation.contains(.systemManageUsers))
        XCTAssertEqual(admin.effectiveDeviceReceiptPermissions, Permission.deviceEligibleReceiptIDs)
        XCTAssertEqual(admin.effectiveDeviceEligiblePermissions, Permission.deviceEligibleIDs)

        let missingRole = Capabilities.fromLegacyRole(role: nil, user: "u")
        let unknownRole = Capabilities.fromLegacyRole(role: "unknown", user: nil)
        for capabilities in [missingRole, unknownRole] {
            XCTAssertTrue(capabilities.installation.isEmpty)
            XCTAssertNil(capabilities.ownBudget)
            XCTAssertFalse(capabilities.isAuthOff)
            XCTAssertFalse(capabilities.canViewIOC)
            XCTAssertFalse(capabilities.canControlIOC)
        }

        let budgetOnly = Capabilities(ownBudget: .init(
            permissions: [.budgetView], canView: true, canUseReceipts: false, canManageDevices: false
        ))
        XCTAssertEqual(budgetOnly.effectiveDeviceEligiblePermissions, [.budgetView])
        XCTAssertTrue(budgetOnly.effectiveDeviceReceiptPermissions.isEmpty)
        XCTAssertFalse(budgetOnly.canUseReceipts)
        XCTAssertFalse(budgetOnly.canMatchReceipts)

        let delegated = Capabilities(delegatedReceipts: .init(
            permissions: [.budgetView, .budgetReceiptsAdd, .budgetReceiptsMatch], canUse: true
        ))
        XCTAssertEqual(delegated.effectiveDeviceEligiblePermissions, [.budgetReceiptsAdd, .budgetReceiptsMatch])
        XCTAssertEqual(delegated.effectiveDeviceReceiptPermissions, [.budgetReceiptsAdd, .budgetReceiptsMatch])
        XCTAssertTrue(delegated.canUseReceipts)
        XCTAssertTrue(delegated.canMatchReceipts)
    }
}
