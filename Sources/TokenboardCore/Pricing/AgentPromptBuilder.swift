import Foundation

public struct AgentPricingPaths: Equatable, Sendable {
    public let currentCatalog: URL
    public let temporaryCatalog: URL

    public init(currentCatalog: URL, temporaryCatalog: URL) {
        self.currentCatalog = currentCatalog
        self.temporaryCatalog = temporaryCatalog
    }
}

public struct AgentPromptBuilder: Sendable {
    public init() {}

    public func build(paths: AgentPricingPaths) -> String {
        """
        Update Tokenboard's complete, authoritative pricing catalog. Read the current catalog first and preserve substantiated historical entries unless reliable evidence supports correcting or removing them. Add effective dates whenever the evidence supports them, and leave uncertain periods absent instead of guessing.

        Research policy: You may use public web sources. Prefer primary model-provider pricing pages, documentation, announcements, and changelogs. When primary evidence is unavailable or incomplete, use reputable secondary sources and web archives, corroborating important rates where practical. Use a reliable public exchange-rate source for USD, EUR, JPY, GBP, and CNY. Record the strongest supporting HTTPS provenance URL on every model-rate period and on the exchange-rate snapshot, and report every source consulted. Never invent a rate, date, model mapping, or source.

        Put the complete model-pricing ledger and one current exchange-rate snapshot in a schemaVersion 2 catalog. Use origin kind web_research. Exchange rates must use USD as their base and contain exactly USD, EUR, JPY, GBP, and CNY as units of target currency per 1 USD, with USD equal to 1. Use one reference date for the full exchange-rate snapshot.

        Exact active catalog path (read this first; atomic rename destination only):
        \(resolvedPath(paths.currentCatalog))

        Exact temporary path (the only permitted write destination):
        \(resolvedPath(paths.temporaryCatalog))

        Do not open or modify any SQLite file. Do not write anywhere except the exact temporary path. Validate the complete catalog locally, write UTF-8 JSON smaller than 1 MiB, fsync it when your environment permits, then atomically replace the active catalog by renaming the temporary file to the exact active path. If network or filesystem permission is unavailable, stop and ask me explicitly. Do not choose another destination or update mechanism.

        Do not include transcript content, prompts, user source paths, session IDs, project data, or any other private usage data in the pricing catalog or your report.

        After the rename, report every source consulted, model rates and exchange rates changed, corrections or removals made, and uncertainties left unpriced. Tokenboard applies valid changes automatically after validating the file locally; invalid changes leave the last valid pricing active.
        """
    }

    private func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
