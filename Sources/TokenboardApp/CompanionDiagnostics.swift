import Foundation
import os

/// Where the companion feature's degraded renders report. Every failure path
/// stays graceful at its call site — a nil image, an empty window map, an
/// inert scene — but the reason now lands here: once in the local unified log
/// (the app has no network entitlement; nothing leaves the machine) and in a
/// deduplicated observable list the Diagnostics tab can surface.
@MainActor
final class CompanionDiagnostics: ObservableObject {
    enum Issue: Hashable, Sendable {
        /// A bundled resource the render needed and could not use — a file
        /// the image store cannot load, or a sprite the tables cannot size.
        case missingAsset(resource: String)
        /// A village sprite whose bitmap could not be read for windows,
        /// as opposed to one that genuinely has none.
        case unreadableWindowMap(resource: String)
        /// A visible theme and stage the catalog resolved no scene for.
        case unresolvedScene(theme: CompanionTheme, stage: Int)

        var message: String {
            switch self {
            case let .missingAsset(resource):
                "Missing asset \(resource)"
            case let .unreadableWindowMap(resource):
                "Unreadable window map for \(resource)"
            case let .unresolvedScene(theme, stage):
                "No scene for \(theme.rawValue) stage \(stage)"
            }
        }
    }

    static let shared = CompanionDiagnostics()

    @Published private(set) var issues: [Issue] = []
    private var recorded: Set<Issue> = []
    private let logger = Logger(
        subsystem: "com.tokenboard.Tokenboard",
        category: "companion"
    )

    /// One line in the Diagnostics tab: quiet when everything resolved.
    var summary: String {
        issues.isEmpty
            ? "All assets resolved"
            : "\(issues.count) issue\(issues.count == 1 ? "" : "s")"
    }

    func record(_ issue: Issue) {
        guard recorded.insert(issue).inserted else { return }
        issues.append(issue)
        logger.error("\(issue.message, privacy: .public)")
    }

    /// Recording from the pure, nonisolated scene builders. On the main
    /// thread — every render path — this records synchronously; elsewhere
    /// (nonisolated tests) it hops.
    nonisolated static func note(_ issue: Issue) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { shared.record(issue) }
        } else {
            Task { @MainActor in shared.record(issue) }
        }
    }
}
