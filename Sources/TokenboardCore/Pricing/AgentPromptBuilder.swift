import Foundation

public struct AgentPricingPaths: Equatable, Sendable {
    public let currentCatalog: URL
    public let temporaryCatalog: URL

    public init(currentCatalog: URL, temporaryCatalog: URL) {
        self.currentCatalog = currentCatalog
        self.temporaryCatalog = temporaryCatalog
    }
}

public struct PricingResearchTarget: Equatable, Hashable, Sendable {
    public let provider: Provider
    public let observedModelID: String

    public init(provider: Provider, observedModelID: String) {
        self.provider = provider
        self.observedModelID = observedModelID
    }
}

public struct AgentPromptBuilder: Sendable {
    public init() {}

    public func build(
        paths: AgentPricingPaths,
        coverageTargets: [PricingResearchTarget] = []
    ) -> String {
        let coverageSection = coverageSection(for: coverageTargets)
        return """
        Update Tokenboard's complete, authoritative pricing catalog. Read the current catalog first and preserve substantiated historical entries unless reliable evidence supports correcting or removing them. Add effective dates whenever the evidence supports them, and leave uncertain periods absent instead of guessing.

        Research policy: Use only official first-party sources. For OpenAI/Codex model pricing, use exact hosts openai.com, www.openai.com, platform.openai.com, help.openai.com, or developers.openai.com. For Anthropic/Claude Code model pricing, use exact hosts anthropic.com, www.anthropic.com, platform.claude.com, docs.anthropic.com, or www-cdn.anthropic.com. Fetch exchange rates only from https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml. Do not use mirrors, search-result summaries, aggregators, secondary sources, archives, or lookalike subdomains. Record the official HTTPS provenance URL on every model-rate period and the exact ECB URL on the exchange-rate snapshot. Never invent a rate, date, model mapping, or source; leave uncertain periods absent.

        Put the complete model-pricing ledger and one current exchange-rate snapshot in a schemaVersion 2 catalog. Use origin kind official_research. Exchange rates must use USD as their base and contain exactly USD, EUR, JPY, GBP, and CNY as units of target currency per 1 USD, with USD equal to 1. ECB publishes units per EUR, so derive every USD cross-rate from one ECB reference date and do not combine dates.

        \(coverageSection)

        Exact active catalog path (read this first; atomic rename destination only):
        \(resolvedPath(paths.currentCatalog))

        Exact temporary path (the only permitted write destination):
        \(resolvedPath(paths.temporaryCatalog))

        Do not open or modify any SQLite file. Do not write anywhere except the exact temporary path. Validate the complete catalog locally, write UTF-8 JSON smaller than 1 MiB, fsync it when your environment permits, then atomically replace the active catalog by renaming the temporary file to the exact active path. If network or filesystem permission is unavailable, stop and ask me explicitly. Do not choose another destination or update mechanism.

        Do not include transcript content, prompts, user source paths, session IDs, project data, or any other private usage data in the pricing catalog or your report.

        After the rename, report every source consulted, model rates and exchange rates changed, corrections or removals made, and uncertainties left unpriced. Tokenboard applies valid changes automatically after validating the file locally; invalid changes leave the last valid pricing active.
        """
    }

    private func coverageSection(for targets: [PricingResearchTarget]) -> String {
        let safeTargets = Array(Set(targets.filter {
            ModelIdentifierPolicy.isContentSafe($0.observedModelID)
                && !ModelIdentifierPolicy.isOpaqueUnknown($0.observedModelID)
                && $0.observedModelID != "<synthetic>"
        })).sorted {
            ($0.provider.rawValue, $0.observedModelID)
                < ($1.provider.rawValue, $1.observedModelID)
        }
        guard !safeTargets.isEmpty else {
            return "No local pricing coverage targets are currently available."
        }
        let rows = safeTargets.map {
            "- \($0.provider.rawValue) / \($0.observedModelID)"
        }.joined(separator: "\n")
        return """
        Local pricing coverage targets (observed model identifiers only):
        \(rows)
        Research every target above while still preserving the complete substantiated ledger.
        """
    }

    private func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
