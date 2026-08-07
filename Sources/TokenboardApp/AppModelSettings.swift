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
                )
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
            reconcileWarningPresentation(&next)
            commitState(next)
            await querySelectedSummary()
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
            next = settingsState
            next.isRestoringDatabase = false
            next.databaseRecoveryDisposition = .requiresRelaunch
            next.statusMessage = "Recovery artifact preserved and verified · Tokenboard retains at most the newest two local pre-restore snapshots · Quit and reopen Tokenboard"
            commitSettingsState(next)
        } catch let recoveryError as DatabaseRecoveryError
            where recoveryError == .cleanupPending {
            next = settingsState
            next.isRestoringDatabase = false
            next.databaseRecoveryDisposition = .requiresRelaunch
            next.statusMessage = "Recovery artifact preserved and verified · After cleanup, Tokenboard retains at most the newest two local pre-restore snapshots · Reopen Tokenboard"
            commitSettingsState(next)
        } catch let recoveryError as DatabaseRecoveryError
            where recoveryError == .preservationFailed {
            next = settingsState
            next.isRestoringDatabase = false
            next.databaseRecoveryDisposition = .preservationFailed
            next.statusMessage = "The recovery artifact could not be retained · Reveal Data or quit Tokenboard"
            commitSettingsState(next)
        } catch {
            next = settingsState
            next.isRestoringDatabase = false
            next.databaseRecoveryDisposition = .preservationRetryRequired
            next.statusMessage = "Recovery artifact preservation failed · Reveal Data and retry"
            commitSettingsState(next)
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
            nextSettings = settingsState
            nextSettings.isRestoringDatabase = false
            nextSettings.databaseRecoveryDisposition = .requiresRelaunch
            nextSettings.statusMessage = "Backup from \(backup.modificationDate.formatted(date: .abbreviated, time: .shortened)) restored and verified · Tokenboard retains at most the newest two local pre-restore snapshots · Quit and reopen Tokenboard"
            commitSettingsState(nextSettings)
            publishStoppedState()
        } catch let recoveryError as DatabaseRecoveryError
            where recoveryError == .cleanupPending
                || recoveryError == .restoreFailedCleanupPending
                || recoveryError == .rollbackCompleted {
            nextSettings = settingsState
            nextSettings.isRestoringDatabase = false
            nextSettings.databaseRecoveryDisposition = .requiresRelaunch
            nextSettings.statusMessage = recoveryError == .cleanupPending
                ? "Restore completed and verified · A recovery artifact was preserved for cleanup; afterward Tokenboard retains at most the newest two local pre-restore snapshots · Quit and reopen Tokenboard"
                : "Original database rollback completed · A recovery artifact was preserved for cleanup; afterward Tokenboard retains at most the newest two local pre-restore snapshots · Quit or Reveal Data"
            commitSettingsState(nextSettings)
            publishStoppedState()
        } catch let recoveryError as DatabaseRecoveryError
            where recoveryError == .preservationRetryRequired {
            nextSettings = settingsState
            nextSettings.isRestoringDatabase = false
            nextSettings.databaseRecoveryDisposition = .preservationRetryRequired
            nextSettings.statusMessage = "Recovery changed the database; a verified recovery snapshot is held open by Tokenboard until preservation succeeds · Reveal Data and retry"
            commitSettingsState(nextSettings)
            publishStoppedState()
        } catch let recoveryError as DatabaseRecoveryError
            where recoveryError == .preservationFailed {
            nextSettings = settingsState
            nextSettings.isRestoringDatabase = false
            nextSettings.databaseRecoveryDisposition = .preservationFailed
            nextSettings.statusMessage = "Restore changed the database, but the recovery artifact could not be retained · Reveal Data or quit Tokenboard"
            commitSettingsState(nextSettings)
            publishStoppedState()
        } catch let recoveryError as DatabaseRecoveryError {
            nextSettings = settingsState
            nextSettings.isRestoringDatabase = false
            if case let .backupTooLarge(maximumBytes) = recoveryError {
                nextSettings.statusMessage = "Migration backup exceeds the supported \(Self.mebibytes(maximumBytes)) MiB restore limit; the database was not changed"
            } else {
                nextSettings.statusMessage = "Restore failed safely · Existing database and backup were preserved"
            }
            commitSettingsState(nextSettings)
        } catch {
            nextSettings = settingsState
            nextSettings.isRestoringDatabase = false
            nextSettings.statusMessage = "Restore failed safely · Existing database and backup were preserved"
            commitSettingsState(nextSettings)
        }
    }

    func performRefreshSettings(statusMessage: String?) async {
        if case .recoveryRequired = state.health.database {
            await performLoadRecoveryBackups()
            commitSettingsState(AppSettingsState(
                sources: sourceSettings(),
                pricing: settingsState.pricing,
                diagnostics: SettingsDiagnosticsState(
                    health: state.health,
                    parserVersions: [
                        .claudeCode: ClaudeCodeAdapter.parserVersion,
                        .codex: CodexAdapter.parserVersion
                    ]
                ),
                statusMessage: statusMessage ?? settingsState.statusMessage,
                isLoading: false,
                isSourceMutationInProgress: false,
                recoveryBackups: settingsState.recoveryBackups,
                isRestoringDatabase: settingsState.isRestoringDatabase,
                databaseRecoveryDisposition: settingsState.databaseRecoveryDisposition
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
            let resolution = try PriceResolver().resolve(rows: rows, pricing: pricing)
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
            reconcileWarningPresentation(&published)
            commitState(published)

            commitSettingsState(AppSettingsState(
                sources: sourceSettings(),
                pricing: PricingSettingsState(
                    activeModels: activeModelPricing(
                        in: pricing,
                        on: LocalDay(date: now(), calendar: calendar).value
                    ),
                    exchangeRates: pricing.latestExchangeRates,
                    activeCatalogID: pricing.catalogIDs.last,
                    catalogStatus: catalogStatus
                ),
                diagnostics: SettingsDiagnosticsState(
                    health: published.health,
                    parserVersions: [
                        .claudeCode: ClaudeCodeAdapter.parserVersion,
                        .codex: CodexAdapter.parserVersion
                    ]
                ),
                statusMessage: statusMessage,
                isLoading: false,
                isSourceMutationInProgress: sourceMutation != nil,
                recoveryBackups: settingsState.recoveryBackups,
                isRestoringDatabase: settingsState.isRestoringDatabase,
                databaseRecoveryDisposition: settingsState.databaseRecoveryDisposition
            ))
        } catch {
            setSettingsLoading(false)
            setSettingsStatus("Settings unavailable: \(Self.errorDescription(error))")
        }
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
