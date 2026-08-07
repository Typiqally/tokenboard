import SwiftUI
import TokenboardCore

enum PricingOverviewCopy {
    static let displayCurrency = "Display currency"
    static let unpricedUsage = "Unpriced usage"
    static let modelPricing = "Model pricing"
    static let exchangeRates = "Exchange rates"
    static let visibleLabels = [displayCurrency, unpricedUsage, modelPricing, exchangeRates]
}

enum PricingUpdateCopy {
    static let buttonTitle = "Copy Pricing Update Prompt"
    static let explanation = "Tokenboard has no network access. Paste this prompt into Claude Code or Codex; the agent researches pricing, reports its sources, and safely replaces the local catalog. Valid changes apply automatically."

    static func status(
        _ status: PricingCatalogStatus?,
        activeCatalogID: String?
    ) -> String {
        switch status {
        case let .current(catalogID):
            "Active catalog · \(catalogID)"
        case .invalid:
            activeCatalogID.map { "Last update failed · Keeping \($0)" }
                ?? "Last update failed · No valid catalog is active"
        case nil:
            activeCatalogID.map { "Active catalog · \($0)" }
                ?? "Pricing catalog is starting"
        }
    }
}

struct PricingSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let pricing = model.settingsState.pricing
        VStack(alignment: .leading, spacing: 10) {
            Picker(PricingOverviewCopy.displayCurrency, selection: Binding(
                get: { model.selectedDisplayCurrency },
                set: { model.select(displayCurrency: $0) }
            )) {
                ForEach(DisplayCurrency.allCases, id: \.rawValue) { currency in
                    Text(Self.currencyName(currency))
                        .tag(currency)
                        .disabled(currency != .usd && pricing.exchangeRates?.rates[currency] == nil)
                }
            }
            .pickerStyle(.menu)
            Text("API-equivalent values are calculated in USD, then converted locally for display.")
                .foregroundStyle(.secondary)
            if model.selectedDisplayCurrency != .usd,
               pricing.exchangeRates?.rates[model.selectedDisplayCurrency] == nil {
                Text("\(model.selectedDisplayCurrency.rawValue) is unavailable. Update pricing to add its exchange rate.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text(PricingOverviewCopy.unpricedUsage)
                .font(.headline)
            if pricing.unpricedUsage.isEmpty {
                Text("All observed usage in this period has pricing.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pricing.unpricedUsage) { usage in
                    VStack(alignment: .leading, spacing: 3) {
                        LabeledContent(usage.observedModelID) {
                            Text("\(ValueFormatter.exactTokens(usage.tokenCount)) tokens")
                        }
                        Text("\(Self.providerName(usage.provider)) · \(Self.unpricedReason(usage))")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("For \(Self.periodName(model.selectedPeriod).lowercased()).")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text(PricingOverviewCopy.modelPricing)
                .font(.headline)
            if pricing.activeModels.isEmpty {
                Text("No active model rates. Update pricing to add them.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pricing.activeModels) { modelPricing in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Self.providerName(modelPricing.provider)) · \(modelPricing.canonicalModelID)")
                            .fontWeight(.medium)
                            .textSelection(.enabled)
                        ForEach(UsageMetric.allCases, id: \.rawValue) { metric in
                            if let rate = modelPricing.rates[metric] {
                                LabeledContent(Self.metricName(metric)) {
                                    Text("\(ValueFormatter.currency(rate, currency: .usd)) / 1M")
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            Text(PricingOverviewCopy.exchangeRates)
                .font(.headline)
            if let exchangeRates = pricing.exchangeRates {
                Text("Checked \(exchangeRates.verifiedAt)")
                    .foregroundStyle(.secondary)
                ForEach(DisplayCurrency.allCases, id: \.rawValue) { currency in
                    if let rate = exchangeRates.rates[currency] {
                        LabeledContent("1 USD") {
                            Text("\(Self.decimal(rate)) \(currency.rawValue)")
                        }
                    }
                }
            } else {
                Text("No exchange rates installed. Update pricing to enable currency conversion.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Update pricing")
                .font(.headline)
            Text(PricingUpdateCopy.explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The prompt includes the missing model identifiers shown above, never usage amounts or conversation data.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(PricingUpdateCopy.buttonTitle) {
                Task { await model.copyAgentPrompt() }
            }
            Text(PricingUpdateCopy.status(
                pricing.catalogStatus,
                activeCatalogID: pricing.activeCatalogID
            ))
            .foregroundStyle(.secondary)
        }
    }

    private static func currencyName(_ currency: DisplayCurrency) -> String {
        switch currency {
        case .usd: "USD · US Dollar"
        case .eur: "EUR · Euro"
        case .jpy: "JPY · Japanese Yen"
        case .gbp: "GBP · British Pound"
        case .cny: "CNY · Chinese Yuan"
        }
    }

    private static func providerName(_ provider: Provider) -> String {
        switch provider {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    private static func metricName(_ metric: UsageMetric) -> String {
        switch metric {
        case .inputUncached: "Input"
        case .inputCacheRead: "Cached input"
        case .inputCacheWrite: "Cache write"
        case .inputCacheWrite5m: "Cache write · 5m"
        case .inputCacheWrite1h: "Cache write · 1h"
        case .inputUnclassified: "Unclassified input"
        case .output: "Output"
        case .detailReasoningOutput: "Reasoning detail"
        }
    }

    private static func unpricedReason(_ usage: UnpricedUsageGroup) -> String {
        switch usage.reason {
        case .opaqueModel: "Unknown model identifier"
        case .missingAlias: "Missing catalog entry"
        case .missingRate:
            usage.canonicalModelID.map { "Missing rate for \($0)" } ?? "Missing rate"
        }
    }

    private static func periodName(_ period: CalendarPeriod) -> String {
        switch period {
        case .today: "Today"
        case .thisWeek: "This week"
        case .thisMonth: "This month"
        case .thisYear: "This year"
        case .allTime: "All time"
        }
    }

    private static func decimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
