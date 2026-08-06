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

    public init(lines: [JSONLLine], committedOffset: Int64, reachedEndOfFile: Bool) {
        self.lines = lines
        self.committedOffset = committedOffset
        self.reachedEndOfFile = reachedEndOfFile
    }
}

public enum JSONLReaderError: Error, Equatable, Sendable {
    case invalidStartingOffset
    case invalidMaximumLineCount
    case startingOffsetBeyondEndOfFile
}

public struct JSONLReader: Sendable {
    private static let chunkSize = 64 * 1024

    public init() {}

    public func batch(from file: URL, startingAt: Int64, maxLines: Int) throws -> JSONLReadResult {
        guard startingAt >= 0 else { throw JSONLReaderError.invalidStartingOffset }
        guard maxLines >= 1 else { throw JSONLReaderError.invalidMaximumLineCount }

        let fileSize = try size(of: file)
        guard startingAt <= fileSize else { throw JSONLReaderError.startingOffsetBeyondEndOfFile }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(startingAt))

        var lines: [JSONLLine] = []
        lines.reserveCapacity(min(maxLines, 500))
        var lineData = Data()
        var lineStart = startingAt
        var scannedOffset = startingAt
        var reachedEndOfFile = startingAt == fileSize

        while lines.count < maxLines && !reachedEndOfFile {
            let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
            if chunk.isEmpty {
                reachedEndOfFile = true
                break
            }

            var segmentStart = chunk.startIndex
            var index = chunk.startIndex
            while index < chunk.endIndex {
                if chunk[index] == 0x0A {
                    lineData.append(contentsOf: chunk[segmentStart..<index])
                    let endOffset = scannedOffset + Int64(index - chunk.startIndex) + 1
                    lines.append(JSONLLine(data: lineData, startOffset: lineStart, endOffset: endOffset))
                    lineData.removeAll(keepingCapacity: true)
                    lineStart = endOffset
                    segmentStart = chunk.index(after: index)
                    if lines.count == maxLines {
                        break
                    }
                }
                index = chunk.index(after: index)
            }

            if lines.count < maxLines {
                lineData.append(contentsOf: chunk[segmentStart..<chunk.endIndex])
            }
            scannedOffset += Int64(chunk.count)
            reachedEndOfFile = scannedOffset >= fileSize
        }

        let committedOffset = lines.last?.endOffset ?? startingAt
        if lines.count == maxLines && committedOffset < fileSize {
            reachedEndOfFile = false
        }
        return JSONLReadResult(
            lines: lines,
            committedOffset: committedOffset,
            reachedEndOfFile: reachedEndOfFile
        )
    }

    func lineEnding(at endOffset: Int64, in file: URL) throws -> Data? {
        guard endOffset > 0 else { return nil }
        let fileSize = try size(of: file)
        guard endOffset <= fileSize else { return nil }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(endOffset - 1))
        guard try handle.read(upToCount: 1)?.first == 0x0A else { return nil }

        var cursor = endOffset - 1
        var lineStart = Int64(0)
        while cursor > 0 {
            let readStart = max(Int64(0), cursor - Int64(Self.chunkSize))
            let count = Int(cursor - readStart)
            try handle.seek(toOffset: UInt64(readStart))
            let chunk = try handle.read(upToCount: count) ?? Data()
            guard chunk.count == count else { return nil }

            if let newline = chunk.lastIndex(of: 0x0A) {
                lineStart = readStart + Int64(chunk.distance(from: chunk.startIndex, to: newline)) + 1
                break
            }
            cursor = readStart
        }

        let lineLength = Int(endOffset - 1 - lineStart)
        try handle.seek(toOffset: UInt64(lineStart))
        let line = try handle.read(upToCount: lineLength) ?? Data()
        return line.count == lineLength ? line : nil
    }

    private func size(of file: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return number.int64Value
    }
}
