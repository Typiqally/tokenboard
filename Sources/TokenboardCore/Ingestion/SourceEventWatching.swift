import Foundation

public struct SourceEventCheckpoint: Equatable, Sendable {
    public let eventID: UInt64

    public init(eventID: UInt64) {
        self.eventID = eventID
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
