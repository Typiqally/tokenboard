import Foundation

public enum AgentPricingSource: String, Hashable, Sendable {
    case tokenboardRepository
    case officialResearch
}

public struct AgentPricingPaths: Equatable, Sendable {
    public let currentCatalog: URL
    public let temporaryCandidate: URL
    public let finalCandidate: URL

    public init(currentCatalog: URL, temporaryCandidate: URL, finalCandidate: URL) {
        self.currentCatalog = currentCatalog
        self.temporaryCandidate = temporaryCandidate
        self.finalCandidate = finalCandidate
    }
}

public struct AgentPromptBuilder: Sendable {
    public init() {}

    public func build(source: AgentPricingSource, paths: AgentPricingPaths) -> String {
        let sourcePolicy: String
        switch source {
        case .tokenboardRepository:
            sourcePolicy = """
            Source policy: Use only this source: https://raw.githubusercontent.com/Typiqally/tokenboard/main/Resources/tokenboard-pricing.json
            Do not research or fetch pricing from any other source.
            """
        case .officialResearch:
            sourcePolicy = """
            Source policy: Research current pricing using only official first-party sources. Use only official pages on these exact hosts: anthropic.com, www.anthropic.com, platform.claude.com, docs.anthropic.com, www-cdn.anthropic.com, openai.com, www.openai.com, platform.openai.com, help.openai.com. Do not use mirrors, search-result summaries, aggregators, or any other host.
            """
        }

        return """
        Update Tokenboard's complete pricing ledger. Read the current catalog from the exact path below. Preserve every substantiated historical entry. Add only rates and effective dates supported by the allowed sources. Leave uncertain periods absent; do not infer or invent them.

        \(sourcePolicy)

        Exact current catalog path (read only):
        \(resolvedPath(paths.currentCatalog))

        Exact temporary candidate path (the only permitted write destination):
        \(resolvedPath(paths.temporaryCandidate))

        Exact final candidate path (rename destination only):
        \(resolvedPath(paths.finalCandidate))

        Do not open or modify any SQLite file. Do not write anywhere except the temporary candidate path below. Validate schemaVersion 1, write UTF-8 JSON smaller than 1 MiB, then atomically rename the temporary candidate to the final candidate path. If network or filesystem permission is unavailable, stop and ask me explicitly. Do not choose another source, destination, or update mechanism.

        Do not include transcript content, prompts, user source paths, session IDs, project data, or any other private usage data in the pricing catalog or your report.

        After the rename, report sources consulted, models/rates added, uncertainties left unpriced, and the exact final path. Tokenboard itself will validate the file and require me to approve it.
        """
    }

    private func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
