import Foundation
import CryptoKit

public struct InboxItem: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let isLink: Bool
    public let timestamp: Date

    public init(id: String = UUID().uuidString.lowercased(), text: String, isLink: Bool? = nil, timestamp: Date = Date()) {
        self.id = id
        self.text = text
        if let isLink {
            self.isLink = isLink
        } else {
            let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.isLink = lower.hasPrefix("https://") || lower.hasPrefix("http://")
        }
        self.timestamp = timestamp
    }
}

struct FileOffer: Codable, Sendable {
    let id: String
    let name: String
    let size: Int64
    let sha256: String
}

actor TransferStore {
    static let maximumSize: Int64 = 1_000_000_000
    let root: URL
    let receiveFolder: URL

    init(root: URL, receiveFolder: URL) throws {
        self.root = root
        self.receiveFolder = receiveFolder
        try FileManager.default.createDirectory(at: root.appendingPathComponent("outbox"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("incoming"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receiveFolder, withIntermediateDirectories: true)
        Self.cleanupOrphanedPartials(in: root)
    }

    func enqueue(_ source: URL, onProgress: @escaping TransferProgressHandler = { _ in }) async throws -> FileOffer {
        let info = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              let count = info.fileSize, count <= Self.maximumSize else {
            throw CompanionError.message("Select a regular file up to 1 GB.")
        }
        let id = UUID().uuidString.lowercased()
        let destination = root.appendingPathComponent("outbox/\(id).data")
        var size: Int64 = 0
        await onProgress(TransferProgress(id: id, name: source.lastPathComponent, direction: .send,
                                         transferredBytes: 0, totalBytes: Int64(count), stage: .preparing))
        do {
            let free = try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber
            guard let free, free.int64Value > Int64(count) + 32 * 1024 * 1024 else {
                throw CompanionError.message("Not enough disk space to prepare this file.")
            }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw CompanionError.message("Could not prepare file.")
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var hash = SHA256()
            var lastUpdate = Date.distantPast
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                size += Int64(chunk.count)
                guard size <= Self.maximumSize else { throw CompanionError.message("File exceeds the 1 GB limit.") }
                try output.write(contentsOf: chunk)
                hash.update(data: chunk)
                if Date().timeIntervalSince(lastUpdate) >= 0.2 || size == Int64(count) {
                    await onProgress(TransferProgress(id: id, name: source.lastPathComponent, direction: .send,
                                                     transferredBytes: size, totalBytes: Int64(count), stage: .preparing))
                    lastUpdate = Date()
                }
            }
            try output.synchronize()
            let offer = FileOffer(id: id, name: source.lastPathComponent, size: size,
                                  sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
            try JSONEncoder().encode(offer).write(to: root.appendingPathComponent("outbox/\(id).json"), options: .atomic)
            await onProgress(TransferProgress(id: id, name: offer.name, direction: .send,
                                             transferredBytes: 0, totalBytes: size, stage: .queued))
            return offer
        } catch {
            try? FileManager.default.removeItem(at: destination)
            await onProgress(TransferProgress(id: id, name: source.lastPathComponent, direction: .send,
                                             transferredBytes: size, totalBytes: Int64(count), stage: .failed,
                                             error: error.localizedDescription))
            throw error
        }
    }

    func next() throws -> FileOffer? {
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("outbox"),
                                                               includingPropertiesForKeys: nil)
        guard let manifest = files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }).first else { return nil }
        return try JSONDecoder().decode(FileOffer.self, from: Data(contentsOf: manifest))
    }

    func acknowledge(id: String, sha256: String) throws {
        try validateID(id)
        let manifest = root.appendingPathComponent("outbox/\(id).json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return }
        let offer = try JSONDecoder().decode(FileOffer.self, from: Data(contentsOf: manifest))
        guard offer.sha256 == sha256 else { throw CompanionError.message("Receipt hash mismatch.") }
        try FileManager.default.removeItem(at: manifest)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("outbox/\(id).data"))
    }

    func send(_ offer: FileOffer, channel: Channel, resumeOffset: Int64 = 0,
              onProgress: @escaping TransferProgressHandler = { _ in }) async throws {
        guard resumeOffset >= 0, resumeOffset <= offer.size else {
            throw CompanionError.message("Invalid resume offset.")
        }
        let file = try FileHandle(forReadingFrom: root.appendingPathComponent("outbox/\(offer.id).data"))
        defer { try? file.close() }
        if resumeOffset > 0 {
            try file.seek(toOffset: UInt64(resumeOffset))
        }
        var remaining = offer.size - resumeOffset
        var lastUpdate = Date.distantPast
        await onProgress(TransferProgress(id: offer.id, name: offer.name, direction: .send,
                                         transferredBytes: resumeOffset, totalBytes: offer.size, stage: .transferring))
        while remaining > 0 {
            guard let chunk = try file.read(upToCount: Int(min(remaining, 64 * 1024))), !chunk.isEmpty else {
                throw CompanionError.message("Queued source is incomplete.")
            }
            try await channel.send(chunk)
            remaining -= Int64(chunk.count)
            if Date().timeIntervalSince(lastUpdate) >= 0.2 || remaining == 0 {
                await onProgress(TransferProgress(id: offer.id, name: offer.name, direction: .send,
                                                 transferredBytes: offer.size - remaining, totalBytes: offer.size, stage: .transferring))
                lastUpdate = Date()
            }
        }
    }

    func receive(_ offer: FileOffer, channel: Channel,
                 onProgress: @escaping TransferProgressHandler = { _ in }) async throws -> URL {
        try validateID(offer.id)
        guard offer.size >= 0, offer.size <= Self.maximumSize,
              offer.sha256.count == 64, offer.sha256.allSatisfy({ $0.isHexDigit }),
              !offer.name.isEmpty, offer.name.utf8.count <= 180,
              offer.name == (offer.name as NSString).lastPathComponent,
              !offer.name.contains("\\"), !offer.name.contains("\0"),
              offer.name != ".", offer.name != ".." else {
            throw CompanionError.message("Invalid file offer.")
        }
        await onProgress(TransferProgress(id: offer.id, name: offer.name, direction: .receive,
                                         transferredBytes: 0, totalBytes: offer.size, stage: .preparing))
        let destination = try destinationURL(for: offer.name, expectedHash: offer.sha256)
        if destination.alreadyComplete {
            try await channel.sendMessage(WireMessage(type: "file.saved", id: offer.id, sha256: offer.sha256))
            await onProgress(TransferProgress(id: offer.id, name: offer.name, direction: .receive,
                                             transferredBytes: offer.size, totalBytes: offer.size, stage: .completed))
            return destination.url
        }
        let final = destination.url
        let free = try FileManager.default.attributesOfFileSystem(forPath: receiveFolder.path)[.systemFreeSize] as? NSNumber
        guard let free, free.int64Value > offer.size + 32 * 1024 * 1024 else {
            throw CompanionError.message("Not enough disk space.")
        }
        
        let partial = root.appendingPathComponent("incoming/\(offer.id).partial")
        var existingSize: Int64 = 0
        if FileManager.default.fileExists(atPath: partial.path) {
            existingSize = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)) ?? 0
            if existingSize >= offer.size {
                existingSize = 0
                try? FileManager.default.removeItem(at: partial)
            }
        }
        if existingSize == 0 {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                throw CompanionError.message("Could not prepare receive file.")
            }
        }
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }
        if existingSize > 0 {
            try file.seekToEnd()
        }
        try await channel.sendMessage(WireMessage(type: "file.ready", id: offer.id, size: existingSize))
        var remaining = offer.size - existingSize
        var lastUpdate = Date.distantPast
        await onProgress(TransferProgress(id: offer.id, name: offer.name, direction: .receive,
                                         transferredBytes: existingSize, totalBytes: offer.size, stage: .transferring))
        while remaining > 0 {
            let data = try await channel.read(Int(min(remaining, 64 * 1024)))
            try file.write(contentsOf: data)
            remaining -= Int64(data.count)
            if Date().timeIntervalSince(lastUpdate) >= 0.2 || remaining == 0 {
                await onProgress(TransferProgress(id: offer.id, name: offer.name, direction: .receive,
                                                 transferredBytes: offer.size - remaining, totalBytes: offer.size, stage: .transferring))
                lastUpdate = Date()
            }
        }
        try file.synchronize()
        try file.close()
        await onProgress(TransferProgress(id: offer.id, name: offer.name, direction: .receive,
                                         transferredBytes: offer.size, totalBytes: offer.size, stage: .verifying))
        let actual = try hashFile(partial)
        guard actual == offer.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw CompanionError.message("File integrity check failed.")
        }
        if FileManager.default.fileExists(atPath: final.path) {
            guard try hashFile(final) == actual else { throw CompanionError.message("Destination collision.") }
        } else {
            try FileManager.default.moveItem(at: partial, to: final)
        }
        try? FileManager.default.removeItem(at: partial)
        try await channel.sendMessage(WireMessage(type: "file.saved", id: offer.id, sha256: actual))
        await onProgress(TransferProgress(id: offer.id, name: offer.name, direction: .receive,
                                         transferredBytes: offer.size, totalBytes: offer.size, stage: .completed))
        return final
    }

    func destinationURL(for rawName: String, expectedHash: String) throws -> (url: URL, alreadyComplete: Bool) {
        let name = (rawName as NSString).deletingPathExtension
        let ext = (rawName as NSString).pathExtension
        let baseFilename = ext.isEmpty ? name : "\(name).\(ext)"
        let target = receiveFolder.appendingPathComponent(baseFilename)
        if !FileManager.default.fileExists(atPath: target.path) {
            return (target, false)
        }
        if (try? hashFile(target)) == expectedHash {
            return (target, true)
        }
        var counter = 1
        while counter < 1000 {
            let candidateName = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
            let candidateURL = receiveFolder.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidateURL.path) {
                return (candidateURL, false)
            }
            if (try? hashFile(candidateURL)) == expectedHash {
                return (candidateURL, true)
            }
            counter += 1
        }
        throw CompanionError.message("Too many files with the same name.")
    }

    private func validateID(_ id: String) throws {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else {
            throw CompanionError.message("Invalid transfer ID.")
        }
    }

    private func hashFile(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private var inboxFile: URL { root.appendingPathComponent("inbox.json") }

    func getInboxItems() throws -> [InboxItem] {
        guard FileManager.default.fileExists(atPath: inboxFile.path) else { return [] }
        return try JSONDecoder().decode([InboxItem].self, from: Data(contentsOf: inboxFile))
    }

    func addInboxItem(_ item: InboxItem) throws {
        var items = (try? getInboxItems()) ?? []
        if !items.contains(where: { $0.id == item.id || ($0.text == item.text && abs($0.timestamp.timeIntervalSince(item.timestamp)) < 60) }) {
            items.insert(item, at: 0)
            if items.count > 50 { items = Array(items.prefix(50)) }
            try JSONEncoder().encode(items).write(to: inboxFile, options: .atomic)
        }
    }

    func removeInboxItem(id: String) throws {
        var items = (try? getInboxItems()) ?? []
        items.removeAll { $0.id == id }
        try JSONEncoder().encode(items).write(to: inboxFile, options: .atomic)
    }

    func enqueueText(_ text: String) throws -> InboxItem {
        let item = InboxItem(text: text)
        let manifest = root.appendingPathComponent("outbox/text-\(item.id).json")
        try JSONEncoder().encode(item).write(to: manifest, options: .atomic)
        return item
    }

    func nextPendingText() throws -> InboxItem? {
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("outbox"), includingPropertiesForKeys: nil)
        guard let manifest = files.filter({ $0.lastPathComponent.hasPrefix("text-") && $0.pathExtension == "json" })
            .sorted(by: { $0.path < $1.path }).first else { return nil }
        return try JSONDecoder().decode(InboxItem.self, from: Data(contentsOf: manifest))
    }

    func acknowledgeText(id: String) throws {
        let manifest = root.appendingPathComponent("outbox/text-\(id).json")
        try? FileManager.default.removeItem(at: manifest)
    }

    static func cleanupOrphanedPartials(in root: URL) {
        let incomingDir = root.appendingPathComponent("incoming")
        guard let files = try? FileManager.default.contentsOfDirectory(at: incomingDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-86400)
        for file in files where file.pathExtension == "partial" {
            if let date = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate, date < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

