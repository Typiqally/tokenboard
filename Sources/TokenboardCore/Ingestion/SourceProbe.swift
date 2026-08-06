import Foundation

public enum SourceProbeError: Error, Equatable, Sendable {
    case missingStableIdentity
}

public struct SourceProbe: Sendable {
    private static let maximumBytes = 8 * 1024 * 1024
    private static let chunkSize = 64 * 1024

    public init() {}

    public func stableID(at file: URL, provider: Provider) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var bytesRead = 0
        var partialLine = Data()
        while bytesRead < Self.maximumBytes {
            let requested = min(Self.chunkSize, Self.maximumBytes - bytesRead)
            let chunk = try handle.read(upToCount: requested) ?? Data()
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
