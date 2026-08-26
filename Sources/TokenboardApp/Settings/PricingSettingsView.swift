import SwiftUI
import TokenboardCore

enum PricingOverviewCopy {
    static let displayCurrency = "Display currency"
    static let unpricedUsage = "Unpriced usage"
    static let modelPricing = "Model pricing"
    static let modelPricingHint = "USD per million tokens. All current catalog rates are shown."
    static let exchangeRates = "Exchange rates"
    static let visibleLabels = [displayCurrency, unpricedUsage, modelPricing, exchangeRates]
}

struct PricingProviderGroup: Equatable, Identifiable {
    let provider: Provider
    let models: [ActiveModelPricingSummary]

    var id: Provider { provider }
}

struct PricingExchangeRateRow: Equatable, Identifiable {
    let currency: DisplayCurrency
    let formattedRate: String

    var id: DisplayCurrency { currency }
}

enum PricingSettingsPresentation {
    static func groups(
        for models: [ActiveModelPricingSummary]
    ) -> [PricingProviderGroup] {
        Provider.allCases.compactMap { provider in
            let providerModels = models
                .filter { $0.provider == provider }
                .sorted { $0.canonicalModelID < $1.canonicalModelID }
            guard !providerModels.isEmpty else { return nil }
            return PricingProviderGroup(provider: provider, models: providerModels)
        }
    }

    static func metrics(for group: PricingProviderGroup) -> [UsageMetric] {
        UsageMetric.allCases.filter { metric in
            group.models.contains { $0.rates[metric] != nil }
        }
    }

    static func exchangeRateRows(
        for snapshot: ExchangeRateSnapshot
    ) -> [PricingExchangeRateRow] {
        DisplayCurrency.allCases.compactMap { currency in
            guard currency != .usd, let rate = snapshot.rates[currency] else {
                return nil
            }
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            let precision = currency == .jpy ? 2 : 4
            formatter.minimumFractionDigits = precision
            formatter.maximumFractionDigits = precision
            guard let formattedRate = formatter.string(
                from: NSDecimalNumber(decimal: rate)
            ) else {
                return nil
            }
            return PricingExchangeRateRow(
                currency: currency,
                formattedRate: formattedRate
            )
        }
    }
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
                    Text(UsageSelectionPresentation.currencyTitle(currency))
                        .tag(currency)
                        .disabled(!model.isDisplayCurrencyAvailable(currency))
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
            if pricing.coveragePeriod != model.selectedPeriod {
                Text("Refreshing pricing coverage…")
                    .foregroundStyle(.secondary)
            } else if pricing.unpricedUsage.isEmpty {
                Text("All observed usage in this period has pricing.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pricing.unpricedUsage) { usage in
                    VStack(alignment: .leading, spacing: 3) {
                        LabeledContent(usage.observedModelID) {
                            Text("\(ValueFormatter.exactTokens(usage.tokenCount)) tokens")
                        }
                        Text("\(usage.provider.displayName) · \(Self.unpricedReason(usage))")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("For \(UsageSelectionPresentation.periodTitle(model.selectedPeriod).lowercased()).")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text(PricingOverviewCopy.modelPricing)
                .font(.headline)
            if pricing.activeModels.isEmpty {
                Text("No active model rates. Update pricing to add them.")
                    .foregroundStyle(.secondary)
            } else {
                Text(PricingOverviewCopy.modelPricingHint)
                    .foregroundStyle(.secondary)
                let groups = PricingSettingsPresentation.groups(for: pricing.activeModels)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        PricingProviderLedger(group: group)
                    }
                }
            }

            Divider()

            Text(PricingOverviewCopy.exchangeRates)
                .font(.headline)
            if let exchangeRates = pricing.exchangeRates {
                HStack(alignment: .firstTextBaseline) {
                    Text("Checked \(exchangeRates.verifiedAt)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("1 USD equals")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(PricingSettingsPresentation.exchangeRateRows(for: exchangeRates)) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(UsageSelectionPresentation.currencyDisplayName(row.currency))
                            Spacer()
                            Text(row.formattedRate)
                                .monospacedDigit()
                            Text(row.currency.rawValue)
                                .foregroundStyle(.secondary)
                                .frame(width: 32, alignment: .leading)
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

    private static func unpricedReason(_ usage: UnpricedUsageGroup) -> String {
        switch usage.reason {
        case .opaqueModel: "Unknown model identifier"
        case .missingAlias: "Missing catalog entry"
        case .missingRate:
            usage.canonicalModelID.map { "Missing rate for \($0)" } ?? "Missing rate"
        }
    }

}

private struct PricingProviderLedger: View {
    let group: PricingProviderGroup

    private var metrics: [UsageMetric] {
        PricingSettingsPresentation.metrics(for: group)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(providerName)
                    .font(.headline)
                Spacer()
                Text(modelCount)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 7)

            Divider()

            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                    GridRow(alignment: .bottom) {
                        ledgerHeader("Model", width: 210, alignment: .leading)
                        ForEach(metrics, id: \.rawValue) { metric in
                            ledgerHeader(metricName(metric), width: 80, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 6)

                    Divider()
                        .gridCellColumns(metrics.count + 1)

                    ForEach(Array(group.models.enumerated()), id: \.element.id) { index, model in
                        GridRow(alignment: .center) {
                            Text(model.canonicalModelID)
                                .font(.subheadline.monospaced().weight(.medium))
                                .lineLimit(1)
                                .textSelection(.enabled)
                                .frame(width: 210, alignment: .leading)

                            ForEach(metrics, id: \.rawValue) { metric in
                                rateCell(model.rates[metric], metric: metric)
                            }
                        }
                        .padding(.vertical, 6)

                        if index < group.models.count - 1 {
                            Divider()
                                .gridCellColumns(metrics.count + 1)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(providerName) pricing, \(modelCount)")
    }

    private func ledgerHeader(
        _ title: String,
        width: CGFloat,
        alignment: Alignment
    ) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .lineLimit(2)
            .frame(width: width, alignment: alignment)
    }

    @ViewBuilder
    private func rateCell(_ rate: Decimal?, metric: UsageMetric) -> some View {
        if let rate {
            Text(ValueFormatter.currency(rate, currency: .usd))
                .font(.subheadline.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
                .accessibilityLabel(
                    "\(metricName(metric)), \(ValueFormatter.currency(rate, currency: .usd)) per million tokens"
                )
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .trailing)
                .accessibilityLabel("\(metricName(metric)), unavailable")
        }
    }

    private var providerName: String {
        group.provider.displayName
    }

    private var modelCount: String {
        "\(group.models.count) \(group.models.count == 1 ? "model" : "models")"
    }

    private func metricName(_ metric: UsageMetric) -> String {
        switch metric {
        case .inputUncached: "Input"
        case .inputCacheRead: "Cached"
        case .inputCacheWrite: "Cache write"
        case .inputCacheWrite5m: "Write · 5m"
        case .inputCacheWrite1h: "Write · 1h"
        case .inputUnclassified: "Unclassified"
        case .output: "Output"
        case .detailReasoningOutput: "Reasoning"
        }
    }
}
