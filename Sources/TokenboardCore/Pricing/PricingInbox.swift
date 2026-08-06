import Darwin
import Dispatch
import Foundation
import CryptoKit

public struct PricingCandidateIdentity: Equatable, Hashable, Sendable {
    public let digest: String

    public init(canonicalJSON: Data) {
        digest = SHA256.hash(data: canonicalJSON).map { String(format: "%02x", $0) }.joined()
    }
}

public enum PricingInboxInvalidReason: Equatable, Sendable {
    case invalidCatalog
    case unsafeFile
    case candidateTooLarge
    case unreadableCandidate
}

public enum PricingInboxStatus: Equatable, Sendable {
    case empty
    case valid(PendingPricingCandidate)
    case invalid(PricingInboxInvalidReason)
    case applying(PricingCandidateIdentity)
    case appliedFinalizing(PricingCandidateIdentity)
    case rejecting(PricingCandidateIdentity)
    case rejectedFinalizing(PricingCandidateIdentity)
}

public enum PricingApplyOutcome: Equatable, Sendable {
    case finalized
    case committedFinalizationPending
}

public enum PricingRejectOutcome: Equatable, Sendable {
    case finalized
    case rejectedFinalizationPending
}

public struct PendingPricingCandidate: Equatable, Sendable {
    public let catalog: ValidatedPricingCatalog
    public let canonicalJSON: Data
    public let diff: CatalogDiff
    public let sourceURL: URL
    public let identity: PricingCandidateIdentity

    public init(
        catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        diff: CatalogDiff,
        sourceURL: URL
    ) {
        self.catalog = catalog
        self.canonicalJSON = canonicalJSON
        self.diff = diff
        self.sourceURL = sourceURL
        identity = PricingCandidateIdentity(canonicalJSON: canonicalJSON)
    }
}

public enum PricingInboxError: Error, Equatable, Sendable {
    case invalidApplicationSupportDirectory
    case insecureManagedDirectory(String)
    case couldNotMonitorInbox(Int32)
    case startInProgress
    case resolutionInProgress
    case candidateAlreadyApplied
    case noPendingCandidate
    case noActiveCatalog
    case candidateUnavailable
    case candidateNotRegularFile
    case candidateHasMultipleLinks
    case candidateTooLarge
    case candidateChanged
    case archiveConflict(String)
    case fileOperationFailed(String)
}

