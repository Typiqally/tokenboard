import Foundation
import TokenboardCore

@MainActor
extension AppModel {
    var hasEveryGrant: Bool {
        Provider.allCases.allSatisfy { activeGrants[$0] != nil }
    }

    var hasAnyGrant: Bool { !activeGrants.isEmpty }

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
        } catch {
            await publishDatabaseRecovery(.migrationFailure, generation: generation)
            return
        }
        guard accepts(generation) else { return }
        do {
            try await ledger.integrityCheck()
        } catch {
            await publishDatabaseRecovery(.integrityFailure, generation: generation)
            return
        }
        guard accepts(generation) else { return }

        do {
            try await installBundledCatalogIfNeeded()
            guard accepts(generation) else { return }

            inboxStatus = .starting
            let pricingUpdates = await pricingInbox.updates()
            try await pricingInbox.start()
            guard accepts(generation) else { return }
            inboxStatus = .active(runID: generation)
            readyGeneration = generation

            guard let resolved = await resolveStoredGrants(generation: generation),
                  accepts(generation) else { return }
            let durableSkipped = (try? await ledger.skippedRecordCountsByProvider()) ?? [:]
            let skippedCount = (try? await ledger.skippedRecordCount()) ?? 0
            guard accepts(generation) else {
                resolved.grants.values.forEach { $0.close() }
                return
            }
            activeGrants = resolved.grants
            var next = state
            next.lifecycle = .ready
            next.sourceHealth = resolved.health
            for (provider, count) in durableSkipped where count > 0
                && resolved.grants[provider] != nil {
                next.sourceHealth[provider] = .warning(
                    issue: .unknownFormats,
                    message: TokenboardHealth.Issue.unknownFormats.message
                )
            }
            next.health = next.health.replacing(skippedRecordCount: skippedCount)
            next.sourceFileCounts = resolved.counts
            next.grantedProviders = Set(resolved.grants.keys)
            next.onboardingRequired = !preferences.historicalImportApproved
                || resolved.grants.count != Provider.allCases.count
            commitState(next)
            startPricingUpdateConsumer(pricingUpdates, generation: generation)
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
                issue: .applicationFailure,
                message: "Startup paused: \(Self.errorDescription(error))"
            )
            commitState(next)
        }
    }

    func publishDatabaseRecovery(
        _ issue: TokenboardHealth.Issue,
        generation: UInt64
    ) async {
        guard accepts(generation) else { return }
        readyGeneration = nil
        if coordinatorStatus != .inactive {
            await coordinator.stop()
        }
        pricingUpdateConsumerTask?.cancel()
        await pricingUpdateConsumerTask?.value
        pricingUpdateConsumerTask = nil
        if inboxStatus != .inactive {
            try? await pricingInbox.stop()
        }
        coordinatorStatus = .inactive
        inboxStatus = .inactive
        guard accepts(generation) else { return }
        var next = state
        next.lifecycle = .failed(message: issue.message)
        next.onboardingRequired = false
        next.grantedProviders = []
        next.sourceFileCounts = [:]
        next.sourceHealth = [.claudeCode: .notGranted, .codex: .notGranted]
        next.health = next.health.replacing(
            database: .recoveryRequired(message: issue.message)
        )
        commitState(next)
        await performLoadRecoveryBackups()
    }

    func startPricingUpdateConsumer(
        _ updates: AsyncStream<PricingCatalogStatus>,
        generation: UInt64
    ) {
        pricingUpdateConsumerTask?.cancel()
        pricingUpdateConsumerTask = Task { @MainActor [weak self] in
            for await status in updates {
                guard !Task.isCancelled else { break }
                await self?.receivePricingCatalogStatus(status, generation: generation)
            }
        }
    }

    func receivePricingCatalogStatus(
        _ status: PricingCatalogStatus,
        generation: UInt64
    ) async {
        guard accepts(generation), isReadyForSources else { return }
        await runSettingsOperation { [weak self] in
            guard let self,
                  self.accepts(generation),
                  self.isReadyForSources else { return }
            if case .current = status {
                await self.querySelectedSummary()
            }
            await self.performRefreshSettings(statusMessage: nil)
        }
    }

    func finishStartupBehavior() async {
        guard isReadyForSources else { return }
        if preferences.historicalImportApproved, hasAnyGrant {
            await launchIngestion(refreshExisting: false)
        } else if preferences.historicalImportApproved {
            await querySelectedSummary()
        }
    }

    func installBundledCatalogIfNeeded() async throws {
        guard try await ledger.latestAppliedPricingCatalogJSON() == nil else { return }
        let loaded = try PricingCatalogLoader().load(bundledCatalogData)
        let validated = try PricingCatalogValidator().validate(loaded)
        guard let validationSummary = PricingImportMetadata.validationSummary(
            for: validated.schemaVersion
        ) else {
            throw PricingLedgerError.invalidImportMetadata
        }
        try await ledger.applyPricingCatalog(
            validated,
            canonicalJSON: validated.canonicalJSON,
            origin: PricingImportMetadata.bundledRepositoryOrigin,
            validationSummary: validationSummary
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
                    health[provider] = .warning(
                        issue: .missingRoot,
                        message: TokenboardHealth.Issue.missingRoot.message
                    )
                }
            } catch {
                health[provider] = .warning(
                    issue: .staleBookmark,
                    message: TokenboardHealth.Issue.staleBookmark.message
                )
            }
        }
        return AppResolvedGrants(grants: grants, health: health, counts: counts)
    }
}
