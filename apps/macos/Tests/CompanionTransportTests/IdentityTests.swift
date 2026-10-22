import XCTest
import Foundation
import Security
@testable import CompanionTransport

private final class MemoryIdentityStorage: IdentityStorage, @unchecked Sendable {
    var data: Data?
    var writes = 0
    var renames = 0
    var requiresApproval = false
    var lastInteraction: Bool?

    func read(allowUserInteraction: Bool) throws -> Data? {
        lastInteraction = allowUserInteraction
        if requiresApproval && !allowUserInteraction { throw IdentityAccessError.approvalRequired }
        return data
    }
    func save(_ data: Data, allowUserInteraction: Bool) throws {
        self.data = data
        writes += 1
    }
    func updateDisplayName() { renames += 1 }
}

final class IdentityTests: XCTestCase {
    func testRenamingExistingIdentityPreservesKeyAndFingerprint() throws {
        let storage = MemoryIdentityStorage()
        let initial = try LocalIdentity.load(storage: storage)
        let originalArchive = try XCTUnwrap(storage.data)
        let loaded = try LocalIdentity.load(storage: storage)
        XCTAssertEqual(initial.fingerprint.count, 64)
        XCTAssertEqual(initial.fingerprint, loaded.fingerprint)
        XCTAssertEqual(storage.data, originalArchive, "A readable name must not replace the connection key")
        XCTAssertEqual(storage.writes, 1)
        XCTAssertGreaterThan(storage.renames, 0)
        XCTAssertEqual(storage.lastInteraction, false)
    }

    func testNormalLaunchDoesNotRequestPasswordAndExplicitRetryPreservesPairing() throws {
        let storage = MemoryIdentityStorage()
        let original = try LocalIdentity.load(storage: storage)
        let archive = storage.data
        storage.requiresApproval = true
        XCTAssertThrowsError(try LocalIdentity.load(storage: storage)) { error in
            guard case IdentityAccessError.approvalRequired = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(storage.lastInteraction, false)
        XCTAssertEqual(storage.writes, 1, "A denied key must never be replaced")
        let approved = try LocalIdentity.load(allowUserInteraction: true, storage: storage)
        XCTAssertEqual(storage.lastInteraction, true)
        XCTAssertEqual(original.fingerprint, approved.fingerprint)
        XCTAssertEqual(storage.data, archive)
        XCTAssertEqual(storage.writes, 1)
    }

    func testKeychainMetadataMigrationLeavesStoredBytesUnchanged() throws {
        let service = "dev.relay.identity-test.\(UUID().uuidString)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "test"]
        defer { SecItemDelete(query as CFDictionary) }
        let storage = KeychainIdentityStorage(service: service, account: "test")
        let sentinel = Data("test-only-connection-key".utf8)
        try storage.save(sentinel, allowUserInteraction: false)
        XCTAssertEqual(try storage.read(allowUserInteraction: false), sentinel)
        XCTAssertEqual(SecItemUpdate(query as CFDictionary, [kSecAttrLabel as String: "old-internal-name"] as CFDictionary), errSecSuccess)
        storage.updateDisplayName()
        var attributesQuery = query
        attributesQuery[kSecReturnAttributes as String] = true
        attributesQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(attributesQuery as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrLabel as String] as? String, KeychainIdentityStorage.displayName)
        XCTAssertEqual(try storage.read(allowUserInteraction: false), sentinel)
    }

    func testDamagedStoredIdentityIsNotSilentlyReplaced() throws {
        let storage = MemoryIdentityStorage()
        storage.data = Data("invalid".utf8)
        XCTAssertThrowsError(try LocalIdentity.load(storage: storage))
        XCTAssertEqual(storage.data, Data("invalid".utf8))
        XCTAssertEqual(storage.writes, 0)
    }
}
