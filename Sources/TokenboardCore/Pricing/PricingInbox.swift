import Darwin
import Dispatch
import Foundation

public struct PendingPricingCandidate: Equatable, Sendable {
    public let catalog: ValidatedPricingCatalog
    public let canonicalJSON: Data
    public let diff: CatalogDiff
    public let sourceURL: URL

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
    }
}

public enum PricingInboxError: Error, Equatable, Sendable {
    case invalidApplicationSupportDirectory
    case insecureManagedDirectory(String)
    case couldNotMonitorInbox(Int32)
    case startInProgress
    case noPendingCandidate
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

    private let ledger: any LedgerStore
    private let applicationSupportDirectory: URL
    private let bundledCatalogData: Data
    private var directorySource: DispatchSourceFileSystemObject?
    private var pendingRecord: PendingRecord?
    private var started = false
    private var isStarting = false
    private var isDetecting = false
    private var detectionRequested = false
    private var isResolvingPending = false

    public init(
        ledger: any LedgerStore,
        applicationSupportDirectory: URL,
        bundledCatalogData: Data
    ) {
        self.ledger = ledger
        self.applicationSupportDirectory = applicationSupportDirectory.standardizedFileURL
        self.bundledCatalogData = bundledCatalogData
    }

    deinit {
        directorySource?.cancel()
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
        try createManagedDirectories()

        let activeData = try await ledger.latestAppliedPricingCatalogJSON() ?? bundledCatalogData
        let activeCatalog = try validate(activeData)
        try writeAtomically(activeCatalog.canonicalJSON, to: currentCatalogURL)

        let descriptor = open(inboxURL.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw PricingInboxError.couldNotMonitorInbox(errno)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename],
            queue: DispatchQueue(label: "com.tokenboard.pricing-inbox")
        )
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in
            Task { await self?.requestCandidateDetection() }
        }
        directorySource = source
        started = true
        source.resume()
        await requestCandidateDetection()
    }

    public func pendingCandidate() -> PendingPricingCandidate? {
        pendingRecord?.preview
    }

    public func applyPending() async throws {
        guard var record = pendingRecord else {
            throw PricingInboxError.noPendingCandidate
        }
        isResolvingPending = true
        defer {
            isResolvingPending = false
            if detectionRequested {
                Task { await self.requestCandidateDetection() }
            }
        }

        let processingURL = try moveToProcessing(record: record)
        record.processingURL = processingURL
        pendingRecord = record
        do {
            try verify(record: record, at: processingURL)
            try await ledger.applyPricingCatalog(
                record.preview.catalog,
                canonicalJSON: record.preview.canonicalJSON,
                origin: PricingImportMetadata.agentCandidateOrigin,
                validationSummary: PricingImportMetadata.schemaV1ValidSummary
            )
            try writeAtomically(record.preview.canonicalJSON, to: currentCatalogURL)
            try archive(
                processingURL,
                as: appliedURL.appending(path: "\(record.preview.catalog.catalogID).json"),
                canonicalJSON: record.preview.canonicalJSON
            )
            pendingRecord = nil
        } catch {
            if restoreProcessingFile(processingURL) {
                record.processingURL = nil
                pendingRecord = record
            }
            if error as? PricingInboxError == .candidateChanged {
                pendingRecord = nil
            }
            throw error
        }
    }

    public func rejectPending() async throws {
        guard var record = pendingRecord else {
            throw PricingInboxError.noPendingCandidate
        }
        isResolvingPending = true
        defer {
            isResolvingPending = false
            if detectionRequested {
                Task { await self.requestCandidateDetection() }
            }
        }

        let processingURL = try moveToProcessing(record: record)
        record.processingURL = processingURL
        pendingRecord = record
        do {
            try verify(record: record, at: processingURL)
            try archive(
                processingURL,
                as: rejectedURL.appending(path: "\(record.preview.catalog.catalogID).json"),
                canonicalJSON: record.preview.canonicalJSON
            )
            pendingRecord = nil
        } catch {
            if restoreProcessingFile(processingURL) {
                record.processingURL = nil
                pendingRecord = record
            }
            if error as? PricingInboxError == .candidateChanged {
                pendingRecord = nil
            }
            throw error
        }
    }

    private func requestCandidateDetection() async {
        detectionRequested = true
        guard !isDetecting,
              !isResolvingPending,
              pendingRecord?.processingURL == nil else { return }
        isDetecting = true
        repeat {
            detectionRequested = false
            await detectCandidate()
        } while detectionRequested && !isResolvingPending
        isDetecting = false
    }

    private func detectCandidate() async {
        do {
            let opened = try readCandidate(at: candidateURL)
            let catalog = try validate(opened.data)
            let snapshot = try await ledger.pricingSnapshot()
            let preview = PendingPricingCandidate(
                catalog: catalog,
                canonicalJSON: catalog.canonicalJSON,
                diff: CatalogDiff.compare(candidate: catalog, against: snapshot),
                sourceURL: candidateURL
            )
            pendingRecord = PendingRecord(preview: preview, identity: opened.identity, processingURL: nil)
        } catch {
            pendingRecord = nil
        }
    }

    private func moveToProcessing(record: PendingRecord) throws -> URL {
        if let processingURL = record.processingURL {
            return processingURL
        }
        let processingURL = pricingURL.appending(path: ".candidate-processing-\(UUID().uuidString).tmp")
        guard rename(candidateURL.path, processingURL.path) == 0 else {
            throw PricingInboxError.candidateUnavailable
        }
        return processingURL
    }

    private func verify(record: PendingRecord, at url: URL) throws {
        let opened = try readCandidate(at: url)
        guard opened.identity == record.identity else {
            throw PricingInboxError.candidateChanged
        }
        let catalog = try validate(opened.data)
        guard catalog.canonicalJSON == record.preview.canonicalJSON else {
            throw PricingInboxError.candidateChanged
        }
    }

    private func archive(_ source: URL, as destination: URL, canonicalJSON: Data) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try readCandidate(at: destination)
            let catalog = try validate(existing.data)
            guard catalog.canonicalJSON == canonicalJSON else {
                throw PricingInboxError.archiveConflict(destination.lastPathComponent)
            }
            do {
                try FileManager.default.removeItem(at: source)
            } catch {
                throw PricingInboxError.fileOperationFailed("could not remove duplicate candidate")
            }
            return
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw PricingInboxError.fileOperationFailed("could not archive candidate")
        }
    }

    @discardableResult
    private func restoreProcessingFile(_ processingURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: processingURL.path),
              !FileManager.default.fileExists(atPath: candidateURL.path) else { return false }
        do {
            try FileManager.default.moveItem(at: processingURL, to: candidateURL)
            return true
        } catch {
            return false
        }
    }

    private func validate(_ data: Data) throws -> ValidatedPricingCatalog {
        try PricingCatalogValidator().validate(PricingCatalogLoader().load(data))
    }

    private func readCandidate(at url: URL) throws -> OpenedCandidate {
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0 else {
            throw PricingInboxError.candidateUnavailable
        }
        guard pathStatus.st_mode & S_IFMT == S_IFREG else {
            throw PricingInboxError.candidateNotRegularFile
        }
        guard pathStatus.st_nlink == 1 else {
            throw PricingInboxError.candidateHasMultipleLinks
        }
        guard pathStatus.st_size >= 0, pathStatus.st_size <= 1_048_576 else {
            throw PricingInboxError.candidateTooLarge
        }

        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw PricingInboxError.candidateUnavailable
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw PricingInboxError.candidateUnavailable
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw PricingInboxError.candidateNotRegularFile
        }
        guard status.st_nlink == 1 else {
            throw PricingInboxError.candidateHasMultipleLinks
        }
        guard status.st_size >= 0, status.st_size <= 1_048_576 else {
            throw PricingInboxError.candidateTooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PricingInboxError.candidateUnavailable
            }
            guard data.count + count <= 1_048_576 else {
                throw PricingInboxError.candidateTooLarge
            }
            data.append(buffer, count: count)
        }
        return OpenedCandidate(
            data: data,
            identity: FileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
        )
    }

    private func createManagedDirectories() throws {
        guard applicationSupportDirectory.isFileURL,
              applicationSupportDirectory.path.hasPrefix("/") else {
            throw PricingInboxError.invalidApplicationSupportDirectory
        }
        try ensureDirectory(applicationSupportDirectory, create: true)
        try ensureDirectory(pricingURL, create: true)
        try ensureDirectory(inboxURL, create: true)
        try ensureDirectory(appliedURL, create: true)
        try ensureDirectory(rejectedURL, create: true)
    }

    private func ensureDirectory(_ url: URL, create: Bool) throws {
        if create, !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } catch {
                throw PricingInboxError.fileOperationFailed("could not create managed directory")
            }
        }
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            throw PricingInboxError.insecureManagedDirectory(url.lastPathComponent)
        }
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            guard rename(temporary.path, destination.path) == 0 else {
                throw PricingInboxError.fileOperationFailed("could not replace active catalog")
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let inboxError = error as? PricingInboxError { throw inboxError }
            throw PricingInboxError.fileOperationFailed("could not write active catalog")
        }
    }

    private var pricingURL: URL {
        applicationSupportDirectory.appending(path: "Pricing", directoryHint: .isDirectory)
    }
    private var inboxURL: URL {
        pricingURL.appending(path: "Inbox", directoryHint: .isDirectory)
    }
    private var appliedURL: URL {
        pricingURL.appending(path: "Applied", directoryHint: .isDirectory)
    }
    private var rejectedURL: URL {
        pricingURL.appending(path: "Rejected", directoryHint: .isDirectory)
    }
    private var currentCatalogURL: URL {
        pricingURL.appending(path: "current-tokenboard-pricing.json")
    }
    private var candidateURL: URL {
        inboxURL.appending(path: Self.candidateFilename)
    }
}

private struct PendingRecord: Sendable {
    let preview: PendingPricingCandidate
    let identity: FileIdentity
    var processingURL: URL?
}

private struct OpenedCandidate: Sendable {
    let data: Data
    let identity: FileIdentity
}

private struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}
