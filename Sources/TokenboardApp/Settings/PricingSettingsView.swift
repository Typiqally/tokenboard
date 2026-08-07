import Foundation
import SwiftUI
import TokenboardCore

enum PricingSettingsCandidateAction: Equatable, Identifiable {
    case review(PricingCandidateIdentity)
    case reject(PricingCandidateIdentity)

    var id: String {
        switch self {
        case let .review(identity): "review-\(identity.digest)"
        case let .reject(identity): "reject-\(identity.digest)"
        }
    }
}

enum PricingOverviewCopy {
    static let displayCurrency = "Display currency"
    static let modelPricing = "Model pricing"
    static let exchangeRates = "Exchange rates"
    static let visibleLabels = [displayCurrency, modelPricing, exchangeRates]
}

struct PricingPromptOption: Equatable, Identifiable {
    let source: AgentPricingSource
    let buttonTitle: String
    let description: String

    var id: AgentPricingSource { source }
}

enum PricingUpdateCopy {
    static let explanation = "Tokenboard never connects to the internet. Copy one of the prompts below into Claude Code or Codex. The agent saves a local pricing candidate for your review."
    static let promptOptions = [
        PricingPromptOption(
            source: .tokenboardRepository,
            buttonTitle: "Copy Catalog-Only Prompt",
            description: "Uses only Tokenboard’s published model prices and exchange rates on GitHub."
        ),
        PricingPromptOption(
            source: .officialResearch,
            buttonTitle: "Copy Official-Sites Prompt",
            description: "Researches official OpenAI and Anthropic pricing plus ECB exchange rates."
        )
    ]

    static func inboxStatus(_ status: PricingInboxStatus) -> String {
        switch status {
        case .empty:
            "No candidate is waiting. Run the copied prompt to create one."
        case .valid:
            "A candidate is ready for review."
        case let .invalid(reason):
            switch reason {
            case .invalidCatalog:
                "The candidate file was rejected because its pricing catalog is invalid. Active pricing was not changed."
            case .unsafeFile:
                "The candidate file was rejected because it is not a safe local file. Active pricing was not changed."
            case .candidateTooLarge:
                "The candidate file was rejected because it is larger than 1 MiB. Active pricing was not changed."
            case .unreadableCandidate:
                "The candidate file could not be read safely. Active pricing was not changed."
            }
        case .applying:
            "Applying the approved pricing candidate."
        case .appliedFinalizing:
            "Pricing was updated. Finishing local file cleanup."
        case .rejecting:
            "Rejecting the pricing candidate."
        case .rejectedFinalizing:
            "Candidate rejected. Finishing local file cleanup."
        }
    }
}

struct PricingReviewContent: Equatable {
    let modelsAdded: String
    let aliases: [String]
    let rates: [String]
    let provenanceURLs: [String]
    let exchangeRates: [String]
    let exchangeRateProvenance: String
    let currentKnownValue: String
    let candidateKnownValue: String
    let newlyPricedTokens: String
    let remainingUnpricedTokens: String
    let conflictsAndGaps: [String]

    init(
        preview: PricingPreview,
        validationConflicts: [String],
        displayCurrency: DisplayCurrency
    ) {
        modelsAdded = preview.diff.modelsAdded.joined(separator: ", ")
        aliases = preview.reviewAliases.map { alias in
            "\(alias.provider.rawValue) · \(alias.observedModelID) → \(alias.canonicalModelID) · \(Self.interval(from: alias.effectiveFrom, to: alias.effectiveTo))"
        }
        rates = preview.reviewRates.map { rate in
            let price = NSDecimalNumber(decimal: rate.usdPerMillion).stringValue
            return "\(rate.provider.rawValue) · \(rate.canonicalModelID) · \(rate.metric.rawValue) · $\(price) / 1M · \(Self.interval(from: rate.effectiveFrom, to: rate.effectiveTo)) · \(rate.provenanceURL.absoluteString) · verified \(rate.verifiedAt)"
        }
        provenanceURLs = Array(Set(preview.reviewRates.map { $0.provenanceURL.absoluteString })).sorted()
        let changedCurrencies = Set(preview.diff.exchangeRatesChanged)
        if let candidateRates = preview.candidateExchangeRates {
            exchangeRates = DisplayCurrency.allCases.compactMap { currency in
                candidateRates.rates[currency].map {
                    "\(currency.rawValue) · \(Self.decimal($0)) per USD · \(changedCurrencies.contains(currency) ? "changed" : "unchanged")"
                }
            }
            exchangeRateProvenance = "\(candidateRates.provenanceURL.absoluteString) · checked \(candidateRates.verifiedAt)"
        } else {
            exchangeRates = []
            exchangeRateProvenance = "Unavailable"
        }
        currentKnownValue = Self.convertedValue(
            preview.currentKnownUSD,
            currency: displayCurrency,
            exchangeRates: preview.currentExchangeRates
        )
        candidateKnownValue = Self.convertedValue(
            preview.candidateKnownUSD,
            currency: displayCurrency,
            exchangeRates: preview.candidateExchangeRates
        )
        newlyPricedTokens = ValueFormatter.exactTokens(preview.newlyPricedTokens)
        remainingUnpricedTokens = ValueFormatter.exactTokens(preview.remainingUnpricedTokens)

        var issues = validationConflicts + preview.diff.conflicts
        issues.append(contentsOf: preview.unresolvedGaps.map { gap in
            "\(gap.provider.rawValue)/\(gap.observedModelID) · \(gap.metric.rawValue) · \(gap.effectiveDate) · \(ValueFormatter.exactTokens(gap.unpricedTokens)) unpriced"
        })
        if preview.unresolvedGaps.isEmpty, preview.remainingUnpricedTokens > 0 {
            issues.append("\(ValueFormatter.exactTokens(preview.remainingUnpricedTokens)) tokens remain unpriced")
        }
        conflictsAndGaps = issues.isEmpty ? ["None"] : issues
    }

