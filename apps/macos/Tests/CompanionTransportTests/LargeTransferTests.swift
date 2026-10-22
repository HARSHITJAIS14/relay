import XCTest
import Foundation
import Network
@testable import CompanionTransport

private actor ProgressLog {
    private var events: [TransferProgress] = []
    func append(_ event: TransferProgress) { events.append(event) }
    func all() -> [TransferProgress] { events }
}

final class LargeTransferTests: XCTestCase, @unchecked Sendable {
    func testLargeStreamAndResumeReportProgressAndVerifyBytes() async throws {
        // Opt in to exercising the exact advertised boundary; the default still exceeds the old cap.
        let size: Int64 = ProcessInfo.processInfo.environment["RUN_LARGE_TRANSFER_TESTS"] == "1" ? 1_000_000_000 : 128 * 1024 * 1024
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large-test.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: UInt64(size))
        try file.close()
        let sender = try TransferStore(root: root.appendingPathComponent("sender"), receiveFolder: root.appendingPathComponent("unused"))
        let receiverRoot = root.appendingPathComponent("receiver")
        let receiver = try TransferStore(root: receiverRoot, receiveFolder: root.appendingPathComponent("received"))
        let preparation = ProgressLog()
        let offer = try await sender.enqueue(source) { await preparation.append($0) }
        XCTAssertEqual(offer.size, size)
        let preparationEvents = await preparation.all()
        XCTAssertEqual(preparationEvents.first?.stage, .preparing)
        XCTAssertEqual(preparationEvents.last?.stage, .queued)
        XCTAssertTrue(preparationEvents.contains { $0.transferredBytes > 0 && $0.stage == .preparing })

        // Simulate an interrupted transfer. The production receive method must request this offset.
        let offset: Int64 = 256 * 1024
        try Data(repeating: 0, count: Int(offset)).write(to: receiverRoot.appendingPathComponent("incoming/\(offer.id).partial"))
        let connections = AsyncStream<NWConnection>.makeStream()
        let ready = AsyncThrowingStream<Bool, Error>.makeStream()
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connections.continuation.yield($0) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.continuation.yield(true); ready.continuation.finish()
            case .failed(let error): ready.continuation.finish(throwing: error)
            default: break
            }
        }
        listener.start(queue: DispatchQueue(label: "relay.large-transfer-test"))
        defer { listener.cancel(); connections.continuation.finish() }
        for try await _ in ready.stream { break }
        let port = try XCTUnwrap(listener.port)
        let outgoing = Channel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        async let connected: Void = outgoing.start()
        var iterator = connections.stream.makeAsyncIterator()
        let receivedConnection = await iterator.next()
        let incoming = Channel(try XCTUnwrap(receivedConnection))
        try await incoming.start()
        try await connected
        defer { incoming.close(); outgoing.close() }
        let receivedProgress = ProgressLog()
        let sentProgress = ProgressLog()
        async let saved: URL = receiver.receive(offer, channel: incoming) { await receivedProgress.append($0) }
        let resume = try await outgoing.receiveMessage()
        XCTAssertEqual(resume.type, "file.ready")
        XCTAssertEqual(resume.size, offset)
        try await sender.send(offer, channel: outgoing, resumeOffset: try XCTUnwrap(resume.size)) { await sentProgress.append($0) }
        let receipt = try await outgoing.receiveMessage()
        XCTAssertEqual(receipt.type, "file.saved")
        XCTAssertEqual(receipt.sha256, offer.sha256)
        let savedURL = try await saved
        let savedSize = try savedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertEqual(savedSize, Int(size))
        try await sender.acknowledge(id: offer.id, sha256: try XCTUnwrap(receipt.sha256))
        let queue = try await sender.next()
        XCTAssertNil(queue)
        let received = await receivedProgress.all()
        let sent = await sentProgress.all()
        XCTAssertEqual(received.first?.stage, .preparing)
        XCTAssertEqual(received.last?.stage, .completed)
        XCTAssertTrue(received.contains { $0.stage == .verifying })
        XCTAssertEqual(received.filter { $0.stage == .transferring }.first?.transferredBytes, offset)
        XCTAssertEqual(sent.first?.transferredBytes, offset)
        XCTAssertEqual(sent.last?.transferredBytes, size)
        XCTAssertTrue(sent.allSatisfy { (0...size).contains($0.transferredBytes) })
        XCTAssertTrue(received.allSatisfy { (0...size).contains($0.transferredBytes) })
        let bytes = received.filter { $0.stage == .transferring }.map(\.transferredBytes)
        XCTAssertEqual(bytes, bytes.sorted())
    }

    func testRejectsFileOneByteAboveOneGBBeforeCopying() async throws {
        XCTAssertEqual(TransferStore.maximumSize, 1_000_000_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("oversize.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: 1_000_000_001)
        try file.close()
        let store = try TransferStore(root: root.appendingPathComponent("queue"), receiveFolder: root.appendingPathComponent("received"))
        do { _ = try await store.enqueue(source); XCTFail("Oversized file accepted") } catch {}
        let pending = try await store.next()
        XCTAssertNil(pending)
    }
}
