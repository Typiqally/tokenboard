import Foundation

public struct JSONLLine: Equatable, Sendable {
    public let data: Data
    public let startOffset: Int64
    public let endOffset: Int64

    public init(data: Data, startOffset: Int64, endOffset: Int64) {
        self.data = data
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

public struct JSONLReadResult: Equatable, Sendable {
    public let lines: [JSONLLine]
    public let committedOffset: Int64
    public let reachedEndOfFile: Bool
    public let oversizedRecordOffset: Int64?

    public init(
        lines: [JSONLLine],
        committedOffset: Int64,
        reachedEndOfFile: Bool,
        oversizedRecordOffset: Int64? = nil
    ) {
        self.lines = lines
        self.committedOffset = committedOffset
        self.reachedEndOfFile = reachedEndOfFile
        self.oversizedRecordOffset = oversizedRecordOffset
    }
}

public enum JSONLReaderError: Error, Equatable, Sendable {
    case invalidStartingOffset
    case invalidMaximumLineCount
    case invalidMaximumRecordBytes
    case startingOffsetBeyondEndOfFile
}

public struct JSONLReader: Sendable {
    public static let defaultMaximumRecordBytes = 8 * 1_024 * 1_024
    private static let chunkSize = 64 * 1_024
    public let maximumRecordBytes: Int

    public init(maximumRecordBytes: Int = Self.defaultMaximumRecordBytes) {
        self.maximumRecordBytes = maximumRecordBytes
    }

    public func batch(from file: URL, startingAt: Int64, maxLines: Int) throws -> JSONLReadResult {
        try batch(from: RetainedSourceFile(url: file), startingAt: startingAt, maxLines: maxLines)
    }

    func batch(
        from source: RetainedSourceFile,
        startingAt: Int64,
        maxLines: Int
    ) throws -> JSONLReadResult {
        guard startingAt >= 0 else { throw JSONLReaderError.invalidStartingOffset }
        guard maxLines >= 1 else { throw JSONLReaderError.invalidMaximumLineCount }
        guard maximumRecordBytes >= 1 else { throw JSONLReaderError.invalidMaximumRecordBytes }
        guard startingAt <= source.size else {
            throw JSONLReaderError.startingOffsetBeyondEndOfFile
        }

        var lines: [JSONLLine] = []
        lines.reserveCapacity(min(maxLines, 500))
        var lineData = Data()
        var lineStart = startingAt
        var readOffset = startingAt
        var reachedCapturedEnd = startingAt == source.size

        while lines.count < maxLines, readOffset < source.size {
            let chunk = try source.read(
                at: readOffset,
                count: min(Self.chunkSize, Int(source.size - readOffset))
            )
            guard !chunk.isEmpty else { break }
            var segmentStart = chunk.startIndex
            while segmentStart < chunk.endIndex, lines.count < maxLines {
                let newline = chunk[segmentStart...].firstIndex(of: 0x0A)
                let segmentEnd = newline ?? chunk.endIndex
                let segmentCount = chunk.distance(from: segmentStart, to: segmentEnd)
                let (candidateRecordBytes, overflowed) = lineData.count
                    .addingReportingOverflow(segmentCount)
                guard !overflowed, candidateRecordBytes <= maximumRecordBytes else {
                    return JSONLReadResult(
                        lines: lines,
                        committedOffset: lines.last?.endOffset ?? startingAt,
                        reachedEndOfFile: false,
                        oversizedRecordOffset: lineStart
                    )
                }
                lineData.append(contentsOf: chunk[segmentStart..<segmentEnd])
                guard let newline else { break }

                let endOffset = readOffset
                    + Int64(chunk.distance(from: chunk.startIndex, to: newline)) + 1
                lines.append(JSONLLine(
                    data: lineData,
                    startOffset: lineStart,
                    endOffset: endOffset
                ))
                lineData.removeAll(keepingCapacity: true)
                lineStart = endOffset
                segmentStart = chunk.index(after: newline)
            }
            readOffset += Int64(chunk.count)
            reachedCapturedEnd = readOffset >= source.size
        }

        let committedOffset = lines.last?.endOffset ?? startingAt
        if lines.count == maxLines, committedOffset < source.size {
            reachedCapturedEnd = false
        }
        return JSONLReadResult(
            lines: lines,
            committedOffset: committedOffset,
            reachedEndOfFile: reachedCapturedEnd,
            oversizedRecordOffset: nil
        )
    }

    func lineEnding(at endOffset: Int64, in file: URL) throws -> Data? {
        try lineEnding(at: endOffset, in: RetainedSourceFile(url: file))
    }

    func lineEnding(at endOffset: Int64, in source: RetainedSourceFile) throws -> Data? {
        guard maximumRecordBytes >= 1, endOffset > 0, endOffset <= source.size else { return nil }
        guard try source.read(at: endOffset - 1, count: 1).first == 0x0A else { return nil }

        let contentEnd = endOffset - 1
        let searchStart = max(Int64(0), contentEnd - Int64(maximumRecordBytes) - 1)
        let search = try source.read(at: searchStart, count: Int(contentEnd - searchStart))
        let lineStart: Int64
        if let newline = search.lastIndex(of: 0x0A) {
            lineStart = searchStart
                + Int64(search.distance(from: search.startIndex, to: newline)) + 1
        } else {
            guard searchStart == 0 else { return nil }
            lineStart = 0
        }
        let lineLength = contentEnd - lineStart
        guard lineLength <= Int64(maximumRecordBytes) else { return nil }
        return try source.read(at: lineStart, count: Int(lineLength))
    }
}
