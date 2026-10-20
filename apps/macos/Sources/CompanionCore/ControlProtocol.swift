import Foundation

public enum ProtocolFailure: Error, Equatable {
    case invalidLength
    case malformedEnvelope
    case incompatibleVersion
    case unsupportedMessage
}

/// The initial protocol deliberately implements only capability negotiation.
/// All networking must authenticate the peer before delivering frames here.
public struct Hello: Codable, Equatable, Sendable {
    public let deviceName: String
    public let capabilities: [String]

    public init(deviceName: String, capabilities: [String]) {
        self.deviceName = deviceName
        self.capabilities = capabilities
    }
}

public struct ControlEnvelope: Codable, Equatable, Sendable {
    public let protocolMajor: Int
    public let protocolMinor: Int
    public let type: String
    public let messageId: String
    public let sessionId: String
    public let body: Hello

    public init(messageId: String, sessionId: String, body: Hello) {
        protocolMajor = 1
        protocolMinor = 0
        type = "session.hello"
        self.messageId = messageId
        self.sessionId = sessionId
        self.body = body
    }

    public func validate() throws {
        guard protocolMajor == 1 else { throw ProtocolFailure.incompatibleVersion }
        guard protocolMinor >= 0 else { throw ProtocolFailure.malformedEnvelope }
        guard type == "session.hello" else { throw ProtocolFailure.unsupportedMessage }
        guard UUID(uuidString: messageId) != nil,
              !sessionId.isEmpty, sessionId.utf8.count <= 128,
              !body.deviceName.isEmpty, body.deviceName.utf8.count <= 128,
              body.capabilities.count <= 32,
              body.capabilities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
              Set(body.capabilities).count == body.capabilities.count
        else { throw ProtocolFailure.malformedEnvelope }
    }
}

public enum ControlCodec {
    public static let maxPayloadBytes = 512 * 1024

    public static func decode(_ payload: Data) throws -> ControlEnvelope {
        guard !payload.isEmpty, payload.count <= maxPayloadBytes else {
            throw ProtocolFailure.invalidLength
        }
        let envelope: ControlEnvelope
        do {
            envelope = try JSONDecoder().decode(ControlEnvelope.self, from: payload)
        } catch {
            throw ProtocolFailure.malformedEnvelope
        }
        try envelope.validate()
        return envelope
    }

    public static func frame(_ envelope: ControlEnvelope) throws -> Data {
        try envelope.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(envelope)
        guard payload.count <= maxPayloadBytes else { throw ProtocolFailure.invalidLength }
        let length = UInt32(payload.count)
        var result = Data([
            UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),
            UInt8((length >> 8) & 255), UInt8(length & 255)
        ])
        result.append(payload)
        return result
    }
}

/// Incremental parser with at most one bounded payload buffered. It tolerates
/// arbitrary TCP fragmentation/coalescing and rejects lengths before allocation.
public struct FrameDecoder {
    private var header = Data()
    private var payload = Data()
    private var expectedLength: Int?

    public init() {}

    public mutating func append(_ bytes: Data, onFrame: (ControlEnvelope) throws -> Void) throws {
        do {
            for byte in bytes {
                guard let expectedLength else {
                    header.append(byte)
                    if header.count == 4 {
                        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                        guard length > 0, length <= ControlCodec.maxPayloadBytes else {
                            throw ProtocolFailure.invalidLength
                        }
                        self.expectedLength = Int(length)
                        header.removeAll(keepingCapacity: true)
                    }
                    continue
                }
                payload.append(byte)
                if payload.count == expectedLength {
                    let message = try ControlCodec.decode(payload)
                    payload.removeAll(keepingCapacity: true)
                    self.expectedLength = nil
                    try onFrame(message)
                }
            }
        } catch {
            self = FrameDecoder()
            throw error
        }
    }
}
