import Foundation
import TokenboardCore

@MainActor
extension AppModel {
    var hasEveryGrant: Bool {
        Provider.allCases.allSatisfy { activeGrants[$0] != nil }
    }

    var isReadyForSources: Bool {
        state.lifecycle == .ready && readyGeneration == lifecycleGeneration
    }

    func ensureReady(retryFailed: Bool) async -> Bool {
        switch state.lifecycle {
        case .ready:
            return isReadyForSources
        case .starting:
            await startupTask?.value
            return isReadyForSources
        case .failed where !retryFailed:
            return false
        case .shuttingDown, .stopped:
            return false
        case .idle, .failed:
            break
        }

        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        readyGeneration = nil
        var next = state
        next.lifecycle = .starting
        next.onboardingRequired = false
        next.isImporting = false
        commitState(next)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStartup(generation: generation)
        }
        startupTask = task
        await task.value
        if lifecycleGeneration == generation {
            startupTask = nil
        }
        return isReadyForSources
    }

    func performStartup(generation: UInt64) async {
        do {
            try await ledger.migrate()
            guard accepts(generation) else { return }
            try await ledger.integrityCheck()
            guard accepts(generation) else { return }
            try await installBundledCatalogIfNeeded()
            guard accepts(generation) else { return }

            inboxStatus = .starting
            try await pricingInbox.start()
            guard accepts(generation) else { return }
            inboxStatus = .active(runID: generation)
            readyGeneration = generation

            guard let resolved = await resolveStoredGrants(generation: generation),
                  accepts(generation) else { return }
            activeGrants = resolved.grants
            var next = state
            next.lifecycle = .ready
            next.sourceHealth = resolved.health
            next.sourceFileCounts = resolved.counts
            next.grantedProviders = Set(resolved.grants.keys)
            next.onboardingRequired = !preferences.historicalImportApproved
                || resolved.grants.count != Provider.allCases.count
            commitState(next)
        } catch {
            guard accepts(generation) else { return }
            readyGeneration = nil
            if inboxStatus == .starting {
                try? await pricingInbox.stop()
                inboxStatus = .inactive
            }
            guard accepts(generation) else { return }
            var next = state
            next.lifecycle = .failed(message: Self.errorDescription(error))
            next.onboardingRequired = false
            next.grantedProviders = []
            next.sourceFileCounts = [:]
            next.sourceHealth = warningHealth(
                message: "Startup paused: \(Self.errorDescription(error))"
            )
            commitState(next)
        }
    }

    func finishStartupBehavior() async {
        guard isReadyForSources else { return }
        if preferences.historicalImportApproved, hasEveryGrant {
            await launchIngestion(refreshExisting: false)
        } else if preferences.historicalImportApproved {
            await querySelectedSummary()
        }
    }

    func installBundledCatalogIfNeeded() async throws {
        guard try await ledger.latestAppliedPricingCatalogJSON() == nil else { return }
        let loaded = try PricingCatalogLoader().load(bundledCatalogData)
        let validated = try PricingCatalogValidator().validate(loaded)
        try await ledger.applyPricingCatalog(
            validated,
            canonicalJSON: validated.canonicalJSON,
            origin: PricingImportMetadata.bundledRepositoryOrigin,
            validationSummary: PricingImportMetadata.schemaV1ValidSummary
        )
    }

    func resolveStoredGrants(generation: UInt64) async -> AppResolvedGrants? {
        guard readyGeneration == generation, accepts(generation) else { return nil }
        var grants: [Provider: ActiveSourceGrant] = [:]
        var health: [Provider: SourceHealth] = [:]
        var counts: [Provider: Int] = [:]
        for provider in Provider.allCases {
            guard readyGeneration == generation, accepts(generation) else {
                grants.values.forEach { $0.close() }
                return nil
            }
            do {
                guard let grant = try grantStore.openGrant(for: provider) else {
                    health[provider] = .notGranted
                    continue
                }
                grants[provider] = grant
                do {
                    let count = try await discoveredFileCount(under: grant.root)
                    guard readyGeneration == generation, accepts(generation) else {
                        grants.values.forEach { $0.close() }
                        return nil
                    }
                    counts[provider] = count
                    health[provider] = .indexing(fileCount: count)
                } catch {
                    health[provider] = .warning(message: "Source discovery unavailable")
                }
            } catch {
                health[provider] = .warning(message: "Access unavailable")
            }
        }
        return AppResolvedGrants(grants: grants, health: health, counts: counts)
    }
}