    private static func interval(from: String, to: String?) -> String {
        "\(from) → \(to ?? "open")"
    }

    private static func convertedValue(
        _ usd: Decimal,
        currency: DisplayCurrency,
        exchangeRates: ExchangeRateSnapshot?
    ) -> String {
        guard let value = CurrencyConverter.convert(
            usd: usd,
            to: currency,
            rates: exchangeRates?.rates
        ) else { return "\(currency.rawValue) unavailable" }
        return "≈ \(ValueFormatter.currency(value, currency: currency))"
    }

    private static func decimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}

struct PricingReviewSelection: Equatable, Identifiable {
    let identity: PricingCandidateIdentity
    let content: PricingReviewContent
    let allowsApply: Bool

    var id: PricingCandidateIdentity { identity }

    func isCurrent(in pricing: PricingSettingsState) -> Bool {
        pricing.pendingCandidate?.identity == identity
    }
}

struct PricingSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var reviewSelection: PricingReviewSelection?

    var candidateActions: [PricingSettingsCandidateAction] {
        guard let identity = model.settingsState.pricing.pendingCandidate?.identity else { return [] }
        return [.review(identity), .reject(identity)]
    }

    var currentReviewSelection: PricingReviewSelection? {
        let pricing = model.settingsState.pricing
        guard let candidate = pricing.pendingCandidate, let preview = pricing.preview else { return nil }
        return PricingReviewSelection(
            identity: candidate.identity,
            content: PricingReviewContent(
                preview: preview,
                validationConflicts: pricing.validationConflicts,
                displayCurrency: model.selectedDisplayCurrency
            ),
            allowsApply: pricing.canApply
        )
    }

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
            ForEach(PricingUpdateCopy.promptOptions) { option in
                VStack(alignment: .leading, spacing: 4) {
                    Button(option.buttonTitle) {
                        Task { await model.copyAgentPrompt(source: option.source) }
                    }
                    Text(option.description)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LabeledContent("Candidate ready") {
                Text(pricing.pendingCandidate?.catalog.catalogID ?? "No")
            }
            Text(PricingUpdateCopy.inboxStatus(pricing.inboxStatus))
                .foregroundStyle(.secondary)
            HStack {
                ForEach(candidateActions) { action in
                    switch action {
                    case let .review(identity):
                        Button("Review") {
                            guard let selection = currentReviewSelection,
                                  selection.identity == identity else { return }
                            reviewSelection = selection
                        }
                    case let .reject(identity):
                        Button("Reject", role: .destructive) {
                            Task { await model.rejectPendingPricing(rejectedIdentity: identity) }
                        }
                    }
                }
                if pricing.finalizationIdentity != nil {
                    Button(model.settingsState.isFinalizationRetryInProgress
                        ? "Retrying Finalization…"
                        : "Retry Finalization") {
                        Task { await model.retryPricingFinalization() }
                    }
                    .disabled(!pricing.canRetryFinalization)
                }
            }
        }
        .sheet(item: $reviewSelection) { selection in
            PricingReviewView(model: model, review: selection)
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

    private static func decimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
