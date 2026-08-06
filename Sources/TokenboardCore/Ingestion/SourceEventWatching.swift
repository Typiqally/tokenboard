import Foundation

public protocol SourceEventWatching: Sendable {
    func events(for roots: [URL]) -> AsyncStream<Set<URL>>
    func stop()
}
