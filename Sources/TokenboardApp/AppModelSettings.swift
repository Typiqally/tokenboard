import Foundation
import TokenboardCore

@MainActor
extension AppModel {
    func refreshSettings() async {
        await runSettingsOperation { [weak self] in
            await self?.performRefreshSettings(statusMessage: nil)
        }
    }

    func copyAgentPrompt() async {
        await runSettingsOperation { [weak self] in
            await self?.performCopyAgentPrompt()
        }
    }

    private func performCopyAgentPrompt() async {
        do {
            try await pricingInbox.exportCurrentSnapshot()
            let prompt = AgentPromptBuilder().build(
                paths: AgentPricingPaths(
                    currentCatalog: applicationPaths.pricing.appending(
                        path: PricingInbox.currentCatalogFilename
                    ),
                    temporaryCatalog: applicationPaths.pricing.appending(
                        path: PricingInbox.temporaryCatalogFilename
                    )
                ),
                coverageTargets: (settingsState.pricing.coveragePeriod == state.selectedPeriod
                    ? settingsState.pricing.unpricedUsage
                    : []).map {
                    PricingResearchTarget(
                        provider: $0.provider,
                        observedModelID: $0.observedModelID
                    )
                }
            )
            guard pasteboard.replace(with: prompt) else {
                throw AppSettingsError.pasteboardWriteFailed
            }
            setSettingsStatus("Prompt copied · Tokenboard made no network request")
        } catch {
            setSettingsStatus("Prompt copy failed: \(Self.errorDescription(error))")
        }
    }

    func changeSource(_ provider: Provider) async {
        await chooseSource(provider)
        await refreshSettings()
    }

    func revokeSource(_ provider: Provider) async {
        await startSourceMutation(.revoke(provider))
    }

    func runRevocation(
        provider: Provider,
        generation: UInt64,
        mutationID: UInt64
    ) async {
        guard acceptsSourceMutation(generation: generation, id: mutationID) else { return }
        let oldRoots = activeRoots()
        let oldCoordinatorWasActive = coordinatorStatus.isActive
        var remainingRoots = oldRoots
        remainingRoots[provider] = nil
        prepareForCoordinatorStart()

        do {
            let runID = try await coordinator.revokeSource(
                provider,
                remainingRoots: remainingRoots
            )
            guard acceptsSourceMutation(generation: generation, id: mutationID) else {
                return
            }
            if let runID {
                coordinatorStatus = .active(runID: runID)
                discardPendingResults(exceptRunID: runID)
                await processPendingIngestionResults(generation: generation)
            } else {
                coordinatorStatus = .inactive
                discardPendingResults(exceptRunID: UInt64.max)
            }

            grantStore.revoke(provider)
            let revokedGrant = activeGrants.removeValue(forKey: provider)
            revokedGrant?.close()
            var next = state
            next.grantedProviders.remove(provider)
            next.sourceFileCounts[provider] = nil
            next.lastSuccessfulScans[provider] = nil
            next.lastUpdated = next.lastSuccessfulScans.values.max()
            next.sourceHealth[provider] = .notGranted
            next.onboardingRequired = true
            commitState(next)
            await queryUsagePresentations()
            await performRefreshSettings(statusMessage: "Source access revoked · Committed totals retained")
        } catch {
            coordinatorStatus = .inactive
            guard acceptsSourceMutation(generation: generation, id: mutationID) else {
                return
            }
            if oldCoordinatorWasActive, !oldRoots.isEmpty {
                do {
                    prepareForCoordinatorStart()
                    beginCoordinatorInventoryRequest()
                    let restored: IngestionBatchResult
                    do {
                        restored = try await coordinator.startMonitoring(roots: oldRoots)
                    } catch {
                        completeCoordinatorInventoryRequest()
                        throw error
                    }
                    guard acceptsSourceMutation(
                        generation: generation,
                        id: mutationID
                    ) else {
                        completeCoordinatorInventoryRequest()
                        return
                    }
                    await activateRestoredCoordinator(restored, generation: generation)
                } catch {
                    coordinatorStatus = .inactive
                    guard acceptsSourceMutation(
                        generation: generation,
                        id: mutationID
                    ) else { return }
                    publishWarning(
                        .importFailure,
                        message: "Historical import paused: \(Self.errorDescription(error))"
                    )
                }
            }
            setSettingsStatus("Source revoke failed: \(Self.errorDescription(error))")
        }
    }

    func revealLocalData() {
        guard !isDatabaseRestoreInProgress else { return }
        localDataRevealer.reveal([applicationPaths.root])
    }