public actor PricingInbox {
    public static let candidateFilename = "tokenboard-pricing.candidate.json"
    public static let temporaryCandidateFilename = "tokenboard-pricing.candidate.json.tmp"
    static let processingFilenamePrefix = ".candidate-processing-"
    static let processingFilenameSuffix = ".json"

    private let ledger: any LedgerStore
    private let applicationSupportDirectory: URL
    private let bundledCatalogData: Data
    private let fileSystem: any PricingInboxFileSystem
    private var directorySource: DispatchSourceFileSystemObject?
    private var state: CandidateState = .idle
    private var activeCatalog: ValidatedPricingCatalog?
    private var activeSnapshot: PricingSnapshot?
    private var started = false
    private var isStarting = false
    private var isDetecting = false
    private var detectionRequested = false
    private var resolution: CandidateResolution?

    public init(
        ledger: any LedgerStore,
        applicationSupportDirectory: URL,
        bundledCatalogData: Data
    ) {
        self.ledger = ledger
        self.applicationSupportDirectory = applicationSupportDirectory.standardizedFileURL
        self.bundledCatalogData = bundledCatalogData
        fileSystem = POSIXPricingInboxFileSystem()
    }

    init(
        ledger: any LedgerStore,
        applicationSupportDirectory: URL,
        bundledCatalogData: Data,
        fileSystem: any PricingInboxFileSystem
    ) {
        self.ledger = ledger
        self.applicationSupportDirectory = applicationSupportDirectory.standardizedFileURL
        self.bundledCatalogData = bundledCatalogData
        self.fileSystem = fileSystem
    }

    deinit {
        directorySource?.cancel()
        fileSystem.close()
    }

    public static func applicationSupport(
        ledger: any LedgerStore,
        bundledCatalogData: Data
    ) throws -> PricingInbox {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: support,
            bundledCatalogData: bundledCatalogData
        )
    }

    public func start() async throws {
        guard !started else { return }
        guard !isStarting else { throw PricingInboxError.startInProgress }
        isStarting = true
        defer { isStarting = false }

        do {
            guard applicationSupportDirectory.isFileURL,
                  applicationSupportDirectory.path.hasPrefix("/") else {
                throw PricingInboxError.invalidApplicationSupportDirectory
            }
            try fileSystem.open(rootPath: applicationSupportDirectory.path)
            let latestData = try await ledger.latestAppliedPricingCatalogJSON()
            let active = try validate(latestData ?? bundledCatalogData)
            activeCatalog = active
            activeSnapshot = snapshot(from: active)
            try fileSystem.replaceCanonical(
                active.canonicalJSON,
                in: .pricing,
                name: Self.currentCatalogFilename
            )
            try reconcileProcessingResidue(latestAppliedData: latestData)

            let descriptor = try fileSystem.duplicateInboxDescriptor()
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename],
                queue: DispatchQueue(label: "com.tokenboard.pricing-inbox")
            )
            source.setCancelHandler { Darwin.close(descriptor) }
            source.setEventHandler { [weak self] in
                Task { await self?.requestCandidateDetection() }
            }
            directorySource = source
            started = true
            source.resume()
            await requestCandidateDetection()
        } catch {
            directorySource?.cancel()
            directorySource = nil
            fileSystem.close()
            activeCatalog = nil
            activeSnapshot = nil
            state = .idle
            resolution = nil
            throw error
        }
    }

    public func stop() throws {
        switch state {
        case .resolving, .rejectedFinalizing:
            throw PricingInboxError.resolutionInProgress
        case .committed:
            throw PricingInboxError.candidateAlreadyApplied
        case .idle, .pending, .invalid:
            break
        }
        guard started || isStarting else { return }
        directorySource?.cancel()
        directorySource = nil
        fileSystem.close()
        started = false
        activeCatalog = nil
        activeSnapshot = nil
        state = .idle
        resolution = nil
    }

    public func pendingCandidate() -> PendingPricingCandidate? {
        guard case let .pending(record) = state else { return nil }
        return record.preview
    }

    public func status() -> PricingInboxStatus {
        switch state {
        case .idle:
            .empty
        case let .invalid(reason):
            .invalid(reason)
        case let .pending(record):
            .valid(record.preview)
        case let .resolving(record):
            resolution == .rejecting
                ? .rejecting(record.preview.identity)
                : .applying(record.preview.identity)
        case let .rejectedFinalizing(record):
            .rejectedFinalizing(record.identity)
        case let .committed(record):
            .appliedFinalizing(record.preview.identity)
        }
    }

    public func exportCurrentSnapshot() throws {
        guard started, let activeCatalog else {
            throw PricingInboxError.noActiveCatalog
        }
        try fileSystem.replaceCanonical(
            activeCatalog.canonicalJSON,
            in: .pricing,
            name: Self.currentCatalogFilename
        )
    }

    public func applyPending() async throws {
        switch state {
        case .resolving, .rejectedFinalizing:
            throw PricingInboxError.resolutionInProgress
        case let .committed(committed):
            try finalizeCommitted(committed)
            return
        case .idle, .invalid:
            throw PricingInboxError.noPendingCandidate
        case let .pending(pending):
            try await apply(pending)
        }
    }

    public func applyPending(
        matching identity: PricingCandidateIdentity
    ) async throws -> PricingApplyOutcome {
        switch state {
        case .resolving, .rejectedFinalizing:
            throw PricingInboxError.resolutionInProgress
        case let .committed(committed):
            guard committed.preview.identity == identity else {
                throw PricingInboxError.candidateChanged
            }
            do {
                try finalizeCommitted(committed)
                return .finalized
            } catch {
                return .committedFinalizationPending
            }
        case .idle, .invalid:
            throw PricingInboxError.noPendingCandidate
        case let .pending(pending):
            guard pending.preview.identity == identity else {
                throw PricingInboxError.candidateChanged
            }
            do {
                try await apply(pending)
                return .finalized
            } catch {
                if case let .committed(committed) = state,
                   committed.preview.identity == identity {
                    return .committedFinalizationPending
                }
                throw error
            }
        }
    }

    public func rejectPending() async throws {
        let pending: PendingRecord
        switch state {
        case .resolving:
            throw PricingInboxError.resolutionInProgress
        case let .rejectedFinalizing(rejected):
            try finalizeRejected(rejected)
            return
        case .committed:
            throw PricingInboxError.candidateAlreadyApplied
        case .idle, .invalid:
            throw PricingInboxError.noPendingCandidate
        case let .pending(record):
            pending = record
        }

        resolution = .rejecting
        state = .resolving(pending)
        do {
            let isolated = try isolateAndVerify(pending)
            state = .resolving(isolated)
            try installArchive(
                isolated.preview.canonicalJSON,
                catalogID: isolated.preview.catalog.catalogID,
                directory: .rejected
            )
            let rejected = RejectedRecord(
                identity: isolated.preview.identity,
                processingName: isolated.location.processingName
            )
            do {
                try fileSystem.removeInbox(name: rejected.processingName)
            } catch {
                if Self.completedRemoval(error, name: rejected.processingName) {
                    state = .rejectedFinalizing(rejected)
                }
                throw error
            }
            state = .idle
            resolution = nil
            requestDetectionAfterResolution()
        } catch {
            if case .rejectedFinalizing = state { throw error }
            restorePreCommitCandidate(pendingRecordFromState(fallback: pending))
            throw error
        }
    }

    public func rejectPending(
        matching identity: PricingCandidateIdentity
    ) async throws -> PricingRejectOutcome {
        switch state {
        case let .pending(record) where record.preview.identity != identity:
            throw PricingInboxError.candidateChanged
        case let .rejectedFinalizing(record) where record.identity != identity:
            throw PricingInboxError.candidateChanged
        case let .committed(record) where record.preview.identity != identity:
            throw PricingInboxError.candidateChanged
        default:
            break
        }
        do {
            try await rejectPending()
            return .finalized
        } catch {
            if case let .rejectedFinalizing(record) = state,
               record.identity == identity {
                return .rejectedFinalizationPending
            }
            throw error
        }
    }

    private func finalizeRejected(_ rejected: RejectedRecord) throws {
        guard case .rejectedFinalizing = state else {
            throw PricingInboxError.noPendingCandidate
        }
        try fileSystem.removeInbox(name: rejected.processingName)
        state = .idle
        resolution = nil
        requestDetectionAfterResolution()
    }

    private func apply(_ pending: PendingRecord) async throws {
        resolution = .applying
        state = .resolving(pending)
        let isolated: PendingRecord
        do {
            isolated = try isolateAndVerify(pending)
            state = .resolving(isolated)
        } catch {
            restorePreCommitCandidate(pendingRecordFromState(fallback: pending))
            throw error
        }

        do {
            try await ledger.applyPricingCatalog(
                isolated.preview.catalog,
                canonicalJSON: isolated.preview.canonicalJSON,
                origin: PricingImportMetadata.agentCandidateOrigin,
                validationSummary: PricingImportMetadata.schemaV1ValidSummary
            )
        } catch {
            restorePreCommitCandidate(isolated)
            throw error
        }

        let committed = CommittedRecord(
            preview: isolated.preview,
            processingName: isolated.location.processingName
        )
        activeCatalog = isolated.preview.catalog
        activeSnapshot = snapshot(from: isolated.preview.catalog)
        state = .committed(committed)
        try finalizeCommitted(committed)
    }

    private func finalizeCommitted(_ committed: CommittedRecord) throws {
        guard case .committed = state else {
            throw PricingInboxError.noPendingCandidate
        }
        try fileSystem.replaceCanonical(
            committed.preview.canonicalJSON,
            in: .pricing,
            name: Self.currentCatalogFilename
        )
        try installArchive(
            committed.preview.canonicalJSON,
            catalogID: committed.preview.catalog.catalogID,
            directory: .applied
        )
        try fileSystem.removeInbox(name: committed.processingName)
        state = .idle
        resolution = nil
        requestDetectionAfterResolution()
    }

    private func isolateAndVerify(_ record: PendingRecord) throws -> PendingRecord {
        var isolated = record
        switch record.location {
        case .candidate:
            let processing = Self.processingFilename()
            do {
                try fileSystem.moveInbox(from: Self.candidateFilename, to: processing, exclusive: true)
            } catch {
                if Self.completedMove(
                    error,
                    from: Self.candidateFilename,
                    to: processing
                ) {
                    isolated.location = .processing(processing)
                    state = .resolving(isolated)
                }
                throw error
            }
            isolated.location = .processing(processing)
            state = .resolving(isolated)
        case .processing:
            break
        }
        guard let opened = try fileSystem.readIfPresent(
            in: .inbox,
            name: isolated.location.processingName
        ) else {
            throw PricingInboxError.candidateUnavailable
        }
        guard opened.identity == isolated.identity else {
            throw PricingInboxError.candidateChanged
        }
        let catalog = try validate(opened.data)
        guard catalog.canonicalJSON == isolated.preview.canonicalJSON else {
            throw PricingInboxError.candidateChanged
        }
        return isolated
    }

    private func restorePreCommitCandidate(_ record: PendingRecord) {
        var restored = record
        if case let .processing(name) = record.location {
            do {
                try fileSystem.moveInbox(from: name, to: Self.candidateFilename, exclusive: true)
                restored.location = .candidate
            } catch {
                restored.location = Self.completedMove(
                    error,
                    from: name,
                    to: Self.candidateFilename
                ) ? .candidate : .processing(name)
            }
        }
        do {
            let name = restored.location.filename
            guard let opened = try fileSystem.readIfPresent(in: .inbox, name: name),
                  opened.identity == restored.identity,
                  try validate(opened.data).canonicalJSON == restored.preview.canonicalJSON else {
                state = .idle
                requestDetectionAfterResolution()
                return
            }
            state = .pending(restored)
            resolution = nil
            requestDetectionAfterResolution()
        } catch {
            state = .idle
            resolution = nil
            requestDetectionAfterResolution()
        }
    }

    private func pendingRecordFromState(fallback: PendingRecord) -> PendingRecord {
        guard case let .resolving(record) = state else { return fallback }
        return record
    }

    private func requestDetectionAfterResolution() {
        detectionRequested = true
        Task { await self.requestCandidateDetection() }
    }

    private func requestCandidateDetection() async {
        detectionRequested = true
        guard !isDetecting, state.allowsDetection else { return }
        isDetecting = true
        repeat {
            detectionRequested = false
            detectCandidate()
        } while detectionRequested && state.allowsDetection
        isDetecting = false
    }

    private func detectCandidate() {
        guard let activeSnapshot else {
            state = .idle
            resolution = nil
            return
        }
        do {
            guard let opened = try fileSystem.readIfPresent(in: .inbox, name: Self.candidateFilename) else {
                state = .idle
                resolution = nil
                return
            }
            let catalog = try validate(opened.data)
            let preview = PendingPricingCandidate(
                catalog: catalog,
                canonicalJSON: catalog.canonicalJSON,
                diff: CatalogDiff.compare(candidate: catalog, against: activeSnapshot),
                sourceURL: candidateURL
            )
            state = .pending(PendingRecord(
                preview: preview,
                identity: opened.identity,
                location: .candidate
            ))
            resolution = nil
        } catch {
            state = .invalid(Self.invalidReason(for: error))
            resolution = nil
        }
    }

    private func reconcileProcessingResidue(latestAppliedData: Data?) throws {
        let latestApplied = try latestAppliedData.map(validate)
        var restoredUncommitted = false
        for name in try fileSystem.listInbox() where Self.isProcessingFilename(name) {
            guard let opened = try? fileSystem.readIfPresent(in: .inbox, name: name),
                  let catalog = try? validate(opened.data) else {
                continue
            }
            if let latestApplied,
               catalog.canonicalJSON == latestApplied.canonicalJSON {
                try installArchive(
                    latestApplied.canonicalJSON,
                    catalogID: latestApplied.catalogID,
                    directory: .applied
                )
                try fileSystem.removeInbox(name: name)
            } else if !restoredUncommitted {
                do {
                    try fileSystem.moveInbox(from: name, to: Self.candidateFilename, exclusive: true)
                    restoredUncommitted = true
                } catch {
                    if Self.completedMove(error, from: name, to: Self.candidateFilename) {
                        restoredUncommitted = true
                    } else {
                        continue
                    }
                }
            }
        }
    }

    private func installArchive(
        _ canonicalJSON: Data,
        catalogID: String,
        directory: PricingInboxDirectory
    ) throws {
        let name = "\(catalogID).json"
        if try fileSystem.installCanonicalIfAbsent(canonicalJSON, in: directory, name: name) {
            return
        }
        guard let existing = try fileSystem.readIfPresent(in: directory, name: name) else {
            throw PricingInboxError.archiveConflict(name)
        }
        let existingCatalog = try validate(existing.data)
        guard existingCatalog.canonicalJSON == canonicalJSON else {
            throw PricingInboxError.archiveConflict(name)
        }
    }

    private func snapshot(from catalog: ValidatedPricingCatalog) -> PricingSnapshot {
        var rates: [StoredPriceRate] = []
        var aliases: [StoredModelAlias] = []
        for model in catalog.models {
            aliases.append(contentsOf: model.aliases.map {
                StoredModelAlias(
                    provider: model.provider,
                    observedModelID: $0.observedModelID,
                    canonicalModelID: model.canonicalModelID,
                    effectiveFrom: $0.effectiveFrom,
                    effectiveTo: $0.effectiveTo
                )
            })
            for rate in model.rates {
                rates.append(contentsOf: rate.prices.map { metric, price in
                    StoredPriceRate(
                        provider: model.provider,
                        canonicalModelID: model.canonicalModelID,
                        metric: metric,
                        usdPerMillion: price,
                        effectiveFrom: rate.effectiveFrom,
                        effectiveTo: rate.effectiveTo,
                        provenanceURL: rate.provenanceURL,
                        verifiedAt: rate.verifiedAt
                    )
                })
            }
        }
        return PricingSnapshot(catalogIDs: [catalog.catalogID], rates: rates, aliases: aliases)
    }

    private func validate(_ data: Data) throws -> ValidatedPricingCatalog {
        try PricingCatalogValidator().validate(PricingCatalogLoader().load(data))
    }

    private static func processingFilename() -> String {
        "\(processingFilenamePrefix)\(UUID().uuidString)\(processingFilenameSuffix)"
    }

    private static func completedMove(_ error: Error, from: String, to: String) -> Bool {
        guard let mutationError = error as? PricingInboxMutationError else { return false }
        return mutationError.mutationCompleted
            && mutationError.mutation == .moveInbox(from: from, to: to)
    }

    private static func completedRemoval(_ error: Error, name: String) -> Bool {
        guard let mutationError = error as? PricingInboxMutationError else { return false }
        return mutationError.mutationCompleted
            && mutationError.mutation == .removeInbox(name: name)
    }

    private static func isProcessingFilename(_ name: String) -> Bool {
        name.hasPrefix(processingFilenamePrefix)
            && name.hasSuffix(processingFilenameSuffix)
            && name.count > processingFilenamePrefix.count + processingFilenameSuffix.count
    }

    private static func invalidReason(for error: Error) -> PricingInboxInvalidReason {
        switch error as? PricingInboxError {
        case .candidateNotRegularFile, .candidateHasMultipleLinks:
            .unsafeFile
        case .candidateTooLarge:
            .candidateTooLarge
        case .candidateUnavailable:
            .unreadableCandidate
        default:
            .invalidCatalog
        }
    }

    public static let currentCatalogFilename = "current-tokenboard-pricing.json"

    private var candidateURL: URL {
        applicationSupportDirectory
            .appending(path: "Pricing/Inbox", directoryHint: .isDirectory)
            .appending(path: Self.candidateFilename)
    }
}

