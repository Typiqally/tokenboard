import Foundation
import TokenboardCore

@MainActor
final class AppPreferences {
    private enum Key {
        static let selectedPeriod = "selectedPeriod"
        static let selectedDisplayMetric = "selectedDisplayMetric"
        static let historicalImportApproved = "historicalImportApproved"
        static let dismissedWarningSignature = "dismissedWarningSignature"
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

    var historicalImportApproved: Bool {
        get { defaults.bool(forKey: Key.historicalImportApproved) }
        set { defaults.set(newValue, forKey: Key.historicalImportApproved) }
    }

    private static func isValidWarningSignature(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    var dismissedWarningSignature: String? {
        get {
            guard let value = defaults.string(forKey: Key.dismissedWarningSignature),
                  Self.isValidWarningSignature(value) else { return nil }
            return value
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.dismissedWarningSignature)
                return
            }
            guard Self.isValidWarningSignature(newValue) else {
                defaults.removeObject(forKey: Key.dismissedWarningSignature)
                return
            }
            defaults.set(newValue, forKey: Key.dismissedWarningSignature)
        }
    }
}
