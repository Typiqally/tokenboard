import Foundation
import TokenboardCore

@MainActor
final class AppPreferences {
    private enum Key {
        static let selectedPeriod = "selectedPeriod"
        static let selectedDisplayMetric = "selectedDisplayMetric"
        static let selectedDisplayCurrency = "selectedDisplayCurrency"
        static let historicalImportApproved = "historicalImportApproved"
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

}
