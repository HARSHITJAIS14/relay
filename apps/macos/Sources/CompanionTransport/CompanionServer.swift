import Foundation
import Combine
import Network
import Security
import OSLog
import ServiceManagement
import UserNotifications

public struct MirroredNotification: Identifiable, Sendable, Codable {
    public let id: String
    public let packageName: String
    public let appName: String
    public let title: String
    public let text: String
    public let timestamp: Int64
    public let canReply: Bool

    public init(id: String, packageName: String, appName: String, title: String, text: String, timestamp: Int64, canReply: Bool) {
        self.id = id
        self.packageName = packageName
        self.appName = appName
        self.title = title
        self.text = text
        self.timestamp = timestamp
        self.canReply = canReply
    }
}

public struct SmsThread: Identifiable, Sendable, Codable {
    public var id: String { String(threadId) }
    public let threadId: Int64
    public let address: String
    public let contactName: String
    public let snippet: String
    public let date: Int64
    public let unreadCount: Int

    public init(threadId: Int64, address: String, contactName: String, snippet: String, date: Int64, unreadCount: Int) {
        self.threadId = threadId
        self.address = address
        self.contactName = contactName
        self.snippet = snippet
        self.date = date
        self.unreadCount = unreadCount
    }

    enum CodingKeys: String, CodingKey {
        case threadId, address, contactName, snippet, date, unreadCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.threadId = try container.decodeIfPresent(Int64.self, forKey: .threadId) ?? 0
        let addr = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        self.address = addr
        self.contactName = try container.decodeIfPresent(String.self, forKey: .contactName) ?? (addr.isEmpty ? "Unknown" : addr)
        self.snippet = try container.decodeIfPresent(String.self, forKey: .snippet) ?? ""
        self.date = try container.decodeIfPresent(Int64.self, forKey: .date) ?? 0
        self.unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
    }
}

public struct SmsMessage: Identifiable, Sendable, Codable {
    public var idStr: String { String(id) }
    public let id: Int64
    public let threadId: Int64
    public let address: String
    public let body: String
    public let date: Int64
    public let type: Int?
    public let isFromMe: Bool?

    public init(id: Int64, threadId: Int64, address: String, body: String, date: Int64, type: Int? = nil, isFromMe: Bool? = nil) {
        self.id = id
        self.threadId = threadId
        self.address = address
        self.body = body
        self.date = date
        self.type = type
        self.isFromMe = isFromMe
    }

    enum CodingKeys: String, CodingKey {
        case id, threadId, address, body, date, type, isFromMe
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        self.threadId = try container.decodeIfPresent(Int64.self, forKey: .threadId) ?? 0
        self.address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        self.body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        self.date = try container.decodeIfPresent(Int64.self, forKey: .date) ?? 0
        self.type = try container.decodeIfPresent(Int.self, forKey: .type)
        self.isFromMe = try container.decodeIfPresent(Bool.self, forKey: .isFromMe)
    }
}

public struct ActiveCall: Identifiable, Sendable, Codable {
    public var id: String { callId }
    public let callId: String
    public let number: String
    public let callerName: String
    public let state: String // "RINGING", "OFFHOOK", "IDLE", "MISSED"
    public let timestamp: Int64

    public init(callId: String, number: String, callerName: String, state: String, timestamp: Int64) {
        self.callId = callId
        self.number = number
        self.callerName = callerName
        self.state = state
        self.timestamp = timestamp
    }
}

private final class TrustGate: @unchecked Sendable {
    private let lock = NSLock()
    private var peer: String?
    private var until = Date.distantPast
    func update(peer: String?, until: Date) {
        lock.lock(); defer { lock.unlock() }
        self.peer = peer
        self.until = until
    }
    func accepts(_ fingerprint: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return peer == fingerprint || (peer == nil && until > Date())
    }
}

