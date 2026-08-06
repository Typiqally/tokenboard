import Foundation

public enum TimestampParser {
    public static func parse(_ value: String) -> Date? {
        if let timestamp = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
            return timestamp
        }
        return try? Date.ISO8601FormatStyle().parse(value)
    }
}
