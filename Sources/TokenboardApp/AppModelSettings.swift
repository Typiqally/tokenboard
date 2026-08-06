import Foundation
import TokenboardCore

@MainActor
extension AppModel {
    func refreshSettings() async {
        await refreshSettings(statusMessage: nil)
    }

    func copyAgentPrompt(source: AgentPricingSource) async {
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

    func applyPendingPricing() async {
        if settingsState.pricing.pendingCandidate == nil {
            await refreshSettings()
        }
        guard settingsState.pricing.canApply,
              let identity = settingsState.pricing.pendingCandidate?.identity else {
            setSettingsStatus("Pricing candidate has conflicts that block Apply")
            return
        }
        setSettingsLoading(true)
        do {
            let outcome = try await pricingInbox.applyPending(matching: identity)
            await querySelectedSummary()
            await refreshSettings(
                statusMessage: outcome == .finalized
                    ? "Pricing applied · API-equivalent value refreshed"
                    : "Pricing applied · File finalization will retry"
            )
        } catch {
            await refreshSettings(statusMessage: error as? PricingInboxError == .candidateChanged
                ? "Pricing candidate changed · Review the replacement before applying"
                : "Pricing apply failed · Active pricing unchanged")
        }
    }

    func rejectPendingPricing() async {
        guard let identity = settingsState.pricing.pendingCandidate?.identity else {
            setSettingsStatus("No pending pricing candidate")
            return
        }
        setSettingsLoading(true)
        do {
            let outcome = try await pricingInbox.rejectPending(matching: identity)
            await refreshSettings(
                statusMessage: outcome == .finalized
                    ? "Pricing candidate rejected · Active pricing unchanged"
                    : "Pricing rejected · File finalization will retry"
            )
        } catch {
            await refreshSettings(statusMessage: error as? PricingInboxError == .candidateChanged
                ? "Pricing candidate changed · Review the replacement before rejecting"
                : "Pricing rejection failed · Active pricing unchanged")
        }
    }

    func retryPricingFinalization() async {
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
            await refreshSettings(statusMessage: outcome == .applied
                ? "Pricing file finalization completed"
                : "Rejected candidate file finalization completed")
        } catch {
            await refreshSettings(statusMessage: error as? PricingInboxError == .candidateChanged
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
            next.sourceHealth[provider] = .notGranted
            next.onboardingRequired = true
            commitState(next)
            await querySelectedSummary()
            await refreshSettings(statusMessage: "Source access revoked · Committed totals retained")
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
                        "Historical import paused: \(Self.errorDescription(error))"
                    )
                }
            }
            setSettingsStatus("Source revoke failed: \(Self.errorDescription(error))")
        }
    }

    func revealLocalData() {
        localDataRevealer.reveal([applicationPaths.root])
    }

    private func refreshSettings(statusMessage: String?) async {
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
                    skippedRecordCount: skippedCount,
                    parserVersions: [
                        .claudeCode: ClaudeCodeAdapter.parserVersion,
                        .codex: CodexAdapter.parserVersion
                    ]
                ),
                statusMessage: statusMessage,
                isLoading: false,
                isSourceMutationInProgress: sourceMutation != nil
            ))
        } catch {
            setSettingsLoading(false)
            setSettingsStatus("Settings unavailable: \(Self.errorDescription(error))")
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
}

private enum AppSettingsError: LocalizedError {
    case pasteboardWriteFailed

    var errorDescription: String? {
        "The pasteboard did not accept plain text"
    }
}
