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

struct LocalIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let fingerprint: String

    static func load() throws -> LocalIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.companion.tls-identity.v1",
            kSecAttrAccount as String: "mac",
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let archive: IdentityArchive
        if status == errSecSuccess, let data = result as? Data {
            archive = try JSONDecoder().decode(IdentityArchive.self, from: data)
        } else if status == errSecItemNotFound {
            archive = try generate()
            var insert = query
            insert.removeValue(forKey: kSecReturnData as String)
            insert[kSecValueData as String] = try JSONEncoder().encode(archive)
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else {
                throw CompanionError.message("Could not save the Mac identity in Keychain (\(added)).")
            }
        } else {
            throw CompanionError.message("Keychain identity unavailable (\(status)).")
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
                 "-keyout", "identity.key", "-out", "identity.crt", "-subj", "/CN=Companion Mac"])
        try run(["pkcs12", "-export", "-inkey", "identity.key", "-in", "identity.crt",
                 "-out", "identity.p12", "-name", "Companion Mac",
                 "-passout", "env:COMPANION_P12_PASSWORD"])
        return IdentityArchive(pkcs12: try Data(contentsOf: directory.appendingPathComponent("identity.p12")),
                               password: password)
    }
}
