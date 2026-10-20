import Foundation
import Network
import Security

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}

/// One bounded request per TLS connection. Bulk file bytes are streamed separately.
final class Channel: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.companion.channel")
    private var deadline: DispatchWorkItem?

    init(_ connection: NWConnection) { self.connection = connection }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard once.claim() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard once.claim() else { return }
                    continuation.resume(throwing: CompanionError.message("Connection closed."))
                default: break
                }
            }
            let timeout = DispatchWorkItem { [weak self] in self?.connection.cancel() }
            deadline = timeout
            queue.asyncAfter(deadline: .now() + 120, execute: timeout)
            connection.start(queue: queue)
        }
    }

    func close() { deadline?.cancel(); connection.cancel() }

    func peerFingerprint() throws -> String {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            throw CompanionError.message("TLS metadata unavailable.")
        }
        var certificate: Data?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { item in
            if certificate == nil {
                certificate = SecCertificateCopyData(sec_certificate_copy_ref(item).takeRetainedValue()) as Data
            }
        }
        guard let certificate else { throw CompanionError.message("Client certificate required.") }
        return digest(certificate)
    }

    func read(_ count: Int) async throws -> Data {
        guard count > 0, count <= 512 * 1024 else { throw CompanionError.message("Invalid read length.") }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: CompanionError.message("Incomplete network data.")) }
            }
        }
    }

    func send(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func receiveMessage() async throws -> WireMessage {
        let header = try await read(4)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= 64 * 1024 else { throw CompanionError.message("Invalid control frame.") }
        let message = try JSONDecoder().decode(WireMessage.self, from: await read(Int(count)))
        guard message.version == 1 else { throw CompanionError.message("Unsupported protocol version.") }
        return message
    }

    func sendMessage(_ message: WireMessage) async throws {
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= 64 * 1024 else { throw CompanionError.message("Control frame too large.") }
        let count = UInt32(payload.count)
        var data = Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255),
                         UInt8((count >> 8) & 255), UInt8(count & 255)])
        data.append(payload)
        try await send(data)
    }
}

struct WireMessage: Codable, Sendable {
    var version = 1
    var type: String
    var token: String?
    var name: String?
    var id: String?
    var size: Int64?
    var sha256: String?
    var code: String?
    var message: String?
    var text: String?
    var seq: Int?
    var timestamp: Int64?
    var mode: String?
}