private func verifyPeerTrust(trust: sec_trust_t, gate: TrustGate, complete: @escaping sec_protocol_verify_complete_t) {
    let value = sec_trust_copy_ref(trust).takeRetainedValue()
    guard let certificates = SecTrustCopyCertificateChain(value) as? [SecCertificate],
          let leaf = certificates.first else {
        Logger(subsystem: "dev.companion", category: "tls").error("TLS client certificate chain is missing.")
        complete(false); return
    }
    let fingerprint = digest(SecCertificateCopyData(leaf) as Data)
    guard gate.accepts(fingerprint) else {
        Logger(subsystem: "dev.companion", category: "tls").error("Peer is neither trusted nor within an active invitation.")
        complete(false); return
    }
    SecTrustSetAnchorCertificates(value, [leaf] as CFArray)
    SecTrustSetAnchorCertificatesOnly(value, true)
    SecTrustSetPolicies(value, SecPolicyCreateSSL(false, nil))
    var error: CFError?
    let accepted = SecTrustEvaluateWithError(value, &error)
    if !accepted {
        Logger(subsystem: "dev.companion", category: "tls").error("Certificate rejected: \(String(describing: error), privacy: .public)")
    }
    complete(accepted)
}

private func makeVerifyBlock(gate: TrustGate) -> sec_protocol_verify_t {
    return { _, trust, complete in
        verifyPeerTrust(trust: trust, gate: gate, complete: complete)
    }
}



private struct TrustedPeer: Codable {
    let fingerprint: String
    let name: String
}

public struct PairingRequest: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let code: String
    let fingerprint: String
}

