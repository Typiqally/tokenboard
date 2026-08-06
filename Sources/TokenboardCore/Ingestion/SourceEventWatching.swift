import Foundation

public enum SourceEventCheckpointDisposition: Equatable, Sendable {
    case advance
    case reset
}

public struct SourceEventCheckpoint: Equatable, Sendable {
    public let eventID: UInt64
    public let disposition: SourceEventCheckpointDisposition

    public init(
        eventID: UInt64,
        disposition: SourceEventCheckpointDisposition = .advance
    ) {
        self.eventID = eventID
        self.disposition = disposition
    }
}

public struct SourceEventBatch: Equatable, Sendable {
    public let paths: Set<URL>
    public let checkpoint: SourceEventCheckpoint?

    public init(paths: Set<URL>, checkpoint: SourceEventCheckpoint?) {
        self.paths = paths
        self.checkpoint = checkpoint
    }
}

public protocol SourceEventWatching: Sendable {
    func events(for roots: [URL]) -> AsyncStream<SourceEventBatch>
    func acknowledge(_ checkpoint: SourceEventCheckpoint?)
    func stop()
}