private enum CandidateState: Sendable {
    case idle
    case invalid(PricingInboxInvalidReason)
    case pending(PendingRecord)
    case resolving(PendingRecord)
    case rejectedFinalizing(RejectedRecord)
    case committed(CommittedRecord)

    var allowsDetection: Bool {
        switch self {
        case .idle, .invalid:
            true
        case let .pending(record):
            record.location.isCandidate
        case .resolving, .rejectedFinalizing, .committed:
            false
        }
    }
}

private struct PendingRecord: Sendable {
    let preview: PendingPricingCandidate
    let identity: PricingInboxFileIdentity
    var location: CandidateLocation
}

private struct CommittedRecord: Sendable {
    let preview: PendingPricingCandidate
    let processingName: String
}

private struct RejectedRecord: Sendable {
    let identity: PricingCandidateIdentity
    let processingName: String
}

private enum CandidateResolution: Sendable {
    case applying
    case rejecting
}

private enum CandidateLocation: Sendable {
    case candidate
    case processing(String)

    var filename: String {
        switch self {
        case .candidate: PricingInbox.candidateFilename
        case let .processing(name): name
        }
    }

    var processingName: String {
        switch self {
        case .candidate: PricingInbox.candidateFilename
        case let .processing(name): name
        }
    }

    var isCandidate: Bool {
        if case .candidate = self { return true }
        return false
    }

}