    func loadRecoveryBackups() async {
        await runSettingsOperation { [weak self] in
            await self?.performLoadRecoveryBackups()
        }
    }

    func performLoadRecoveryBackups() async {
        do {
            let backups = try await databaseRecovery.availableBackups()
            var next = settingsState
            next.recoveryBackups = backups
            commitSettingsState(next)
        } catch let recoveryError as DatabaseRecoveryError {
            var next = settingsState
            next.recoveryBackups = []
            if case let .backupTooLarge(maximumBytes) = recoveryError {
                next.statusMessage = "Migration backup exceeds the supported \(Self.mebibytes(maximumBytes)) MiB restore limit; the database was not changed"
            } else {
                next.statusMessage = "Backup list unavailable; the database was not changed"
            }
            commitSettingsState(next)
        } catch {
            var next = settingsState
            next.recoveryBackups = []
            next.statusMessage = "Backup list unavailable; the database was not changed"
            commitSettingsState(next)
        }
    }

    func restoreLatestBackup() async {
        guard let confirmedBackup = settingsState.recoveryBackups.first else { return }
        await restoreBackup(confirmedBackup)
    }

    func restoreBackup(_ confirmedBackup: DatabaseBackup) async {
        if let restoreActivity {
            await restoreActivity.task.value
            return
        }
        guard case .recoveryRequired = state.health.database,
              terminationRecoveryGate == .idle,
              !isWriterQuiescing,
              state.lifecycle != .shuttingDown,
              state.lifecycle != .stopped,
              !isDatabaseRecoveryActionLocked,
              !settingsState.isRestoringDatabase else { return }
        terminationRecoveryGate = .restoring
        restoreActivityGeneration &+= 1
        let id = restoreActivityGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRestore(confirmedBackup)
        }
        restoreActivity = AppRuntimeActivity(id: id, task: task)
        await task.value
        if restoreActivity?.id == id {
            restoreActivity = nil
        }
        if terminationRecoveryGate == .restoring {
            terminationRecoveryGate = .idle
        }
    }

    func retryDatabasePreservation() async {
        if let preservationActivity {
            await preservationActivity.task.value
            return
        }
        guard settingsState.databaseRecoveryDisposition == .preservationRetryRequired,
              terminationRecoveryGate == .idle,
              !settingsState.isRestoringDatabase else { return }
        terminationRecoveryGate = .preserving
        preservationActivityGeneration &+= 1
        let id = preservationActivityGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPreservationRetry()
        }
        preservationActivity = AppRuntimeActivity(id: id, task: task)
        await task.value
        if preservationActivity?.id == id {
            preservationActivity = nil
        }
        if terminationRecoveryGate == .preserving {
            terminationRecoveryGate = .idle
        }
    }

    private func performPreservationRetry() async {
        var next = settingsState
        next.isRestoringDatabase = true
        next.statusMessage = "Retrying recovery artifact preservation…"
        commitSettingsState(next)
        do {
            try await databaseRecovery.retryPreservation()
            finishRecoveryOperation(
                disposition: .requiresRelaunch,
                status: "Recovery artifact preserved and verified · Tokenboard retains at most the newest two local pre-restore snapshots · Quit and reopen Tokenboard"
            )
        } catch let recoveryError as DatabaseRecoveryError
            where recoveryError == .cleanupPending {
            finishRecoveryOperation(
                disposition: .requiresRelaunch,
                status: "Recovery artifact preserved and verified · After cleanup, Tokenboard retains at most the newest two local pre-restore snapshots · Reopen Tokenboard"
            )
        } catch let recoveryError as DatabaseRecoveryError
            where recoveryError == .preservationFailed {
            finishRecoveryOperation(
                disposition: .preservationFailed,
                status: "The recovery artifact could not be retained · Reveal Data or quit Tokenboard"
            )
        } catch {
            finishRecoveryOperation(
                disposition: .preservationRetryRequired,
                status: "Recovery artifact preservation failed · Reveal Data and retry"
            )
        }
    }

    private func performRestore(_ confirmedBackup: DatabaseBackup) async {
        var nextSettings = settingsState
        nextSettings.isRestoringDatabase = true
        nextSettings.statusMessage = "Stopping local writers before restore…"
        commitSettingsState(nextSettings)
        do {
            let backup = try await databaseRecovery.restore(confirmedBackup) { [weak self] in
                guard let self else { return }
                try await self.prepareForDatabaseRecovery().get()
            }
            finishRecoveryOperation(
                disposition: .requiresRelaunch,
                status: "Backup from \(backup.modificationDate.formatted(date: .abbreviated, time: .shortened)) restored and verified · Tokenboard retains at most the newest two local pre-restore snapshots · Quit and reopen Tokenboard",
                publishStopped: true
            )
        } catch let recoveryError as DatabaseRecoveryError
            where recoveryError == .cleanupPending
                || recoveryError == .restoreFailedCleanupPending
                || recoveryError == .rollbackCompleted {
            finishRecoveryOperation(
                disposition: .requiresRelaunch,
                status: recoveryError == .cleanupPending
                    ? "Restore completed and verified · A recovery artifact was preserved for cleanup; afterward Tokenboard retains at most the newest two local pre-restore snapshots · Quit and reopen Tokenboard"
                    : "Original database rollback completed · A recovery artifact was preserved for cleanup; afterward Tokenboard retains at most the newest two local pre-restore snapshots · Quit or Reveal Data",
                publishStopped: true
            )
        } catch let recoveryError as DatabaseRecoveryError
            where recoveryError == .preservationRetryRequired {
            finishRecoveryOperation(
                disposition: .preservationRetryRequired,
                status: "Recovery changed the database; a verified recovery snapshot is held open by Tokenboard until preservation succeeds · Reveal Data and retry",
                publishStopped: true
            )
        } catch let recoveryError as DatabaseRecoveryError
            where recoveryError == .preservationFailed {
            finishRecoveryOperation(
                disposition: .preservationFailed,
                status: "Restore changed the database, but the recovery artifact could not be retained · Reveal Data or quit Tokenboard",
                publishStopped: true
            )
        } catch let recoveryError as DatabaseRecoveryError {
            if recoveryBarrierTask != nil {
                finishRecoveryOperation(
                    disposition: .requiresRelaunch,
                    status: "Restore could not complete after local writers stopped · Quit and reopen Tokenboard",
                    publishStopped: true
                )
            } else if case let .backupTooLarge(maximumBytes) = recoveryError {
                finishRecoveryOperation(
                    status: "Migration backup exceeds the supported \(Self.mebibytes(maximumBytes)) MiB restore limit; the database was not changed"
                )
            } else {
                finishRecoveryOperation(
                    status: "Restore failed safely · Existing database and backup were preserved"
                )
            }
        } catch {
            if recoveryBarrierTask != nil {
                finishRecoveryOperation(
                    disposition: .requiresRelaunch,
                    status: "Restore could not complete after local writers stopped · Quit and reopen Tokenboard",
                    publishStopped: true
                )
            } else {
                finishRecoveryOperation(
                    status: "Restore failed safely · Existing database and backup were preserved"
                )
            }
        }
    }

    private func finishRecoveryOperation(
        disposition: DatabaseRecoveryDisposition? = nil,
        status: String,
        publishStopped: Bool = false
    ) {
        var next = settingsState
        next.isRestoringDatabase = false
        if let disposition {
            next.databaseRecoveryDisposition = disposition
        }
        next.statusMessage = status
        commitSettingsState(next)
        if publishStopped {
            publishStoppedState()
        }
    }

    func performRefreshSettings(statusMessage: String?) async {
        if case .recoveryRequired = state.health.database {
            await performLoadRecoveryBackups()
            commitSettingsState(settingsSnapshot(
                pricing: settingsState.pricing,
                statusMessage: statusMessage ?? settingsState.statusMessage,
                sourceMutationInProgress: false
            ))
            return
        }
        guard await ensureReady(retryFailed: false) else {
            setSettingsStatus("Settings unavailable until startup completes")
            return
        }
        setSettingsLoading(true)
        do {
            let interval = state.selectedPeriod.interval(
                containing: now(),
                calendar: calendar
            )
            let pricing = try await ledger.pricingSnapshot()
            let rows = try await ledger.usageRows(in: interval, calendar: calendar)
            let skippedCount = try await ledger.skippedRecordCount()
            let catalogStatus = await pricingInbox.status()
            let priceResolver = try PriceResolver(pricing: pricing)
            let resolution = try priceResolver.resolve(rows: rows)
            let unpricedUsage = try priceResolver.unpricedUsage(rows: rows)
            let pricingHealth: TokenboardHealth.PricingState
            if case .invalid = catalogStatus {
                pricingHealth = .warning(
                    message: TokenboardHealth.Issue.invalidPricingCatalog.message
                )
            } else {
                pricingHealth = .healthy
            }
            var published = state
            published.health = published.health.replacing(
                skippedRecordCount: skippedCount,
                unpricedTokens: resolution.unpricedTokens,
                pricing: pricingHealth
            )
            commitState(published)

            commitSettingsState(settingsSnapshot(
                pricing: PricingSettingsState(
                    activeModels: activeModelPricing(
                        in: pricing,
                        on: LocalDay(date: now(), calendar: calendar).value
                    ),
                    unpricedUsage: unpricedUsage,
                    exchangeRates: pricing.latestExchangeRates,
                    activeCatalogID: pricing.catalogIDs.last,
                    catalogStatus: catalogStatus,
                    coveragePeriod: state.selectedPeriod
                ),
                statusMessage: statusMessage,
                sourceMutationInProgress: sourceMutation != nil,
                diagnosticsHealth: published.health
            ))
        } catch {
            setSettingsLoading(false)
            setSettingsStatus("Settings unavailable: \(Self.errorDescription(error))")
        }
    }

    private func settingsSnapshot(
        pricing: PricingSettingsState,
        statusMessage: String?,
        sourceMutationInProgress: Bool,
        diagnosticsHealth: TokenboardHealth? = nil
    ) -> AppSettingsState {
        AppSettingsState(
            sources: sourceSettings(),
            pricing: pricing,
            diagnostics: .current(health: diagnosticsHealth ?? state.health),
            statusMessage: statusMessage,
            isLoading: false,
            isSourceMutationInProgress: sourceMutationInProgress,
            recoveryBackups: settingsState.recoveryBackups,
            isRestoringDatabase: settingsState.isRestoringDatabase,
            databaseRecoveryDisposition: settingsState.databaseRecoveryDisposition
        )
    }

    func runSettingsOperation(
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        while let existing = settingsActivity {
            await existing.task.value
            if settingsActivity?.id == existing.id {
                settingsActivity = nil
            }
        }
        guard !isWriterQuiescing,
              !isDatabaseRestoreInProgress,
              !isDatabaseRecoveryActionLocked,
              state.lifecycle != .shuttingDown,
              state.lifecycle != .stopped else { return }
        settingsActivityGeneration &+= 1
        let id = settingsActivityGeneration
        let task = Task { @MainActor in await operation() }
        settingsActivity = AppRuntimeActivity(id: id, task: task)
        await task.value
        if settingsActivity?.id == id {
            settingsActivity = nil
        }
    }

    private func sourceSettings() -> [Provider: SourceSettingsState] {
        Dictionary(uniqueKeysWithValues: Provider.allCases.map { provider in
            let health = state.sourceHealth[provider] ?? .notGranted
            return (
                provider,
                SourceSettingsState(
                    provider: provider,
                    resolvedPath: activeGrants[provider]?.root.path,
                    accessStatus: activeGrants[provider] == nil
                        ? "Not granted"
                        : "Read-only access",
                    fileCount: state.sourceFileCounts[provider, default: 0],
                    lastScan: state.lastSuccessfulScans[provider],
                    health: health
                )
            )
        })
    }

    private func activeModelPricing(
        in pricing: PricingSnapshot,
        on day: String
    ) -> [ActiveModelPricingSummary] {
        struct Key: Hashable {
            let provider: Provider
            let modelID: String
        }
        var active: [Key: [UsageMetric: StoredPriceRate]] = [:]
        for rate in pricing.rates where rate.effectiveFrom <= day
            && (rate.effectiveTo.map { day < $0 } ?? true) {
            let key = Key(provider: rate.provider, modelID: rate.canonicalModelID)
            if let existing = active[key]?[rate.metric],
               existing.effectiveFrom >= rate.effectiveFrom {
                continue
            }
            active[key, default: [:]][rate.metric] = rate
        }
        return active.map { key, rates in
            ActiveModelPricingSummary(
                provider: key.provider,
                canonicalModelID: key.modelID,
                rates: rates.mapValues(\.usdPerMillion)
            )
        }.sorted {
            ($0.provider.rawValue, $0.canonicalModelID)
                < ($1.provider.rawValue, $1.canonicalModelID)
        }
    }

    private func setSettingsLoading(_ isLoading: Bool) {
        var next = settingsState
        next.isLoading = isLoading
        commitSettingsState(next)
    }

    private func setSettingsStatus(_ status: String) {
        var next = settingsState
        next.statusMessage = status
        commitSettingsState(next)
    }

    func setSourceMutationInProgress(_ inProgress: Bool) {
        var next = settingsState
        next.isSourceMutationInProgress = inProgress
        commitSettingsState(next)
    }

    private static func mebibytes(_ bytes: Int) -> Int {
        bytes / (1_024 * 1_024)
    }
}

private enum AppSettingsError: LocalizedError {
    case pasteboardWriteFailed

    var errorDescription: String? {
        "The pasteboard did not accept plain text"
    }
}
