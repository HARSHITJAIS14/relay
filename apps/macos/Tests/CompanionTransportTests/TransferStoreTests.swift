import XCTest
import Foundation
@testable import CompanionTransport

final class TransferStoreTests: XCTestCase, @unchecked Sendable {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testQueueSnapshotsSourceAndSurvivesRestart() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.txt")
        try Data("original".utf8).write(to: source)
        let store = try TransferStore(root: root.appendingPathComponent("peer"), receiveFolder: root.appendingPathComponent("received"))
        let offer = try await store.enqueue(source)
        try Data("changed".utf8).write(to: source)
        let restarted = try TransferStore(root: root.appendingPathComponent("peer"), receiveFolder: root.appendingPathComponent("received"))
        let restored = try await restarted.next()
        XCTAssertEqual(restored?.id, offer.id)
        XCTAssertEqual(restored?.sha256, digest(Data("original".utf8)))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("peer/outbox/\(offer.id).data")), Data("original".utf8))
    }

    func testWrongReceiptKeepsQueueAndCorrectReceiptRemovesIt() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.txt")
        try Data("test".utf8).write(to: source)
        let store = try TransferStore(root: root.appendingPathComponent("peer"), receiveFolder: root.appendingPathComponent("received"))
        let offer = try await store.enqueue(source)
        do {
            try await store.acknowledge(id: offer.id, sha256: String(repeating: "0", count: 64))
            XCTFail("Wrong hash accepted")
        } catch {}
        let pending = try await store.next()
        XCTAssertEqual(pending?.id, offer.id)
        try await store.acknowledge(id: offer.id, sha256: offer.sha256)
        let empty = try await store.next()
        XCTAssertNil(empty)
        try await store.acknowledge(id: offer.id, sha256: offer.sha256)
    }

    func testRejectsSymlinkAndOversizedFile() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.txt")
        try Data("test".utf8).write(to: source)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let store = try TransferStore(root: root.appendingPathComponent("peer"), receiveFolder: root.appendingPathComponent("received"))
        do { _ = try await store.enqueue(link); XCTFail("Symlink accepted") } catch {}
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: UInt64(TransferStore.maximumSize + 1))
        try file.close()
        do { _ = try await store.enqueue(source); XCTFail("Oversized file accepted") } catch {}
    }

    func testPeerQueuesAreIsolatedAndReceiptPathsValidated() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.txt")
        try Data("test".utf8).write(to: source)
        let first = try TransferStore(root: root.appendingPathComponent("peer-one"), receiveFolder: root.appendingPathComponent("received"))
        let second = try TransferStore(root: root.appendingPathComponent("peer-two"), receiveFolder: root.appendingPathComponent("received"))
        _ = try await first.enqueue(source)
        let otherQueue = try await second.next()
        XCTAssertNil(otherQueue)
        do { try await first.acknowledge(id: "../sample", sha256: "invalid"); XCTFail("Unsafe ID accepted") } catch {}
    }

    func testRetainsOriginalNameAndHandlesCollision() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let receiveFolder = root.appendingPathComponent("received")
        let store = try TransferStore(root: root.appendingPathComponent("peer"), receiveFolder: receiveFolder)

        let hashA = digest(Data("content A".utf8))
        let hashB = digest(Data("content B".utf8))

        // 1. First file gets original name
        let dest1 = try await store.destinationURL(for: "report.pdf", expectedHash: hashA)
        XCTAssertEqual(dest1.url.lastPathComponent, "report.pdf")
        XCTAssertFalse(dest1.alreadyComplete)

        // Write content A to report.pdf
        try Data("content A".utf8).write(to: dest1.url)

        // 2. Exact same hash reports alreadyComplete on original name
        let destSame = try await store.destinationURL(for: "report.pdf", expectedHash: hashA)
        XCTAssertEqual(destSame.url.lastPathComponent, "report.pdf")
        XCTAssertTrue(destSame.alreadyComplete)

        // 3. Different content gets numbered suffix without UUID prefix
        let dest2 = try await store.destinationURL(for: "report.pdf", expectedHash: hashB)
        XCTAssertEqual(dest2.url.lastPathComponent, "report (1).pdf")
        XCTAssertFalse(dest2.alreadyComplete)

        // Write content B to report (1).pdf
        try Data("content B".utf8).write(to: dest2.url)

        // 4. Third different file gets (2)
        let hashC = digest(Data("content C".utf8))
        let dest3 = try await store.destinationURL(for: "report.pdf", expectedHash: hashC)
        XCTAssertEqual(dest3.url.lastPathComponent, "report (2).pdf")
        XCTAssertFalse(dest3.alreadyComplete)
    }
}