@MainActor
public final class CompanionServer: ObservableObject {
    @Published public private(set) var status = "Starting…"
    @Published public private(set) var invitation = ""
    @Published public private(set) var pending: PairingRequest?
    @Published public private(set) var peerName: String?
    @Published public private(set) var lastTransfer = ""
    @Published public private(set) var fingerprint = ""
    @Published public private(set) var inbox: [InboxItem] = []
    @Published public private(set) var notifications: [MirroredNotification] = []
    @Published public private(set) var smsThreads: [SmsThread] = []
    @Published public private(set) var activeThreadMessages: [SmsMessage] = []
    @Published public var activeThreadId: Int64? = nil
    @Published public private(set) var activeCall: ActiveCall? = nil
    private var queuedCommands: [WireMessage] = []
    @Published public var clipboardSyncEnabled: Bool = true
    @Published public var launchAtLogin: Bool = false {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Failed to update launch at login: \(error)")
            }
        }
    }
    public let receiveFolder: URL

    private let root: URL
    private var store: TransferStore?
    private var listener: NWListener?
    private let gate = TrustGate()
    private var trusted: TrustedPeer?
    private var invitationToken: String?
    private var expires = Date.distantPast
    private var channels: [UUID: Channel] = [:]
    @Published public var activeCaptureRequest: String? = nil
    private var pendingCaptureRequest: (id: String, mode: String, expires: Date)?
    private var busy = false
    private var starting = false
    private let clipboardMonitor = ClipboardMonitor()
    private var pendingClipboardText: String?
    private var macClipboardSeq: Int = 1
    private var macClipboardTimestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    private var latestClipboardText: String?
    private var netService: NetService?

    public init() {
        let relayRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Relay")
        let legacyRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Companion")
        if !FileManager.default.fileExists(atPath: relayRoot.path) && FileManager.default.fileExists(atPath: legacyRoot.path) {
            try? FileManager.default.copyItem(at: legacyRoot, to: relayRoot)
        }
        root = FileManager.default.fileExists(atPath: relayRoot.path) ? relayRoot : legacyRoot
        receiveFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Relay")
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    public func start() async {
        guard listener == nil, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let peerFile = root.appendingPathComponent("peer.json")
            if FileManager.default.fileExists(atPath: peerFile.path) {
                trusted = try JSONDecoder().decode(TrustedPeer.self, from: Data(contentsOf: peerFile))
                peerName = trusted?.name
            }
            if let trusted {
                let peerStore = try TransferStore(root: root.appendingPathComponent(trusted.fingerprint), receiveFolder: receiveFolder)
                store = peerStore
                inbox = (try? await peerStore.getInboxItems()) ?? []
            }
            let identity = try await Task.detached { try LocalIdentity.load() }.value
            fingerprint = identity.fingerprint
            gate.update(peer: trusted?.fingerprint, until: expires)
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity.identity)!)
            sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
            let gate = self.gate
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, makeVerifyBlock(gate: gate), DispatchQueue(label: "dev.companion.trust"))
            let listener = try NWListener(using: NWParameters(tls: tls), on: 18444)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.status = self?.trusted == nil ? "Ready to pair" : "Waiting for phone"
                        self?.advertiseBonjour()
                    case .failed(let error):
                        self?.status = "Connection unavailable: \(error.localizedDescription)"
                    default: break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: DispatchQueue(label: "dev.companion.listener"))
            clipboardMonitor.onClipboardChanged = { [weak self] text in
                Task { @MainActor in
                    guard let self, self.clipboardSyncEnabled, self.trusted != nil else { return }
                    self.macClipboardSeq += 1
                    self.macClipboardTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
                    self.latestClipboardText = text
                    self.pendingClipboardText = text
                    for channel in self.channels.values {
                        try? await channel.sendMessage(WireMessage(type: "clipboard.sync", text: text, seq: self.macClipboardSeq, timestamp: self.macClipboardTimestamp))
                    }
                }
            }
            if let current = clipboardMonitor.currentString, !current.isEmpty {
                latestClipboardText = current
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            clipboardMonitor.start()
            if trusted == nil, let ip = Self.detectLocalIP() {
                createInvitation(host: ip)
            }
        } catch { status = error.localizedDescription }
    }

    public func advertiseBonjour() {
        stopBonjour()
        let hostName = Host.current().localizedName ?? "Mac"
        let service = NetService(domain: "local.", type: "_relay._tcp.", name: "Relay (\(hostName))", port: 18444)
        if !fingerprint.isEmpty {
            let txtData = NetService.data(fromTXTRecord: [
                "v": "1".data(using: .utf8)!,
                "id": fingerprint.data(using: .utf8)!
            ])
            service.setTXTRecord(txtData)
        }
        service.publish()
        netService = service
    }

    public func stopBonjour() {
        netService?.stop()
        netService = nil
    }

    public func handleSleep() {
        stopBonjour()
        channels.values.forEach { $0.close() }
        channels.removeAll()
    }

    public func handleWake() async {
        advertiseBonjour()
        if trusted == nil, let ip = Self.detectLocalIP() {
            createInvitation(host: ip)
        }
    }

    public static func detectLocalIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let ifa_addr = ptr.pointee.ifa_addr,
                  ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ifa_addr, socklen_t(ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)
                if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                    return ip
                }
            }
        }
        return nil
    }

    public func stop() {
        stopBonjour()
        listener?.cancel()
        listener = nil
        channels.values.forEach { $0.close() }
        channels.removeAll()
        status = "Stopped"
    }

    public func createInvitation(host: String) {
        guard trusted == nil, listener != nil, !fingerprint.isEmpty,
              !host.isEmpty, !host.contains("/") else { return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return }
        invitationToken = bytes.map { String(format: "%02x", $0) }.joined()
        expires = Date().addingTimeInterval(600)
        pending = nil
        var components = URLComponents()
        components.scheme = "companion"
        components.host = host
        components.port = 18444
        components.path = "/pair"
        components.queryItems = [
            URLQueryItem(name: "pin", value: fingerprint),
            URLQueryItem(name: "token", value: invitationToken!)
        ]
        invitation = components.string ?? ""
        try? invitation.write(to: root.appendingPathComponent("invitation.txt"), atomically: true, encoding: .utf8)
        gate.update(peer: nil, until: expires)
        status = "Invitation ready for 10 minutes"
    }

    public func approve() {
        guard let pending, expires > Date() else { status = "Pairing request expired"; return }
        do {
            let peer = TrustedPeer(fingerprint: pending.fingerprint, name: pending.name)
            let peerStore = try TransferStore(root: root.appendingPathComponent(peer.fingerprint), receiveFolder: receiveFolder)
            try JSONEncoder().encode(peer).write(to: root.appendingPathComponent("peer.json"), options: .atomic)
            trusted = peer
            store = peerStore
            try? FileManager.default.removeItem(at: root.appendingPathComponent("invitation.txt"))
            Task { @MainActor in
                self.inbox = (try? await peerStore.getInboxItems()) ?? []
            }
            peerName = peer.name
            invitationToken = nil
            invitation = ""
            self.pending = nil
            gate.update(peer: peer.fingerprint, until: .distantPast)
            status = "Paired with \(peer.name)"
        } catch { status = error.localizedDescription }
    }

    public func reject() {
        pending = nil
        invitationToken = nil
        invitation = ""
        expires = .distantPast
        gate.update(peer: trusted?.fingerprint, until: .distantPast)
    }

    public func forget() {
        do {
            let file = root.appendingPathComponent("peer.json")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            trusted = nil
            store = nil
            inbox = []
            notifications = []
            smsThreads = []
            activeThreadMessages = []
            activeThreadId = nil
            activeCall = nil
            queuedCommands = []
            peerName = nil
            reject()
            channels.values.forEach { $0.close() }
            status = "Ready to pair"
        } catch { status = error.localizedDescription }
    }

    public func enqueue(_ url: URL) async {
        guard trusted != nil, let store else { return }
        do {
            let offer = try await store.enqueue(url)
            lastTransfer = "Queued \(offer.name). Open Companion on your phone to receive."
        } catch { lastTransfer = error.localizedDescription }
    }

    public func refreshInbox() async {
        guard let store else { return }
        inbox = (try? await store.getInboxItems()) ?? []
    }

    public func sendText(_ text: String) async {
        guard trusted != nil, let store else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await store.enqueueText(trimmed)
            lastTransfer = "Queued text/link. Open Companion on your phone to receive."
        } catch {
            lastTransfer = error.localizedDescription
        }
    }

    public func removeInboxItem(id: String) async {
        guard let store else { return }
        try? await store.removeInboxItem(id: id)
        await refreshInbox()
    }

    public func requestCapture(mode: String) async {
        guard trusted != nil else { return }
        let id = UUID().uuidString.lowercased()
        let expires = Date().addingTimeInterval(300)
        pendingCaptureRequest = (id: id, mode: mode, expires: expires)
        activeCaptureRequest = mode
        let title = (mode == "scan") ? "Document Scan" : "Photo"
        lastTransfer = "Requested \(title) from phone. Open Companion on your phone."
        for channel in channels.values {
            try? await channel.sendMessage(WireMessage(type: "capture.request", id: id, mode: mode))
        }
    }

    public func cancelCapture() {
        pendingCaptureRequest = nil
        activeCaptureRequest = nil
        lastTransfer = "Capture cancelled."
    }

    private func postMacNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Logger(subsystem: "dev.companion", category: "notification").error("Failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    public func replyToNotification(id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let cmd = WireMessage(type: "notification.reply", id: id, text: trimmed, replyId: UUID().uuidString.lowercased())
        queueCommand(cmd)
    }

    public func dismissNotification(id: String) {
        notifications.removeAll { $0.id == id }
        let cmd = WireMessage(type: "notification.dismiss", id: id)
        queueCommand(cmd)
    }

    public func clearAllNotifications() {
        notifications.removeAll()
    }

    public func requestSmsSync() {
        queueCommand(WireMessage(type: "sms.sync_request"))
    }

    public func selectSmsThread(threadId: Int64) {
        activeThreadId = threadId
        queueCommand(WireMessage(type: "sms.thread_request", threadId: threadId))
    }

    public func sendSms(address: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !address.isEmpty else { return }
        let sendId = UUID().uuidString.lowercased()
        let cmd = WireMessage(type: "sms.send", text: trimmed, threadId: activeThreadId, address: address, sendId: sendId)
        queueCommand(cmd)

        if let tid = activeThreadId {
            let optimisticMsg = SmsMessage(
                id: Int64(Date().timeIntervalSince1970 * 1000),
                threadId: tid,
                address: address,
                body: trimmed,
                date: Int64(Date().timeIntervalSince1970 * 1000),
                type: 2,
                isFromMe: true
            )
            activeThreadMessages.append(optimisticMsg)
        }
    }

    public func answerCall() {
        queueCommand(WireMessage(type: "call.answer"))
        if let current = activeCall {
            activeCall = ActiveCall(callId: current.callId, number: current.number, callerName: current.callerName, state: "OFFHOOK", timestamp: current.timestamp)
        }
        BluetoothHandsFreeController.shared.acceptCall()
    }

    public func rejectCall() {
        queueCommand(WireMessage(type: "call.reject"))
        activeCall = nil
        BluetoothHandsFreeController.shared.endCall()
    }

    public func endCall() {
        queueCommand(WireMessage(type: "call.end"))
        activeCall = nil
        BluetoothHandsFreeController.shared.endCall()
    }

    public func declineCallWithSms(number: String, message: String) {
        let trimmedMsg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        queueCommand(WireMessage(type: "call.decline_with_sms", message: trimmedMsg, number: number))
        activeCall = nil
        BluetoothHandsFreeController.shared.endCall()
    }

    public func dialNumber(_ number: String) {
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queueCommand(WireMessage(type: "call.dial", number: trimmed))
        activeCall = ActiveCall(callId: UUID().uuidString.lowercased(), number: trimmed, callerName: trimmed, state: "OFFHOOK", timestamp: Int64(Date().timeIntervalSince1970 * 1000))
        BluetoothHandsFreeController.shared.routeAudioToMac()
    }

    public func dismissCall() {
        activeCall = nil
    }

    private func queueCommand(_ cmd: WireMessage) {
        queuedCommands.append(cmd)
    }

    private func accept(_ connection: NWConnection) {
        guard channels.count < 4 else { connection.cancel(); return }
        let id = UUID()
        let channel = Channel(connection)
        channels[id] = channel
        Task {
            defer { channel.close(); channels.removeValue(forKey: id) }
            do {
                try await channel.start()
                // TLS 1.3 can report transport readiness before peer metadata is
                // populated. The first authenticated read completes that flight.
                let request = try await channel.receiveMessage()
                let peer = try channel.peerFingerprint()
                try await handle(request, peer: peer, channel: channel)
            } catch {
                Logger(subsystem: "dev.companion", category: "connection").error("Connection failed: \(error.localizedDescription, privacy: .public)")
                status = "Connection issue: \(error.localizedDescription)"
                try? await channel.sendMessage(WireMessage(type: "error", message: error.localizedDescription))
            }
        }
    }

    private func handle(_ request: WireMessage, peer: String, channel: Channel) async throws {
        if request.type == "pair.request" {
            if trusted?.fingerprint == peer {
                try await channel.sendMessage(WireMessage(type: "pair.complete")); return
            }
            guard trusted == nil, expires > Date(), let token = invitationToken,
                  request.token == token, let name = request.name,
                  !name.isEmpty, name.utf8.count <= 128 else {
                throw CompanionError.message("Pairing invitation is invalid or expired.")
            }
            let code = String(digest(Data("\(fingerprint):\(peer):\(token)".utf8)).prefix(8)).uppercased()
            guard pending == nil || pending?.fingerprint == peer else {
                throw CompanionError.message("Another pairing request is pending.")
            }
            pending = PairingRequest(id: peer, name: name, code: code, fingerprint: peer)
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("auto_approve").path) {
                approve()
                try await channel.sendMessage(WireMessage(type: "pair.complete"))
            } else {
                try await channel.sendMessage(WireMessage(type: "pair.pending", code: code))
            }
            return
        }
        guard trusted?.fingerprint == peer else { throw CompanionError.message("Pairing approval required.") }
        status = "Connected to \(trusted!.name)"
        guard let store else { throw CompanionError.message("Storage unavailable.") }
        switch request.type {
        case "session.check":
            try await channel.sendMessage(WireMessage(type: "session.ready"))
        case "file.offer":
            guard !busy, let id = request.id, let name = request.name, let size = request.size,
                  let hash = request.sha256 else { throw CompanionError.message("Invalid offer or transfer busy.") }
            busy = true
            defer { busy = false }
            let saved = try await store.receive(FileOffer(id: id, name: name, size: size, sha256: hash), channel: channel)
            if activeCaptureRequest != nil {
                activeCaptureRequest = nil
                pendingCaptureRequest = nil
                lastTransfer = "Received capture: \(saved.lastPathComponent)"
            } else {
                lastTransfer = "Saved \(saved.lastPathComponent)"
            }
        case "file.next":
            guard !busy else { throw CompanionError.message("Transfer busy.") }
            busy = true
            defer { busy = false }
            guard let offer = try await store.next() else {
                try await channel.sendMessage(WireMessage(type: "file.empty")); return
            }
            try await channel.sendMessage(WireMessage(type: "file.offer", name: offer.name, id: offer.id,
                                                      size: offer.size, sha256: offer.sha256))
            let ready = try await channel.receiveMessage()
            guard ready.type == "file.ready", ready.id == offer.id else {
                throw CompanionError.message("Receiver is not ready.")
            }
            let resumeOffset = ready.size ?? 0
            try await store.send(offer, channel: channel, resumeOffset: resumeOffset)
            let receipt = try await channel.receiveMessage()
            guard receipt.type == "file.saved", receipt.id == offer.id, receipt.sha256 == offer.sha256 else {
                throw CompanionError.message("Invalid saved receipt.")
            }
            try await store.acknowledge(id: offer.id, sha256: offer.sha256)
            lastTransfer = "Sent \(offer.name)"
        case "inbox.item":
            guard let text = request.text, !text.isEmpty else { throw CompanionError.message("Invalid inbox item.") }
            let id = request.id ?? UUID().uuidString.lowercased()
            let item = InboxItem(id: id, text: text)
            try await store.addInboxItem(item)
            await refreshInbox()
            try await channel.sendMessage(WireMessage(type: "inbox.receipt", id: id))
            lastTransfer = "Received: \(text.prefix(35))"
        case "inbox.next":
            if let item = try await store.nextPendingText() {
                try await channel.sendMessage(WireMessage(type: "inbox.item", id: item.id, text: item.text))
                let receipt = try await channel.receiveMessage()
                if receipt.type == "inbox.receipt", receipt.id == item.id {
                    try await store.acknowledgeText(id: item.id)
                    lastTransfer = "Sent: \(item.text.prefix(35))"
                }
            } else {
                try await channel.sendMessage(WireMessage(type: "inbox.empty"))
            }
        case "clipboard.sync":
            guard let text = request.text, !text.isEmpty else { return }
            clipboardMonitor.applyRemoteText(text)
            macClipboardSeq += 1
            macClipboardTimestamp = request.timestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
            latestClipboardText = text
            pendingClipboardText = nil
            lastTransfer = "Synced clipboard from phone (\(text.prefix(25))...)"
            try await channel.sendMessage(WireMessage(type: "clipboard.receipt", seq: macClipboardSeq, timestamp: macClipboardTimestamp))
        case "clipboard.poll":
            let clientSeq = request.seq ?? 0
            if (clientSeq < macClipboardSeq || clientSeq == 0), let text = latestClipboardText {
                try await channel.sendMessage(WireMessage(type: "clipboard.sync", text: text, seq: macClipboardSeq, timestamp: macClipboardTimestamp))
            } else if let text = pendingClipboardText {
                pendingClipboardText = nil
                try await channel.sendMessage(WireMessage(type: "clipboard.sync", text: text, seq: macClipboardSeq, timestamp: macClipboardTimestamp))
            } else {
                try await channel.sendMessage(WireMessage(type: "clipboard.empty"))
            }
        case "capture.poll":
            if let req = pendingCaptureRequest, req.expires > Date() {
                try await channel.sendMessage(WireMessage(type: "capture.request", id: req.id, mode: req.mode))
            } else {
                pendingCaptureRequest = nil
                try await channel.sendMessage(WireMessage(type: "capture.empty"))
            }
        case "capture.dismiss":
            if let req = pendingCaptureRequest, req.id == request.id {
                pendingCaptureRequest = nil
                activeCaptureRequest = nil
            }
            try await channel.sendMessage(WireMessage(type: "capture.receipt"))
        case "notification.push":
            let notif = MirroredNotification(
                id: request.id ?? UUID().uuidString.lowercased(),
                packageName: request.packageName ?? "",
                appName: (request.appName?.isEmpty == false ? request.appName : request.packageName) ?? "App",
                title: request.title ?? "",
                text: request.text ?? "",
                timestamp: request.timestamp ?? Int64(Date().timeIntervalSince1970 * 1000),
                canReply: request.canReply ?? false
            )
            notifications.removeAll { $0.id == notif.id }
            notifications.insert(notif, at: 0)
            if notifications.count > 100 { notifications.removeLast() }
            postMacNotification(title: "\(notif.appName): \(notif.title)", body: notif.text)
            try await channel.sendMessage(WireMessage(type: "notification.receipt", id: notif.id))
        case "notification.dismiss":
            if let id = request.id {
                notifications.removeAll { $0.id == id }
            }
            try await channel.sendMessage(WireMessage(type: "notification.receipt"))
        case "notification.reply_ack":
            lastTransfer = "Reply delivered to phone"
            try await channel.sendMessage(WireMessage(type: "ok"))
        case "sms.incoming":
            let sender = (request.callerName?.isEmpty == false ? request.callerName : request.address) ?? "Unknown"
            let body = request.text ?? ""
            postMacNotification(title: "SMS from \(sender)", body: body)
            queueCommand(WireMessage(type: "sms.sync_request"))
            if let tid = activeThreadId {
                queueCommand(WireMessage(type: "sms.thread_request", threadId: tid))
            }
            try await channel.sendMessage(WireMessage(type: "sms.receipt"))
        case "sms.threads":
            if let payload = request.payload, let data = payload.data(using: .utf8) {
                do {
                    let threads = try JSONDecoder().decode([SmsThread].self, from: data)
                    self.smsThreads = threads
                    Logger(subsystem: "dev.companion", category: "sms").info("Updated \(threads.count) SMS threads")
                } catch {
                    Logger(subsystem: "dev.companion", category: "sms").error("Failed to decode SMS threads: \(error)")
                }
            }
            try await channel.sendMessage(WireMessage(type: "sms.threads_receipt"))
        case "sms.messages":
            if let payload = request.payload, let data = payload.data(using: .utf8) {
                do {
                    let messages = try JSONDecoder().decode([SmsMessage].self, from: data)
                    self.activeThreadMessages = messages
                    Logger(subsystem: "dev.companion", category: "sms").info("Updated \(messages.count) SMS messages")
                } catch {
                    Logger(subsystem: "dev.companion", category: "sms").error("Failed to decode SMS messages: \(error)")
                }
            }
            try await channel.sendMessage(WireMessage(type: "sms.messages_receipt"))
        case "sms.send_receipt":
            lastTransfer = "SMS dispatched from phone"
            try await channel.sendMessage(WireMessage(type: "ok"))
        case "call.state":
            let callState = request.state ?? "IDLE"
            let caller = (request.callerName?.isEmpty == false ? request.callerName : request.number) ?? "Unknown Caller"
            let number = request.number ?? ""
            let callId = request.callId ?? UUID().uuidString.lowercased()
            let timestamp = request.timestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
            if callState == "RINGING" {
                activeCall = ActiveCall(callId: callId, number: number, callerName: caller, state: "RINGING", timestamp: timestamp)
                postMacNotification(title: "Incoming Call", body: "\(caller) (\(number))")
            } else if callState == "OFFHOOK" {
                activeCall = ActiveCall(callId: callId, number: number, callerName: caller, state: "OFFHOOK", timestamp: timestamp)
            } else if callState == "MISSED" {
                activeCall = nil
                postMacNotification(title: "Missed Call", body: "\(caller) (\(number))")
            } else if callState == "IDLE" {
                activeCall = nil
                BluetoothHandsFreeController.shared.routeAudioToPhone()
            }
            try await channel.sendMessage(WireMessage(type: "call.receipt"))
        case "command.poll":
            if !queuedCommands.isEmpty {
                let cmd = queuedCommands.removeFirst()
                try await channel.sendMessage(cmd)

                if cmd.type == "sms.sync_request" {
                    let resp = try await channel.receiveMessage()
                    if resp.type == "sms.threads", let payload = resp.payload, let data = payload.data(using: .utf8) {
                        do {
                            let threads = try JSONDecoder().decode([SmsThread].self, from: data)
                            self.smsThreads = threads
                            Logger(subsystem: "dev.companion", category: "sms").info("Synchronously updated \(threads.count) SMS threads")
                        } catch {
                            Logger(subsystem: "dev.companion", category: "sms").error("Failed to decode SMS threads: \(error)")
                        }
                    }
                    try await channel.sendMessage(WireMessage(type: "sms.threads_receipt"))
                } else if cmd.type == "sms.thread_request" {
                    let resp = try await channel.receiveMessage()
                    if resp.type == "sms.messages", let payload = resp.payload, let data = payload.data(using: .utf8) {
                        do {
                            let messages = try JSONDecoder().decode([SmsMessage].self, from: data)
                            self.activeThreadMessages = messages
                            Logger(subsystem: "dev.companion", category: "sms").info("Synchronously updated \(messages.count) SMS messages")
                        } catch {
                            Logger(subsystem: "dev.companion", category: "sms").error("Failed to decode SMS messages: \(error)")
                        }
                    }
                    try await channel.sendMessage(WireMessage(type: "sms.messages_receipt"))
                } else if cmd.type == "sms.send" {
                    let receipt = try await channel.receiveMessage()
                    if receipt.type == "sms.send_receipt" {
                        lastTransfer = "SMS dispatched from phone"
                    }
                    try await channel.sendMessage(WireMessage(type: "ok"))
                } else if cmd.type == "notification.reply" {
                    let receipt = try await channel.receiveMessage()
                    if receipt.type == "notification.reply_ack" {
                        lastTransfer = "Reply delivered to phone"
                    }
                    try await channel.sendMessage(WireMessage(type: "ok"))
                } else if cmd.type == "call.answer" || cmd.type == "call.reject" || cmd.type == "call.end" || cmd.type == "call.dial" || cmd.type == "call.decline_with_sms" {
                    let receipt = try await channel.receiveMessage()
                    if receipt.type == "call.action_receipt" {
                        lastTransfer = "Call action executed on phone"
                    }
                    try await channel.sendMessage(WireMessage(type: "ok"))
                }
            } else {
                try await channel.sendMessage(WireMessage(type: "command.empty"))
            }
        default: throw CompanionError.message("Unsupported operation.")
        }
    }
}
