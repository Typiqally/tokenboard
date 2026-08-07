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
        XCTAssertEqual(preferences.selectedDisplayCurrency, .usd)
        XCTAssertFalse(preferences.historicalImportApproved)

        preferences.selectedPeriod = .thisYear
        preferences.selectedDisplayMetric = .apiValue
        preferences.selectedDisplayCurrency = .gbp
        preferences.historicalImportApproved = true

        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(
            Set(persisted.keys),
            ["selectedPeriod", "selectedDisplayMetric", "selectedDisplayCurrency", "historicalImportApproved"]
        )
        XCTAssertEqual(persisted["selectedPeriod"] as? String, "this_year")
        XCTAssertEqual(persisted["selectedDisplayMetric"] as? String, "api_value")
        XCTAssertEqual(persisted["selectedDisplayCurrency"] as? String, "GBP")
        XCTAssertEqual(persisted["historicalImportApproved"] as? Bool, true)
        XCTAssertFalse(persisted.values.compactMap { $0 as? String }.contains { value in
            value.contains("/Users/") || value.contains("warning") || value.contains("project")
        })
    }

    func testUnknownPersistedCurrencyFallsBackToUSD() {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("BTC", forKey: "selectedDisplayCurrency")

        XCTAssertEqual(AppPreferences(defaults: defaults).selectedDisplayCurrency, .usd)
    }
}
