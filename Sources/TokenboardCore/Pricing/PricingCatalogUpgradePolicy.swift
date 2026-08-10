import Foundation

public enum PricingCatalogUpgradePolicy {
    public static func shouldReplaceRepositoryCatalog(
        _ current: ValidatedPricingCatalog,
        with candidate: ValidatedPricingCatalog
    ) -> Bool {
        guard current.origin.kind == .tokenboardRepository,
              candidate.origin.kind == .tokenboardRepository,
              let currentDate = timestamp(current.generatedAt),
              let candidateDate = timestamp(candidate.generatedAt) else {
            return false
        }
        return candidateDate > currentDate
    }

    private static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
