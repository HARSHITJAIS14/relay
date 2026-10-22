import Foundation

public struct TransferProgress: Sendable, Equatable {
    public enum Direction: Sendable { case send, receive }
    public enum Stage: Sendable { case preparing, queued, transferring, verifying, completed, failed }
    public let id: String
    public let name: String
    public let direction: Direction
    public let transferredBytes: Int64
    public let totalBytes: Int64
    public let stage: Stage
    public var error: String? = nil

    public var fraction: Double {
        guard totalBytes > 0 else { return stage == .completed ? 1 : 0 }
        return min(1, max(0, Double(transferredBytes) / Double(totalBytes)))
    }
    public var percent: Int { Int(fraction * 100) }
    public var summary: String {
        "\(ByteCountFormatter.string(fromByteCount: transferredBytes, countStyle: .decimal)) of \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .decimal))"
    }
    public var title: String {
        switch stage {
        case .preparing: return "Preparing file…"
        case .queued: return "Waiting for phone…"
        case .transferring: return direction == .send ? "Sending to phone" : "Receiving from phone"
        case .verifying: return "Verifying file…"
        case .completed: return direction == .send ? "File sent" : "File received"
        case .failed: return "Transfer interrupted"
        }
    }
    public func changing(stage: Stage, error: String? = nil) -> Self {
        Self(id: id, name: name, direction: direction, transferredBytes: transferredBytes,
             totalBytes: totalBytes, stage: stage, error: error)
    }
}

typealias TransferProgressHandler = @Sendable (TransferProgress) async -> Void
