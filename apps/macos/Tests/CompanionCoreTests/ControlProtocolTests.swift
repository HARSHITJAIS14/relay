import Foundation
import XCTest
@testable import CompanionCore

final class ControlProtocolTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/\(name).json"))
    }

    func testSharedHelloFixture() throws {
        let hello = try ControlCodec.decode(fixture("hello"))
        XCTAssertEqual(hello.body.deviceName, "Test phone")
        XCTAssertEqual(hello.body.capabilities, [])
    }

    func testEveryPossibleSplitOfFrame() throws {
        let hello = try ControlCodec.decode(fixture("hello"))
        let bytes = try ControlCodec.frame(hello)
        for split in 0...bytes.count {
            var parser = FrameDecoder()
            var received: [ControlEnvelope] = []
            try parser.append(bytes.prefix(split)) { received.append($0) }
            try parser.append(bytes.dropFirst(split)) { received.append($0) }
            XCTAssertEqual(received, [hello], "Split at \(split)")
        }
    }

    func testCoalescedFramesAndBytewiseInput() throws {
        let hello = try ControlCodec.decode(fixture("hello"))
        let frame = try ControlCodec.frame(hello)
        var parser = FrameDecoder()
        var received: [ControlEnvelope] = []
        try parser.append(frame + frame) { received.append($0) }
        for byte in frame {
            try parser.append(Data([byte])) { received.append($0) }
        }
        XCTAssertEqual(received, [hello, hello, hello])
    }

    func testRejectsLengthBeforePayload() {
        for header in [Data([0, 0, 0, 0]), Data([0, 8, 0, 1]), Data([255, 255, 255, 255])] {
            var parser = FrameDecoder()
            XCTAssertThrowsError(try parser.append(header) { _ in XCTFail("Unexpected frame") }) {
                XCTAssertEqual($0 as? ProtocolFailure, .invalidLength)
            }
        }
    }

    func testSharedInvalidFixtures() throws {
        XCTAssertThrowsError(try ControlCodec.decode(fixture("unsupported-version"))) {
            XCTAssertEqual($0 as? ProtocolFailure, .incompatibleVersion)
        }
        XCTAssertThrowsError(try ControlCodec.decode(fixture("invalid-id"))) {
            XCTAssertEqual($0 as? ProtocolFailure, .malformedEnvelope)
        }
    }

    func testMalformedPayloadAndParserReset() throws {
        var parser = FrameDecoder()
        XCTAssertThrowsError(try parser.append(Data([0, 0, 0, 1, 255])) { _ in })
        let hello = try ControlCodec.decode(fixture("hello"))
        var count = 0
        try parser.append(ControlCodec.frame(hello)) { _ in count += 1 }
        XCTAssertEqual(count, 1)
    }
}
