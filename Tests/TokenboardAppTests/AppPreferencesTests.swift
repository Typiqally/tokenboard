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
        XCTAssertFalse(preferences.discordPresenceEnabled)
        XCTAssertEqual(preferences.discordPresenceConsentVersion, 0)

        preferences.selectedPeriod = .thisYear
        preferences.selectedDisplayMetric = .apiValue
        preferences.selectedDisplayCurrency = .gbp
        preferences.historicalImportApproved = true
        preferences.selectedCompanionTheme = .forest
        preferences.showCompanionInMenuBar = true
        preferences.companionSeed = 42
        preferences.discordPresenceEnabled = true
        preferences.discordPresenceConsentVersion = 1
        preferences.companionAcknowledgedMilestone = CompanionMilestoneAcknowledgement(
            day: "2026-08-28",
            stage: 4
        )

        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(
            Set(persisted.keys),
            [
                "selectedPeriod", "selectedDisplayMetric", "selectedDisplayCurrency",
                "historicalImportApproved", "selectedCompanionTheme",
                "showCompanionInMenuBar", "companionSeed",
                "discordPresenceEnabled", "discordPresenceConsentVersion",
                "companionAcknowledgedMilestone"
            ]
        )
        XCTAssertEqual(persisted["selectedPeriod"] as? String, "this_year")
        XCTAssertEqual(persisted["selectedDisplayMetric"] as? String, "api_value")
        XCTAssertEqual(persisted["selectedDisplayCurrency"] as? String, "GBP")
        XCTAssertEqual(persisted["historicalImportApproved"] as? Bool, true)
        XCTAssertEqual(persisted["selectedCompanionTheme"] as? String, "forest")
        XCTAssertEqual(persisted["showCompanionInMenuBar"] as? Bool, true)
        XCTAssertEqual(persisted["companionSeed"] as? String, "42")
        XCTAssertEqual(persisted["discordPresenceEnabled"] as? Bool, true)
        XCTAssertEqual(persisted["discordPresenceConsentVersion"] as? Int, 1)
        XCTAssertEqual(persisted["companionAcknowledgedMilestone"] as? String, "2026-08-28:4")
        XCTAssertFalse(persisted.values.compactMap { $0 as? String }.contains { value in
            value.contains("/Users/") || value.contains("warning") || value.contains("project")
        })
    }

    func testMilestoneAcknowledgmentRoundTripsAndMalformedReadsAsNothing() {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)

        XCTAssertNil(preferences.companionAcknowledgedMilestone)
        let acknowledged = CompanionMilestoneAcknowledgement(day: "2026-08-28", stage: 3)
        preferences.companionAcknowledgedMilestone = acknowledged
        XCTAssertEqual(preferences.companionAcknowledgedMilestone, acknowledged)

        defaults.set("not a milestone", forKey: "companionAcknowledgedMilestone")
        XCTAssertNil(preferences.companionAcknowledgedMilestone)

        preferences.companionAcknowledgedMilestone = nil
        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertNil(persisted["companionAcknowledgedMilestone"])
    }

    func testLegacyPurgeSparesTheMilestoneAcknowledgment() {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // The retired lifetime-journey key names are close neighbours of the
        // daily milestone key; only they may be purged.
        defaults.set(7, forKey: "companionLastAcknowledgedStage")
        defaults.set("2026-08-28:4", forKey: "companionAcknowledgedMilestone")

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "companionLastAcknowledgedStage"))
        XCTAssertEqual(
            preferences.companionAcknowledgedMilestone,
            CompanionMilestoneAcknowledgement(day: "2026-08-28", stage: 4)
        )
    }

    func testUnknownPersistedCurrencyFallsBackToUSD() {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("BTC", forKey: "selectedDisplayCurrency")

        XCTAssertEqual(AppPreferences(defaults: defaults).selectedDisplayCurrency, .usd)
    }

    func testUnknownPersistedCompanionThemeFallsBackToNone() {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("castle", forKey: "selectedCompanionTheme")

        XCTAssertEqual(AppPreferences(defaults: defaults).selectedCompanionTheme, .none)
    }

    func testLegacyCompanionProgressIsRemovedInsteadOfUsedAsASecondTokenSource() {
        let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "companionProgressInitialized")
        defaults.set(1_422_581_001, forKey: "companionEarnedTokens")
        defaults.set(104_310_953_065, forKey: "companionLastObservedLifetimeTotal")
        defaults.set(11, forKey: "companionLastAcknowledgedStage")

        _ = AppPreferences(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "companionProgressInitialized"))
        XCTAssertNil(defaults.object(forKey: "companionEarnedTokens"))
        XCTAssertNil(defaults.object(forKey: "companionLastObservedLifetimeTotal"))
        XCTAssertNil(defaults.object(forKey: "companionLastAcknowledgedStage"))
    }
}
