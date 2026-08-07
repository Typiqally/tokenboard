import CryptoKit
import Foundation

public struct DismissibleWarningSignature: Equatable, Sendable {
    public let digest: String

    public init?(
        health: TokenboardHealth,
        sourceWarningIssues: [Provider: Set<TokenboardHealth.Issue>] = [:]
    ) {
        var components: [String] = []
        for provider in Provider.allCases {
            guard case let .warning(issue, _) = health.source(provider),
                  issue.isDismissibleSourceWarning else { continue }
            let issues = sourceWarningIssues[provider, default: []].union([issue])
            for identity in issues where identity.isDismissibleSourceWarning {
                components.append("source|\(provider.rawValue)|\(identity.rawValue)")
            }
        }
        if health.skippedRecordCount > 0 {
            components.append("skipped|\(health.skippedRecordCount)")
        }
        guard !components.isEmpty else { return nil }
        digest = Self.digest(components: components)
    }

    static func digest<C: Collection>(components: C) -> String where C.Element == String {
        let canonical = (["warning-signature-v1"] + components.sorted())
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

public extension TokenboardHealth {
    var dismissibleWarningSignature: DismissibleWarningSignature? {
        DismissibleWarningSignature(health: self)
    }

    var hasNonDismissibleDisplayIntegrityWarning: Bool {
        database != .healthy || Provider.allCases.contains { provider in
            guard case let .warning(issue, _) = source(provider) else { return false }
            return !issue.isDismissibleSourceWarning
        }
    }
}
