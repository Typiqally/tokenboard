import Foundation

public actor IncrementalScanner {
    private static let maximumBatchLines = 500

    private let ledger: any LedgerStore
    private let reader: JSONLReader
    private let sourceProbe: SourceProbe

    public init(
        ledger: any LedgerStore,
        reader: JSONLReader = JSONLReader(),
        sourceProbe: SourceProbe = SourceProbe()
    ) {
        self.ledger = ledger
        self.reader = reader
        self.sourceProbe = sourceProbe
    }

    public func scan(file: URL, provider: Provider, calendar: Calendar) async throws -> ScanOutcome {
        let stableSourceID: String
        do {
            stableSourceID = try sourceProbe.stableID(at: file, provider: provider)
        } catch SourceProbeError.missingStableIdentity {
            return attention(.missingStableIdentity, offset: 0)
        }

        let fingerprint = try await ledger.sourceFingerprint(provider: provider, stableID: stableSourceID)
        let storedCheckpoint = try await ledger.checkpoint(for: fingerprint)
        let metadata = try fileMetadata(at: file)
        var checkpoint = storedCheckpoint
            ?? emptyCheckpoint(fingerprint: fingerprint, provider: provider, metadata: metadata)

        guard metadata.size >= checkpoint.byteOffset else {
            return attention(.truncated, offset: checkpoint.byteOffset)
        }
        if checkpoint.byteOffset > 0 {
            guard let previousLine = try reader.lineEnding(at: checkpoint.byteOffset, in: file),
                  let expectedHash = checkpoint.lastCommittedLineHash else {
                return attention(.replaced, offset: checkpoint.byteOffset)
            }
            let observedHash = try await hash(previousLine)
            guard observedHash == expectedHash else {
                return attention(.replaced, offset: checkpoint.byteOffset)
            }
        }

        var adapter = ScannerAdapter(
            provider: provider,
            stableSourceID: stableSourceID,
            currentModel: checkpoint.adapterState["current_model"]
        )
        var usageCount = 0
        var skippedCount = 0
        var reachedEndOfFile = false

        while !reachedEndOfFile {
            let result = try reader.batch(
                from: file,
                startingAt: checkpoint.byteOffset,
                maxLines: Self.maximumBatchLines
            )
            reachedEndOfFile = result.reachedEndOfFile
            guard !result.lines.isEmpty else { break }

            var usageBatch: [NormalizedUsage] = []
            var skippedBatch: [SkippedRecord] = []
            usageBatch.reserveCapacity(result.lines.count)
            skippedBatch.reserveCapacity(result.lines.count)

            for line in result.lines {
                let lineHash = try await hash(line.data)
                let adapterResult: AdapterResult = line.data.isEmpty
                    ? .ignored
                    : adapter.consume(line: line.data)
                switch adapterResult {
                case let .usage(parsed):
                    if !parsed.cumulativeMetrics.isEmpty {
                        checkpoint.cumulativeMetrics = parsed.cumulativeMetrics
                    }
                    let usageIdentityHash: String?
                    if let stableUsageID = parsed.usage.stableUsageID {
                        usageIdentityHash = try await ledger.recordIdentityHash(stableUsageID)
                    } else {
                        usageIdentityHash = nil
                    }
                    if usageIdentityHash == nil || usageIdentityHash != checkpoint.lastUsageIdentityHash {
                        usageBatch.append(try await storageSafeUsage(
                            parsed.usage,
                            sourceFingerprint: fingerprint,
                            usageIdentityHash: usageIdentityHash
                        ))
                    }
                    if let usageIdentityHash {
                        checkpoint.lastUsageIdentityHash = usageIdentityHash
                    }
                case let .skipped(diagnostic):
                    skippedBatch.append(SkippedRecord(
                        sourceFingerprint: fingerprint,
                        byteOffset: line.startOffset,
                        recordHash: lineHash,
                        parserVersion: adapter.parserVersion,
                        reason: diagnostic.kind.rawValue
                    ))
                case .ignored:
                    break
                }

                checkpoint.byteOffset = line.endOffset
                checkpoint.lastCommittedLineHash = lineHash
            }

            checkpoint.parserVersion = adapter.parserVersion
            checkpoint.fileSize = metadata.size
            checkpoint.modificationTime = metadata.modificationTime
            checkpoint.adapterState = try await storageSafeAdapterState(adapter.checkpointState)
            try await ledger.commit(usageBatch, skipped: skippedBatch, checkpoint: checkpoint, calendar: calendar)
            usageCount += usageBatch.count
            skippedCount += skippedBatch.count
        }

        return ScanOutcome(
            committedUsageRecords: usageCount,
            skippedRecords: skippedCount,
            finalOffset: checkpoint.byteOffset,
            attention: nil
        )
    }

    private func emptyCheckpoint(
        fingerprint: String,
        provider: Provider,
        metadata: FileMetadata
    ) -> SourceCheckpoint {
        SourceCheckpoint(
            fingerprint: fingerprint,
            provider: provider,
            parserVersion: ScannerAdapter.parserVersion(for: provider),
            byteOffset: 0,
            fileSize: metadata.size,
            modificationTime: metadata.modificationTime,
            lastUsageIdentityHash: nil,
            cumulativeMetrics: [:]
        )
    }

    private func attention(_ reason: ScanOutcome.Attention, offset: Int64) -> ScanOutcome {
        ScanOutcome(
            committedUsageRecords: 0,
            skippedRecords: 0,
            finalOffset: offset,
            attention: reason
        )
    }

    private func hash(_ data: Data) async throws -> String {
        try await ledger.recordIdentityHash(data.base64EncodedString())
    }

    private func storageSafeUsage(
        _ usage: NormalizedUsage,
        sourceFingerprint: String,
        usageIdentityHash: String?
    ) async throws -> NormalizedUsage {
        let modelID = try await storageSafeModelID(usage.observedModelID)
        return try NormalizedUsage(
            provider: usage.provider,
            observedModelID: modelID,
            timestamp: usage.timestamp,
            metrics: usage.metrics,
            stableSourceID: sourceFingerprint,
            stableUsageID: usageIdentityHash
        )
    }

    private func storageSafeAdapterState(_ state: [String: String]) async throws -> [String: String] {
        guard let currentModel = state["current_model"] else { return [:] }
        return ["current_model": try await storageSafeModelID(currentModel)]
    }

    private func storageSafeModelID(_ rawModelID: String) async throws -> String {
        guard !Self.isContentSafeModelID(rawModelID) else { return rawModelID }
        return "unknown-\(try await ledger.recordIdentityHash(rawModelID))"
    }

    private static func isContentSafeModelID(_ value: String) -> Bool {
        if value == "<synthetic>" { return true }
        guard (1...256).contains(value.utf8.count), let first = value.utf8.first else {
            return false
        }
        return isASCIIAlphaNumeric(first) && value.utf8.allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private func fileMetadata(at file: URL) throws -> FileMetadata {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return FileMetadata(
            size: size.int64Value,
            modificationTime: attributes[.modificationDate] as? Date
        )
    }
}

private struct FileMetadata {
    let size: Int64
    let modificationTime: Date?
}

private enum ScannerAdapter {
    case claude(ClaudeCodeAdapter)
    case codex(CodexAdapter)

    init(provider: Provider, stableSourceID: String, currentModel: String?) {
        switch provider {
        case .claudeCode:
            self = .claude(ClaudeCodeAdapter())
        case .codex:
            self = .codex(CodexAdapter(stableSourceID: stableSourceID, currentModel: currentModel))
        }
    }

    var parserVersion: Int {
        switch self {
        case .claude: ClaudeCodeAdapter.parserVersion
        case .codex: CodexAdapter.parserVersion
        }
    }

    var checkpointState: [String: String] {
        switch self {
        case let .claude(adapter): adapter.checkpointState
        case let .codex(adapter): adapter.checkpointState
        }
    }

    mutating func consume(line: Data) -> AdapterResult {
        switch self {
        case var .claude(adapter):
            let result = adapter.consume(line: line)
            self = .claude(adapter)
            return result
        case var .codex(adapter):
            let result = adapter.consume(line: line)
            self = .codex(adapter)
            return result
        }
    }

    static func parserVersion(for provider: Provider) -> Int {
        switch provider {
        case .claudeCode: ClaudeCodeAdapter.parserVersion
        case .codex: CodexAdapter.parserVersion
        }
    }
}
