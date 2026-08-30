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
        static let discordPresenceEnabled = "discordPresenceEnabled"
        static let discordPresenceConsentVersion = "discordPresenceConsentVersion"
        static let companionAcknowledgedMilestone = "companionAcknowledgedMilestone"
        static let legacyCompanionProgress = [
            "companionProgressInitialized",
            "companionEarnedTokens",
            "companionLastObservedLifetimeTotal",
            "companionLastAcknowledgedStage",
        ]
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for key in Key.legacyCompanionProgress {
            defaults.removeObject(forKey: key)
        }
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

    var discordPresenceEnabled: Bool {
        get { defaults.bool(forKey: Key.discordPresenceEnabled) }
        set { defaults.set(newValue, forKey: Key.discordPresenceEnabled) }
    }

    var discordPresenceConsentVersion: Int {
        get { defaults.integer(forKey: Key.discordPresenceConsentVersion) }
        set { defaults.set(newValue, forKey: Key.discordPresenceConsentVersion) }
    }

    /// The highest companion stage already revealed today, as "day:stage".
    /// Malformed or absent reads as nothing acknowledged. Distinct from the
    /// purged legacy "companionLastAcknowledgedStage" key on purpose.
    var companionAcknowledgedMilestone: CompanionMilestoneAcknowledgement? {
        get {
            defaults.string(forKey: Key.companionAcknowledgedMilestone)
                .flatMap(CompanionMilestoneAcknowledgement.init(storageValue:))
        }
        set {
            if let newValue {
                defaults.set(
                    newValue.storageValue,
                    forKey: Key.companionAcknowledgedMilestone
                )
            } else {
                defaults.removeObject(forKey: Key.companionAcknowledgedMilestone)
            }
        }
    }

}
