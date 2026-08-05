import CryptoKit
import Foundation

public struct PrivacyHasher: Sendable {
    private let salt: Data

    public init(salt: Data) {
        self.salt = salt
    }

    public func fingerprint(provider: Provider, stableID: String) -> String {
        var data = salt
        data.append(contentsOf: provider.rawValue.utf8)
        data.append(0)
        data.append(contentsOf: stableID.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func recordHash(_ value: String) -> String {
        var data = salt
        data.append(contentsOf: value.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
