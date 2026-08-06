import Foundation
import TokenboardCore

@MainActor
extension AppModel {
    func launchIngestion(refreshExisting: Bool) async {
        guard activity == nil, isReadyForSources else { return }
        let generation = lifecycleGeneration
        activityGeneration &+= 1
        let id = activityGeneration
        var next = state
        next.isImporting = true
        commitState(next)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runIngestion(refreshExisting: refreshExisting, generation: generation)
        }
        activity = AppRuntimeActivity(id: id, task: task)
        await task.value
        if activity?.id == id {
            activity = nil
            if accepts(generation), state.lifecycle == .ready {
                next = state
                next.isImporting = false
                commitState(next)
            }
        }
    }

    func runIngestion(refreshExisting: Bool, generation: UInt64) async {
        guard readyGeneration == generation, accepts(generation), hasEveryGrant else { return }
        await ensureResultConsumer(generation: generation)
        guard readyGeneration == generation, accepts(generation) else { return }

        do {
            let result: IngestionBatchResult
            switch coordinatorStatus {
            case .inactive:
                prepareForCoordinatorStart()
                result = try await coordinator.start(roots: activeRoots())
                guard readyGeneration == generation, accepts(generation) else { return }
                coordinatorStatus = .active(runID: result.runID)
                discardPendingResults(exceptRunID: result.runID)
            case let .active(runID):
                guard refreshExisting else { return }
                result = await coordinator.refreshAll()
                guard readyGeneration == generation,
                      accepts(generation),
                      result.runID == runID else { return }
            case .starting:
                return
            }
            await submitAndWaitForIngestionResult(result, generation: generation)
        } catch {
            guard readyGeneration == generation, accepts(generation) else { return }
            coordinatorStatus = .inactive
            publishWarning("Historical import paused: \(Self.errorDescription(error))")
        }
    }

    func ensureResultConsumer(generation: UInt64) async {
        guard resultConsumerTask == nil else { return }
        let stream = await coordinator.results()
        guard readyGeneration == generation, accepts(generation) else { return }
        resultConsumerTask = Task { @MainActor [weak self] in
            for await result in stream {
                guard !Task.isCancelled else { break }
                await self?.receiveIngestionResult(result, generation: generation)
            }
        }
    }

    func prepareForCoordinatorStart() {
        let discarded = Array(pendingIngestionResults.keys)
        pendingIngestionResults.removeAll()
        discarded.forEach(settleIngestionResult)
        lastAppliedSequence.removeAll()
        coordinatorStatus = .starting
    }

    func discardPendingResults(exceptRunID runID: UInt64) {
        let staleKeys = pendingIngestionResults.keys.filter { $0.runID != runID }
        for key in staleKeys {
            pendingIngestionResults[key] = nil
            settleIngestionResult(key)
        }
    }

    func activateRestoredCoordinator(
        _ result: IngestionBatchResult,
        generation: UInt64
    ) async {
        coordinatorStatus = .active(runID: result.runID)
        discardPendingResults(exceptRunID: result.runID)
        await submitAndWaitForIngestionResult(result, generation: generation)
    }

    func submitAndWaitForIngestionResult(
        _ result: IngestionBatchResult,
        generation: UInt64
    ) async {
        let key = IngestionResultKey(runID: result.runID, sequence: result.sequence)
        await receiveIngestionResult(result, generation: generation)
        await waitForIngestionResult(key)
    }

    func receiveIngestionResult(
        _ result: IngestionBatchResult,
        generation: UInt64
    ) async {
        let key = IngestionResultKey(runID: result.runID, sequence: result.sequence)
        guard readyGeneration == generation, accepts(generation) else {
            settleIngestionResult(key)
            return
        }
        if result.sequence <= lastAppliedSequence[result.runID, default: 0] {
            settleIngestionResult(key)
            return
        }
        switch coordinatorStatus {
        case let .active(runID) where runID != result.runID:
            knownIngestionResults.insert(key)
            settleIngestionResult(key)
            return
        case .inactive:
            knownIngestionResults.insert(key)
            settleIngestionResult(key)
            return
        case .active, .starting:
            break
        }
        if knownIngestionResults.insert(key).inserted {
            pendingIngestionResults[key] = result
        }
        await processPendingIngestionResults(generation: generation)
    }

    func processPendingIngestionResults(generation: UInt64) async {
        guard !isProcessingIngestionResults,
              case let .active(runID) = coordinatorStatus else { return }
        isProcessingIngestionResults = true

        while readyGeneration == generation, accepts(generation),
              coordinatorStatus == .active(runID: runID) {
            let candidates = pendingIngestionResults
                .filter { $0.key.runID == runID }
                .sorted { $0.key.sequence < $1.key.sequence }
            guard let (key, result) = candidates.first else { break }
            pendingIngestionResults[key] = nil
            guard result.sequence > lastAppliedSequence[runID, default: 0] else {
                settleIngestionResult(key)
                continue
            }
            await applyBatchAndQuery(result, generation: generation)
            if readyGeneration == generation,
               accepts(generation),
               coordinatorStatus == .active(runID: runID) {
                lastAppliedSequence[runID] = result.sequence
            }
            settleIngestionResult(key)
        }
        isProcessingIngestionResults = false
        if readyGeneration == generation,
           accepts(generation),
           case let .active(currentRunID) = coordinatorStatus,
           pendingIngestionResults.keys.contains(where: { $0.runID == currentRunID }) {
            await processPendingIngestionResults(generation: generation)
        }
    }

    func waitForIngestionResult(_ key: IngestionResultKey) async {
        guard key.sequence > lastAppliedSequence[key.runID, default: 0],
              knownIngestionResults.contains(key) else { return }
        await withCheckedContinuation { continuation in
            ingestionResultWaiters[key, default: []].append(continuation)
        }
    }

    func settleIngestionResult(_ key: IngestionResultKey) {
        knownIngestionResults.remove(key)
        let waiters = ingestionResultWaiters.removeValue(forKey: key) ?? []
        waiters.forEach { $0.resume() }
    }

    func settleAllIngestionWaiters() {
        let waiters = ingestionResultWaiters.values.flatMap { $0 }
        ingestionResultWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func applyBatchAndQuery(
        _ result: IngestionBatchResult,
        generation: UInt64
    ) async {
        if result.requiresInventoryRefresh {
            let recovery = await coordinator.refreshAll()
            guard readyGeneration == generation,
                  accepts(generation),
                  coordinatorStatus == .active(runID: result.runID),
                  recovery.runID == result.runID else { return }
            await receiveIngestionResult(recovery, generation: generation)
            return
        }

        let period = state.selectedPeriod
        let (queryID, summaryResult) = await requestSummary(period: period)
        guard readyGeneration == generation,
              accepts(generation),
              coordinatorStatus == .active(runID: result.runID) else { return }

        var next = state
        let hasSuccessfulProvider = result.providers.values.contains { outcome in
            if case .success = outcome { return true }
            return false
        }
        let successfulUpdate = hasSuccessfulProvider ? now() : nil
        for (provider, outcome) in result.providers {
            switch outcome {
            case let .success(discoveredFiles, _):
                if result.scope == .inventory {
                    next.sourceFileCounts[provider] = discoveredFiles
                }
                if let successfulUpdate,
                   result.scope == .inventory
                    || !Self.isWarning(next.sourceHealth[provider] ?? .notGranted) {
                    next.sourceHealth[provider] = .healthy(
                        fileCount: next.sourceFileCounts[provider, default: 0],
                        lastUpdated: successfulUpdate
                    )
                }
            case let .attention(discoveredFiles, _):
                if result.scope == .inventory {
                    next.sourceFileCounts[provider] = discoveredFiles
                }
                next.sourceHealth[provider] = .warning(
                    message: "Some logs need attention"
                )
            case .failure:
                next.sourceHealth[provider] = .warning(message: "Import failed")
            }
        }
        if hasSuccessfulProvider {
            next.lastUpdated = successfulUpdate
        }
        if queryID == queryGeneration,
           period == state.selectedPeriod,
           case let .success(summary) = summaryResult {
            lastSummary = summary
            next.presentation = makePresentation(summary: summary, state: next)
        } else if let lastSummary {
            next.presentation = makePresentation(summary: lastSummary, state: next)
        }
        if case let .failure(error) = summaryResult, queryID == queryGeneration {
            for provider in Provider.allCases {
                next.sourceHealth[provider] = .warning(
                    message: "Summary unavailable: \(Self.errorDescription(error))"
                )
            }
            if let lastSummary {
                next.presentation = makePresentation(summary: lastSummary, state: next)
            }
        }
        commitState(next)
    }

    func launchReplacement(provider: Provider, url: URL) async {
        guard activity == nil, isReadyForSources else { return }
        let generation = lifecycleGeneration
        activityGeneration &+= 1
        let id = activityGeneration
        var next = state
        next.isImporting = true
        commitState(next)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runReplacement(provider: provider, url: url, generation: generation)
        }
        activity = AppRuntimeActivity(id: id, task: task)
        await task.value
        if activity?.id == id {
            activity = nil
            if accepts(generation), state.lifecycle == .ready {
                next = state
                next.isImporting = false
                commitState(next)
            }
        }
    }

    func runReplacement(
        provider: Provider,
        url: URL,
        generation: UInt64
    ) async {
        guard readyGeneration == generation, accepts(generation) else { return }
        let prepared: PreparedSourceGrant
        do {
            prepared = try grantStore.prepareGrant(url: url, for: provider)
        } catch {
            return
        }

        let oldRoots = activeRoots()
        let oldGrant = activeGrants[provider]
        let oldState = state
        let hadCompleteOldRuntime = oldRoots.count == Provider.allCases.count
            && coordinatorStatus.isActive
        var proposedRoots = oldRoots
        proposedRoots[provider] = prepared.root
        proposedRoots = IngestionRootValidator.canonicalize(proposedRoots)
        if proposedRoots.count == Provider.allCases.count {
            do {
                proposedRoots = try IngestionRootValidator.validate(proposedRoots)
            } catch {
                prepared.close()
                return
            }
        }

        let fileCount: Int
        do {
            fileCount = try await discoveredFileCount(under: prepared.root)
        } catch {
            prepared.close()
            return
        }
        guard readyGeneration == generation, accepts(generation) else {
            prepared.close()
            return
        }

        await coordinator.stop()
        guard readyGeneration == generation, accepts(generation) else {
            prepared.close()
            return
        }
        coordinatorStatus = .inactive

        let newGrant = grantStore.activate(prepared, for: provider)
        activeGrants[provider] = newGrant

        if preferences.historicalImportApproved, hasEveryGrant {
            do {
                await ensureResultConsumer(generation: generation)
                prepareForCoordinatorStart()
                let result = try await coordinator.start(roots: proposedRoots)
                guard readyGeneration == generation, accepts(generation) else {
                    await coordinator.stop()
                    restoreGrantAfterInterruptedReplacement(
                        provider: provider,
                        oldGrant: oldGrant,
                        newGrant: newGrant
                    )
                    return
                }
                coordinatorStatus = .active(runID: result.runID)
                discardPendingResults(exceptRunID: result.runID)
                grantStore.commitBookmark(prepared, for: provider)
                oldGrant?.close()
                var accepted = state
                accepted.grantedProviders = Set(activeGrants.keys)
                accepted.onboardingRequired = false
                commitState(accepted)
                await submitAndWaitForIngestionResult(result, generation: generation)
                return
            } catch {
                await coordinator.stop()
                activeGrants[provider] = oldGrant
                newGrant.close()
                coordinatorStatus = .inactive
                guard readyGeneration == generation, accepts(generation) else { return }
                commitState(oldState)
                guard hadCompleteOldRuntime else { return }
                do {
                    prepareForCoordinatorStart()
                    let restored = try await coordinator.start(roots: oldRoots)
                    guard readyGeneration == generation, accepts(generation) else { return }
                    await activateRestoredCoordinator(restored, generation: generation)
                } catch {
                    coordinatorStatus = .inactive
                    publishWarning("Historical import paused: \(Self.errorDescription(error))")
                }
                return
            }
        }

        grantStore.commitBookmark(prepared, for: provider)
        oldGrant?.close()
        var next = state
        next.grantedProviders.insert(provider)
        next.sourceFileCounts[provider] = fileCount
        next.sourceHealth[provider] = .indexing(fileCount: fileCount)
        next.onboardingRequired = !preferences.historicalImportApproved || !hasEveryGrant
        commitState(next)
    }

    func restoreGrantAfterInterruptedReplacement(
        provider: Provider,
        oldGrant: ActiveSourceGrant?,
        newGrant: ActiveSourceGrant
    ) {
        activeGrants[provider] = oldGrant
        newGrant.close()
    }

    func requeryWithoutScanning() async {
        guard preferences.historicalImportApproved,
              isReadyForSources else { return }
        await querySelectedSummary()
    }

    func querySelectedSummary() async {
        let generation = lifecycleGeneration
        let period = state.selectedPeriod
        let (queryID, result) = await requestSummary(period: period)
        switch result {
        case let .success(summary):
            guard readyGeneration == generation,
                  accepts(generation),
                  queryGeneration == queryID,
                  state.selectedPeriod == period else { return }
            lastSummary = summary
            var next = state
            next.presentation = makePresentation(summary: summary, state: next)
            commitState(next)
        case let .failure(error):
            guard readyGeneration == generation,
                  accepts(generation),
                  queryGeneration == queryID else { return }
            publishWarning("Summary unavailable: \(Self.errorDescription(error))")
        }
    }

    func requestSummary(
        period: CalendarPeriod
    ) async -> (UInt64, Result<UsageSummary, Error>) {
        queryGeneration &+= 1
        let queryID = queryGeneration
        let queryService = self.queryService
        let requestedAt = now()
        let calendar = self.calendar
        let task = Task<Result<UsageSummary, Error>, Never> {
            do {
                return .success(try await queryService.summary(
                    period: period,
                    now: requestedAt,
                    calendar: calendar
                ))
            } catch {
                return .failure(error)
            }
        }
        inFlightQueries[queryID] = task
        let result = await task.value
        inFlightQueries[queryID] = nil
        return (queryID, result)
    }

    func makePresentation(
        summary: UsageSummary,
        state: AppPublishedState
    ) -> MenuPresentation {
        MenuPresentation(
            summary: summary,
            displayMetric: state.selectedDisplayMetric,
            hasHealthWarning: state.sourceHealth.values.contains(where: Self.isWarning)
        )
    }

    func discoveredFileCount(under root: URL) async throws -> Int {
        let discovery = self.discovery
        return try await Task.detached(priority: .utility) {
            try discovery.jsonlFiles(under: root).count
        }.value
    }

    func activeRoots() -> [Provider: URL] {
        Dictionary(uniqueKeysWithValues: activeGrants.map { ($0.key, $0.value.root) })
    }

    func closeActiveGrants() {
        for grant in activeGrants.values { grant.close() }
        activeGrants.removeAll()
    }

    func accepts(_ generation: UInt64) -> Bool {
        lifecycleGeneration == generation
            && state.lifecycle != .shuttingDown
            && state.lifecycle != .stopped
            && !Task.isCancelled
    }

    func publishWarning(_ message: String) {
        var next = state
        next.sourceHealth = warningHealth(message: message)
        if let lastSummary {
            next.presentation = makePresentation(summary: lastSummary, state: next)
        }
        commitState(next)
    }

    func warningHealth(message: String) -> [Provider: SourceHealth] {
        Dictionary(uniqueKeysWithValues: Provider.allCases.map {
            ($0, SourceHealth.warning(message: message))
        })
    }

    static func isWarning(_ health: SourceHealth) -> Bool {
        switch health {
        case .notGranted, .warning:
            true
        case .indexing, .healthy:
            false
        }
    }

    static func errorDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
