import Foundation
import Security
import CryptoKit

enum CompanionError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

enum IdentityAccessError: Error, LocalizedError {
    case approvalRequired
    case unavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .approvalRequired: return "Allow Relay to use its saved secure connection."
        case .unavailable(let status): return "Relay’s saved connection is unavailable (\(status))."
        }
    }
}

protocol IdentityStorage: Sendable {
    func read(allowUserInteraction: Bool) throws -> Data?
    func save(_ data: Data, allowUserInteraction: Bool) throws
    func updateDisplayName()
}

struct KeychainIdentityStorage: IdentityStorage {
    // Keep the original service/account so updates preserve the identity and pairing.
    static let service = "dev.companion.tls-identity.v1"
    static let displayName = "Relay secure device connection"
    static let itemDescription = "Relay’s private connection key, used to recognize this Mac on your paired phone."

    private let serviceName: String
    private let account: String

    init(service: String = Self.service, account: String = "mac") {
        serviceName = service
        self.account = account
    }

    private var itemQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: serviceName,
         kSecAttrAccount as String: account]
    }

    private func query(allowUserInteraction: Bool) -> [String: Any] {
        var query = itemQuery
        // A normal launch must never unexpectedly request the user's password.
        // The UI explicitly retries with interaction only after the user continues.
        query[kSecUseAuthenticationUI as String] = allowUserInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        return query
    }

    private func check(_ status: OSStatus) throws {
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw IdentityAccessError.approvalRequired
        }
        guard status == errSecSuccess else { throw IdentityAccessError.unavailable(status) }
    }

    func read(allowUserInteraction: Bool) throws -> Data? {
        var query = query(allowUserInteraction: allowUserInteraction)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw IdentityAccessError.unavailable(errSecDecode) }
        return data
    }

    func save(_ data: Data, allowUserInteraction: Bool) throws {
        var insert = query(allowUserInteraction: allowUserInteraction)
        insert[kSecValueData as String] = data
        insert[kSecAttrLabel as String] = Self.displayName
        insert[kSecAttrDescription as String] = Self.itemDescription
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try check(SecItemAdd(insert as CFDictionary, nil))
    }

    func updateDisplayName() {
        // Metadata-only migration. Never read/replace the key or show a prompt here.
        // An older build's ACL may require one approval before this update can succeed.
        let attributes = [kSecAttrLabel as String: Self.displayName,
                          kSecAttrDescription as String: Self.itemDescription]
        _ = SecItemUpdate(query(allowUserInteraction: false) as CFDictionary, attributes as CFDictionary)
    }
}

struct LocalIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let fingerprint: String

    static func load(allowUserInteraction: Bool = false,
                     storage: any IdentityStorage = KeychainIdentityStorage()) throws -> LocalIdentity {
        storage.updateDisplayName()
        let archive: IdentityArchive
        if let data = try storage.read(allowUserInteraction: allowUserInteraction) {
            archive = try JSONDecoder().decode(IdentityArchive.self, from: data)
            storage.updateDisplayName()
        } else {
            archive = try generate()
            try storage.save(JSONEncoder().encode(archive), allowUserInteraction: allowUserInteraction)
        }
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: archive.password]
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        }
        let imported = SecPKCS12Import(archive.pkcs12 as CFData, options as CFDictionary, &items)
        guard imported == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let raw = first[kSecImportItemIdentity as String] else {
            throw CompanionError.message("Could not load TLS identity (\(imported)).")
        }
        let identity = raw as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { throw CompanionError.message("Missing identity certificate.") }
        return LocalIdentity(identity: identity, fingerprint: digest(SecCertificateCopyData(certificate) as Data))
    }

    private struct IdentityArchive: Codable {
        let pkcs12: Data
        let password: String
    }

    private static func generate() throws -> IdentityArchive {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let password = UUID().uuidString + UUID().uuidString
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = ["PATH": "/usr/bin:/bin", "COMPANION_P12_PASSWORD": password]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CompanionError.message("Could not create the local TLS identity.")
            }
        }
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
                 "-keyout", "identity.key", "-out", "identity.crt", "-subj", "/CN=Relay Mac"])
        try run(["pkcs12", "-export", "-inkey", "identity.key", "-in", "identity.crt",
                 "-out", "identity.p12", "-name", "Relay secure device connection",
                 "-passout", "env:COMPANION_P12_PASSWORD"])
        return IdentityArchive(pkcs12: try Data(contentsOf: directory.appendingPathComponent("identity.p12")),
                               password: password)
    }
}
