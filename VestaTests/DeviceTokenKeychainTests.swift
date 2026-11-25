import Foundation
import Security
import XCTest
@testable import Vesta

@MainActor
final class DeviceTokenKeychainTests: XCTestCase {
    private let token = StoredReceiptDeviceToken(
        server: URL(string: "https://hestia.example")!, credential: fakeDeviceToken
    )

    func testDeviceKeychainReadDistinguishesAbsentFromLockedAndFailedOSStatus() throws {
        let keychain = ScriptedKeychain()
        let store = KeychainDeviceTokenStore(keychain: keychain)

        keychain.readStatus = errSecItemNotFound
        XCTAssertNil(try store.load())
        XCTAssertEqual(try store.loadPendingRevocations(), [])

        for status in [errSecInteractionNotAllowed, errSecNotAvailable] {
            keychain.readStatus = status
            assertStorageError { _ = try store.load() }
            assertStorageError { _ = try store.loadPendingRevocations() }
        }
        XCTAssertEqual(keychain.writes.count, 0)
    }

    func testDeviceKeychainAddAndUpdateUseWhenUnlockedThisDeviceOnly() throws {
        let keychain = ScriptedKeychain()
        let store = KeychainDeviceTokenStore(keychain: keychain)
        keychain.updateStatuses = [errSecItemNotFound, errSecSuccess]

        try store.save(token)
        try store.save(token)

        XCTAssertEqual(keychain.writes.count, 3)
        guard case .add(let addition) = try XCTUnwrap(keychain.writes.dropFirst().first),
              case .update(let query, let update) = try XCTUnwrap(keychain.writes.last) else {
            return XCTFail("Expected an add after the missing item and an in-place update")
        }
        let expectedPolicy = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        XCTAssertEqual(addition[kSecAttrAccessible as String] as? String, expectedPolicy)
        XCTAssertEqual(update[kSecAttrAccessible as String] as? String, expectedPolicy)
        XCTAssertNil(query[kSecAttrAccessible as String])
        let addedData = try XCTUnwrap(addition[kSecValueData as String] as? Data)
        let updatedData = try XCTUnwrap(update[kSecValueData as String] as? Data)
        XCTAssertEqual(try JSONDecoder().decode(StoredReceiptDeviceToken.self, from: addedData), token)
        XCTAssertEqual(try JSONDecoder().decode(StoredReceiptDeviceToken.self, from: updatedData), token)
    }

    func testDeviceKeychainDuplicateAddRetriesUpdateWithSamePayload() throws {
        let keychain = ScriptedKeychain()
        let store = KeychainDeviceTokenStore(keychain: keychain)
        keychain.updateStatuses = [errSecItemNotFound, errSecSuccess]
        keychain.addStatus = errSecDuplicateItem

        try store.savePendingRevocations([token])

        XCTAssertEqual(keychain.writes.count, 3)
        guard case .update(let before, let initial) = try XCTUnwrap(keychain.writes.first),
              case .add(let addition) = try XCTUnwrap(keychain.writes.dropFirst().first),
              case .update(let after, let retry) = try XCTUnwrap(keychain.writes.last) else {
            return XCTFail("Expected a single update retry after the duplicate result")
        }
        XCTAssertEqual(before[kSecAttrAccount as String] as? String, "receipts-pending-revocations")
        XCTAssertEqual(before as? [String: String], after as? [String: String])
        let initialData = try XCTUnwrap(initial[kSecValueData as String] as? Data)
        XCTAssertEqual(addition[kSecValueData as String] as? Data, initialData)
        XCTAssertEqual(retry[kSecValueData as String] as? Data, initialData)
        XCTAssertEqual(retry[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testDeviceKeychainRejectsFailedWritesAndDeletesWithoutRemovingTheItem() {
        for status in [errSecInteractionNotAllowed, errSecNotAvailable] {
            let keychain = ScriptedKeychain()
            let store = KeychainDeviceTokenStore(keychain: keychain)
            keychain.updateStatuses = [status]
            assertStorageError { try store.save(token) }
            XCTAssertEqual(keychain.writes.count, 1)

            keychain.updateStatuses = [errSecItemNotFound]
            keychain.addStatus = status
            assertStorageError { try store.save(token) }
            XCTAssertEqual(keychain.writes.count, 3)

            keychain.updateStatuses = [errSecItemNotFound, status]
            keychain.addStatus = errSecDuplicateItem
            assertStorageError { try store.save(token) }
            XCTAssertEqual(keychain.writes.count, 6)
            XCTAssertFalse(keychain.writes.contains { if case .delete = $0 { true } else { false } })

            keychain.deleteStatus = status
            assertStorageError { try store.clear() }
            keychain.deleteStatus = errSecItemNotFound
            XCTAssertNoThrow(try store.clear())
        }
    }

    private func assertStorageError(_ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            guard case .storage? = error as? DevicePairingError else {
                return XCTFail("Expected a device storage error, received \(error)", file: file, line: line)
            }
        }
    }
}

@MainActor
private final class ScriptedKeychain: DeviceTokenKeychain {
    enum Write {
        case update([String: Any], [String: Any])
        case add([String: Any])
        case delete
    }

    var readStatus = errSecItemNotFound
    var updateStatuses: [OSStatus] = []
    var addStatus = errSecSuccess
    var deleteStatus = errSecSuccess
    private(set) var writes: [Write] = []

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, item: CFTypeRef?) { (readStatus, nil) }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        writes.append(.update(query, attributes))
        return updateStatuses.isEmpty ? errSecSuccess : updateStatuses.removeFirst()
    }

    func add(_ item: [String: Any]) -> OSStatus {
        writes.append(.add(item))
        return addStatus
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        writes.append(.delete)
        return deleteStatus
    }
}
