import Foundation
import XCTest
@testable import TokenboardApp
import TokenboardCore

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testDefaultsAndWritesOnlyApprovedKeys() {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedPeriod, .today)
        XCTAssertEqual(preferences.selectedDisplayMetric, .tokens)
        XCTAssertFalse(preferences.historicalImportApproved)

        preferences.selectedPeriod = .thisYear
        preferences.selectedDisplayMetric = .apiValue
        preferences.historicalImportApproved = true

        let digest = String(repeating: "a", count: 64)
        preferences.dismissedWarningSignature = digest

        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(
            Set(persisted.keys),
            ["selectedPeriod", "selectedDisplayMetric", "historicalImportApproved", "dismissedWarningSignature"]
        )
        XCTAssertEqual(persisted["selectedPeriod"] as? String, "this_year")
        XCTAssertEqual(persisted["selectedDisplayMetric"] as? String, "api_value")
        XCTAssertEqual(persisted["historicalImportApproved"] as? Bool, true)
        XCTAssertEqual(persisted["dismissedWarningSignature"] as? String, digest)
        XCTAssertFalse(persisted.values.compactMap { $0 as? String }.contains { value in
            value.contains("/Users/") || value.contains("warning") || value.contains("project")
        })
    }

    func testDismissedWarningSignaturePersistsOnlyValidatedDigest() {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let digest = String(repeating: "a", count: 64)

        XCTAssertNil(preferences.dismissedWarningSignature)
        preferences.dismissedWarningSignature = digest
        XCTAssertEqual(AppPreferences(defaults: defaults).dismissedWarningSignature, digest)
        XCTAssertEqual(defaults.string(forKey: "dismissedWarningSignature"), digest)

        for invalid in [
            String(repeating: "A", count: 64),
            String(repeating: "é", count: 64),
            String(repeating: "g", count: 64),
            "/Users/example/private warning"
        ] {
            defaults.set(invalid, forKey: "dismissedWarningSignature")
            XCTAssertNil(AppPreferences(defaults: defaults).dismissedWarningSignature)
        }

        preferences.dismissedWarningSignature = nil
        XCTAssertNil(defaults.object(forKey: "dismissedWarningSignature"))
    }
}
