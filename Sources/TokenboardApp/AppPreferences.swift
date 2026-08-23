import Foundation
import TokenboardCore

@MainActor
final class AppPreferences {
    private enum Key {
        static let selectedPeriod = "selectedPeriod"
        static let selectedDisplayMetric = "selectedDisplayMetric"
        static let selectedDisplayCurrency = "selectedDisplayCurrency"
        static let historicalImportApproved = "historicalImportApproved"
        static let selectedCompanionTheme = "selectedCompanionTheme"
        static let showCompanionInMenuBar = "showCompanionInMenuBar"
        static let companionSeed = "companionSeed"
        static let companionProgressInitialized = "companionProgressInitialized"
        static let companionEarnedTokens = "companionEarnedTokens"
        static let companionLastObservedLifetimeTotal = "companionLastObservedLifetimeTotal"
        static let companionLastAcknowledgedStage = "companionLastAcknowledgedStage"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedPeriod: CalendarPeriod {
        get {
            defaults.string(forKey: Key.selectedPeriod)
                .flatMap(CalendarPeriod.init(rawValue:)) ?? .today
        }
        set { defaults.set(newValue.rawValue, forKey: Key.selectedPeriod) }
    }

    var selectedDisplayMetric: DisplayMetric {
        get {
            defaults.string(forKey: Key.selectedDisplayMetric)
                .flatMap(DisplayMetric.init(rawValue:)) ?? .tokens
        }
        set { defaults.set(newValue.rawValue, forKey: Key.selectedDisplayMetric) }
    }

    var selectedDisplayCurrency: DisplayCurrency {
        get {
            defaults.string(forKey: Key.selectedDisplayCurrency)
                .flatMap(DisplayCurrency.init(rawValue:)) ?? .usd
        }
        set { defaults.set(newValue.rawValue, forKey: Key.selectedDisplayCurrency) }
    }

    var historicalImportApproved: Bool {
        get { defaults.bool(forKey: Key.historicalImportApproved) }
        set { defaults.set(newValue, forKey: Key.historicalImportApproved) }
    }

    var selectedCompanionTheme: CompanionTheme {
        get {
            defaults.string(forKey: Key.selectedCompanionTheme)
                .flatMap(CompanionTheme.init(rawValue:)) ?? .none
        }
        set { defaults.set(newValue.rawValue, forKey: Key.selectedCompanionTheme) }
    }

    var showCompanionInMenuBar: Bool {
        get { defaults.bool(forKey: Key.showCompanionInMenuBar) }
        set { defaults.set(newValue, forKey: Key.showCompanionInMenuBar) }
    }

    var companionSeed: UInt64 {
        get {
            if let rawValue = defaults.string(forKey: Key.companionSeed),
               let value = UInt64(rawValue) {
                return value
            }
            let value = UInt64.random(in: UInt64.min...UInt64.max)
            defaults.set(String(value), forKey: Key.companionSeed)
            return value
        }
        set { defaults.set(String(newValue), forKey: Key.companionSeed) }
    }

    var companionProgress: CompanionProgress? {
        get {
            guard defaults.bool(forKey: Key.companionProgressInitialized) else { return nil }
            return CompanionProgress(
                earnedTokens: max(0, defaults.object(forKey: Key.companionEarnedTokens)
                    .flatMap { ($0 as? NSNumber)?.int64Value } ?? 0),
                lastObservedLifetimeTotal: max(0, defaults.object(forKey: Key.companionLastObservedLifetimeTotal)
                    .flatMap { ($0 as? NSNumber)?.int64Value } ?? 0),
                lastAcknowledgedStage: max(0, min(
                    CompanionJourney.thresholds.count - 1,
                    defaults.integer(forKey: Key.companionLastAcknowledgedStage)
                ))
            )
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.companionProgressInitialized)
                defaults.removeObject(forKey: Key.companionEarnedTokens)
                defaults.removeObject(forKey: Key.companionLastObservedLifetimeTotal)
                defaults.removeObject(forKey: Key.companionLastAcknowledgedStage)
                return
            }
            defaults.set(true, forKey: Key.companionProgressInitialized)
            defaults.set(newValue.earnedTokens, forKey: Key.companionEarnedTokens)
            defaults.set(newValue.lastObservedLifetimeTotal, forKey: Key.companionLastObservedLifetimeTotal)
            defaults.set(newValue.lastAcknowledgedStage, forKey: Key.companionLastAcknowledgedStage)
        }
    }

}
