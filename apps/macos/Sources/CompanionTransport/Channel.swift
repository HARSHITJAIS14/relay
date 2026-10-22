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
            refreshDeadline()
            connection.start(queue: queue)
        }
    }

    // Timeout idle connections, not an active large transfer's total duration.
    private func refreshDeadline() {
        queue.async { [weak self] in
            guard let self else { return }
            self.deadline?.cancel()
            let timeout = DispatchWorkItem { [weak self] in self?.connection.cancel() }
            self.deadline = timeout
            self.queue.asyncAfter(deadline: .now() + 120, execute: timeout)
        }
    }

    func close() {
        queue.async { [self] in deadline?.cancel(); connection.cancel() }
    }

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
                else if let data, data.count == count { self.refreshDeadline(); continuation.resume(returning: data) }
                else { continuation.resume(throwing: CompanionError.message("Incomplete network data.")) }
            }
        }
    }

    func send(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { self.refreshDeadline(); continuation.resume() }
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

public struct WireMessage: Codable, Sendable {
    public var version = 1
    public var type: String
    public var token: String?
    public var name: String?
    public var id: String?
    public var size: Int64?
    public var sha256: String?
    public var code: String?
    public var message: String?
    public var text: String?
    public var seq: Int?
    public var timestamp: Int64?
    public var mode: String?
    
    // v1.4 additions for SMS, Calls, and Notifications
    public var payload: String?
    public var number: String?
    public var callerName: String?
    public var state: String?
    public var callId: String?
    public var replyId: String?
    public var status: String?
    public var threadId: Int64?
    public var address: String?
    public var packageName: String?
    public var appName: String?
    public var title: String?
    public var canReply: Bool?
    public var sendId: String?

    public init(
        version: Int = 1,
        type: String,
        token: String? = nil,
        name: String? = nil,
        id: String? = nil,
        size: Int64? = nil,
        sha256: String? = nil,
        code: String? = nil,
        message: String? = nil,
        text: String? = nil,
        seq: Int? = nil,
        timestamp: Int64? = nil,
        mode: String? = nil,
        payload: String? = nil,
        number: String? = nil,
        callerName: String? = nil,
        state: String? = nil,
        callId: String? = nil,
        replyId: String? = nil,
        status: String? = nil,
        threadId: Int64? = nil,
        address: String? = nil,
        packageName: String? = nil,
        appName: String? = nil,
        title: String? = nil,
        canReply: Bool? = nil,
        sendId: String? = nil
    ) {
        self.version = version
        self.type = type
        self.token = token
        self.name = name
        self.id = id
        self.size = size
        self.sha256 = sha256
        self.code = code
        self.message = message
        self.text = text
        self.seq = seq
        self.timestamp = timestamp
        self.mode = mode
        self.payload = payload
        self.number = number
        self.callerName = callerName
        self.state = state
        self.callId = callId
        self.replyId = replyId
        self.status = status
        self.threadId = threadId
        self.address = address
        self.packageName = packageName
        self.appName = appName
        self.title = title
        self.canReply = canReply
        self.sendId = sendId
    }
}
