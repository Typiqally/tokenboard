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

        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(
            Set(persisted.keys),
            ["selectedPeriod", "selectedDisplayMetric", "historicalImportApproved"]
        )
        XCTAssertEqual(persisted["selectedPeriod"] as? String, "this_year")
        XCTAssertEqual(persisted["selectedDisplayMetric"] as? String, "api_value")
        XCTAssertEqual(persisted["historicalImportApproved"] as? Bool, true)
    }
}
