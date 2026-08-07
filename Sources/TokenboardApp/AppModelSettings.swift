import Foundation
import TokenboardCore

@MainActor
extension AppModel {
    func refreshSettings() async {
        await runSettingsOperation { [weak self] in
            await self?.performRefreshSettings(statusMessage: nil)
        }
    }

    func copyAgentPrompt(source: AgentPricingSource) async {
        await runSettingsOperation { [weak self] in
            await self?.performCopyAgentPrompt(source: source)
        }
    }

    private func performCopyAgentPrompt(source: AgentPricingSource) async {
        do {
            try await pricingInbox.exportCurrentSnapshot()
            let inbox = applicationPaths.pricing.appending(
                path: "Inbox",
                directoryHint: .isDirectory
            )
            let prompt = AgentPromptBuilder().build(
                source: source,
                paths: AgentPricingPaths(
                    currentCatalog: applicationPaths.pricing.appending(
                        path: PricingInbox.currentCatalogFilename
                    ),
                    temporaryCandidate: inbox.appending(
                        path: PricingInbox.temporaryCandidateFilename
                    ),
                    finalCandidate: inbox.appending(path: PricingInbox.candidateFilename)
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

    func applyPendingPricing(reviewedIdentity identity: PricingCandidateIdentity) async {
        await runSettingsOperation { [weak self] in
            await self?.performApplyPendingPricing(reviewedIdentity: identity)
        }
    }

    private func performApplyPendingPricing(reviewedIdentity identity: PricingCandidateIdentity) async {
        guard settingsState.pricing.pendingCandidate?.identity == identity else {
            setSettingsStatus("Pricing candidate changed · Review the replacement before applying")
            return
        }
        guard settingsState.pricing.canApply else {
            setSettingsStatus("Pricing candidate has conflicts that block Apply")
            return
        }
        setSettingsLoading(true)
        do {
            let outcome = try await pricingInbox.applyPending(matching: identity)
            await querySelectedSummary()
            await performRefreshSettings(
                statusMessage: outcome == .finalized
                    ? "Pricing applied · API-equivalent value refreshed"
                    : "Pricing applied · File finalization will retry"
            )
        } catch {
            await performRefreshSettings(statusMessage: error as? PricingInboxError == .candidateChanged
                ? "Pricing candidate changed · Review the replacement before applying"
                : "Pricing apply failed · Active pricing unchanged")
        }
    }

    func rejectPendingPricing(rejectedIdentity identity: PricingCandidateIdentity) async {
        await runSettingsOperation { [weak self] in
            await self?.performRejectPendingPricing(rejectedIdentity: identity)
        }
    }

    private func performRejectPendingPricing(rejectedIdentity identity: PricingCandidateIdentity) async {
        guard settingsState.pricing.pendingCandidate?.identity == identity else {
            setSettingsStatus("Pricing candidate changed · Review the replacement before rejecting")
            return
        }
        setSettingsLoading(true)
        do {
            let outcome = try await pricingInbox.rejectPending(matching: identity)
            await performRefreshSettings(
                statusMessage: outcome == .finalized
                    ? "Pricing candidate rejected · Active pricing unchanged"
                    : "Pricing rejected · File finalization will retry"
            )
        } catch {
            await performRefreshSettings(statusMessage: error as? PricingInboxError == .candidateChanged
                ? "Pricing candidate changed · Review the replacement before rejecting"
                : "Pricing rejection failed · Active pricing unchanged")
        }
    }

    func retryPricingFinalization() async {
        await runSettingsOperation { [weak self] in
            await self?.performRetryPricingFinalization()
        }
    }

    private func performRetryPricingFinalization() async {
        guard !settingsState.isFinalizationRetryInProgress,
              let identity = settingsState.pricing.finalizationIdentity else {
            return
        }
        setFinalizationRetryInProgress(true)
        defer { setFinalizationRetryInProgress(false) }
        do {
            let outcome = try await pricingInbox.retryFinalization(matching: identity)
            if outcome == .applied {
                await querySelectedSummary()
            }
            await performRefreshSettings(statusMessage: outcome == .applied
                ? "Pricing file finalization completed"
                : "Rejected candidate file finalization completed")
        } catch {
            await performRefreshSettings(statusMessage: error as? PricingInboxError == .candidateChanged
                ? "Pricing finalization changed · Refresh Settings before retrying"
                : "Pricing finalization retry failed · Files remain safely pending")
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
            clearDismissalIfWarningsResolved(next.health)
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

    private func performRefreshSettings(statusMessage: String?) async {
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
            let inboxStatus = await pricingInbox.status()
            let pending: PendingPricingCandidate?
            if case let .valid(candidate) = inboxStatus {
                pending = candidate
            } else {
                pending = nil
            }
            let preview = try pending.map {
                try PricingPreview.make(
                    rows: rows,
                    currentPricing: pricing,
                    candidate: $0.catalog
                )
            }
            let resolution = try PriceResolver().resolve(rows: rows, pricing: pricing)
            let pricingHealth: TokenboardHealth.PricingState
            if case .invalid = inboxStatus {
                pricingHealth = .warning(
                    message: TokenboardHealth.Issue.invalidPricingCandidate.message
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

            commitSettingsState(AppSettingsState(
                sources: sourceSettings(),
                pricing: PricingSettingsState(
                    activeCatalogIDs: pricing.catalogIDs.sorted(),
                    verificationDates: Array(Set(pricing.rates.map(\.verifiedAt))).sorted(),
                    provenanceURLs: Array(Set(pricing.rates.map(\.provenanceURL))).sorted {
                        $0.absoluteString < $1.absoluteString
                    },
                    unpricedModels: try unpricedModels(rows: rows, pricing: pricing),
                    pendingCandidate: pending,
                    preview: preview,
                    validationConflicts: [],
                    inboxStatus: inboxStatus,
                    isFinalizationRetryInProgress: settingsState
                        .isFinalizationRetryInProgress
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

    private func runSettingsOperation(
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

    private func unpricedModels(
        rows: [DailyUsageRow],
        pricing: PricingSnapshot
    ) throws -> [String] {
        var values = Set<String>()
        let resolver = PriceResolver()
        for row in rows where row.aggregation == .additive {
            let result = try resolver.resolve(rows: [row], pricing: pricing)
            if result.unpricedTokens > 0 {
                values.insert("\(row.provider.rawValue)/\(row.observedModelID)")
            }
        }
        return values.sorted()
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

    private func setFinalizationRetryInProgress(_ inProgress: Bool) {
        var next = settingsState
        next.isFinalizationRetryInProgress = inProgress
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
