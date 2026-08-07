import Foundation

public enum ModelIdentifierPolicy: Sendable {
    public static func isContentSafe(_ value: String) -> Bool {
        if value == "<synthetic>" { return true }
        guard (1...256).contains(value.utf8.count), let first = value.utf8.first else {
            return false
        }
        return isASCIIAlphaNumeric(first) && value.utf8.allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
    }

    public static func isOpaqueUnknown(_ value: String) -> Bool {
        let prefix = "unknown-"
        guard value.hasPrefix(prefix), value.utf8.count == prefix.utf8.count + 64 else {
            return false
        }
        return value.utf8.dropFirst(prefix.utf8.count).allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}
