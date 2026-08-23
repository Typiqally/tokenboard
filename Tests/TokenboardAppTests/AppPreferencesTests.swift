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
        XCTAssertEqual(preferences.selectedCompanionTheme, .none)
        XCTAssertFalse(preferences.showCompanionInMenuBar)
        XCTAssertNil(preferences.companionProgress)

        preferences.selectedPeriod = .thisYear
        preferences.selectedDisplayMetric = .apiValue
        preferences.selectedDisplayCurrency = .gbp
        preferences.historicalImportApproved = true
        preferences.selectedCompanionTheme = .tree
        preferences.showCompanionInMenuBar = true
        preferences.companionSeed = 42
        preferences.companionProgress = CompanionProgress(
            earnedTokens: 4_000_000,
            lastObservedLifetimeTotal: 50_000_000,
            lastAcknowledgedStage: 1
        )

        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(
            Set(persisted.keys),
            [
                "selectedPeriod", "selectedDisplayMetric", "selectedDisplayCurrency",
                "historicalImportApproved", "selectedCompanionTheme",
                "showCompanionInMenuBar", "companionSeed", "companionProgressInitialized",
                "companionEarnedTokens", "companionLastObservedLifetimeTotal",
                "companionLastAcknowledgedStage"
            ]
        )
        XCTAssertEqual(persisted["selectedPeriod"] as? String, "this_year")
        XCTAssertEqual(persisted["selectedDisplayMetric"] as? String, "api_value")
        XCTAssertEqual(persisted["selectedDisplayCurrency"] as? String, "GBP")
        XCTAssertEqual(persisted["historicalImportApproved"] as? Bool, true)
        XCTAssertEqual(persisted["selectedCompanionTheme"] as? String, "tree")
        XCTAssertEqual(persisted["showCompanionInMenuBar"] as? Bool, true)
        XCTAssertEqual(persisted["companionSeed"] as? String, "42")
        XCTAssertEqual(persisted["companionProgressInitialized"] as? Bool, true)
        XCTAssertEqual(persisted["companionEarnedTokens"] as? NSNumber, 4_000_000)
        XCTAssertEqual(persisted["companionLastObservedLifetimeTotal"] as? NSNumber, 50_000_000)
        XCTAssertEqual(persisted["companionLastAcknowledgedStage"] as? NSNumber, 1)
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
