import Foundation

public enum BuildInfo {
    public static let bundleIdentifier = "com.tokenboard.Tokenboard"
    public static let minimumMacOS = "14.0"

    public static var currentVersionDescription: String {
        versionDescription(
            shortVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            buildNumber: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String
        )
    }

    public static func versionDescription(
        shortVersion: String?,
        buildNumber: String?
    ) -> String {
        switch (nonEmpty(shortVersion), nonEmpty(buildNumber)) {
        case let (shortVersion?, buildNumber?):
            "\(shortVersion) (\(buildNumber))"
        case let (shortVersion?, nil):
            shortVersion
        case let (nil, buildNumber?):
            "Build \(buildNumber)"
        case (nil, nil):
            "Unknown"
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
