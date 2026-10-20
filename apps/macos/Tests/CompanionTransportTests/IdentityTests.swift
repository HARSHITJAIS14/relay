import XCTest
import Foundation
@testable import CompanionTransport

final class IdentityTests: XCTestCase {
    func testIdentityGenerationAndLoad() async throws {
        let identity = try LocalIdentity.load()
        XCTAssertFalse(identity.fingerprint.isEmpty)
        XCTAssertEqual(identity.fingerprint.count, 64)
    }
}
