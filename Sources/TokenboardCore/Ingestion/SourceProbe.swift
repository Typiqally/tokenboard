import Foundation

public enum SourceProbeError: Error, Equatable, Sendable {
    case missingStableIdentity
}

public struct SourceProbe: Sendable {
    private static let maximumBytes = 8 * 1024 * 1024
    private static let chunkSize = 64 * 1024

    public init() {}

    public func stableID(at file: URL, provider: Provider) throws -> String {
        try stableID(in: RetainedSourceFile(url: file), provider: provider)
    }

    func stableID(in source: RetainedSourceFile, provider: Provider) throws -> String {
        var bytesRead = 0
        var partialLine = Data()
        let capturedLimit = min(source.size, Int64(Self.maximumBytes))
        while Int64(bytesRead) < capturedLimit {
            let requested = min(
                Self.chunkSize,
                Int(capturedLimit - Int64(bytesRead))
            )
            let chunk = try source.read(at: Int64(bytesRead), count: requested)
            if chunk.isEmpty { break }
            bytesRead += chunk.count

            var segmentStart = chunk.startIndex
            var index = chunk.startIndex
            while index < chunk.endIndex {
                if chunk[index] == 0x0A {
                    partialLine.append(contentsOf: chunk[segmentStart..<index])
                    if let stableID = stableID(in: partialLine, provider: provider) {
                        return stableID
                    }
                    partialLine.removeAll(keepingCapacity: true)
                    segmentStart = chunk.index(after: index)
                }
                index = chunk.index(after: index)
            }
            partialLine.append(contentsOf: chunk[segmentStart..<chunk.endIndex])
        }

        throw SourceProbeError.missingStableIdentity
    }

    private func stableID(in line: Data, provider: Provider) -> String? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }

        let candidate: String?
        switch provider {
        case .claudeCode:
            candidate = object["sessionId"] as? String ?? object["session_id"] as? String
        case .codex:
            guard object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any] else {
                return nil
            }
            candidate = payload["id"] as? String ?? payload["session_id"] as? String
        }
        guard let candidate, !candidate.isEmpty else { return nil }
        return candidate
    }
}
