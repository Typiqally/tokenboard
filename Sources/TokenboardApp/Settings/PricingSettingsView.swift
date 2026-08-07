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

struct PricingReviewContent: Equatable {
    let modelsAdded: String
    let aliases: [String]
    let rates: [String]
    let provenanceURLs: [String]
    let currentKnownUSD: String
    let candidateKnownUSD: String
    let newlyPricedTokens: String
    let remainingUnpricedTokens: String
    let conflictsAndGaps: [String]

    init(preview: PricingPreview, validationConflicts: [String]) {
        modelsAdded = preview.diff.modelsAdded.joined(separator: ", ")
        aliases = preview.reviewAliases.map { alias in
            "\(alias.provider.rawValue) · \(alias.observedModelID) → \(alias.canonicalModelID) · \(Self.interval(from: alias.effectiveFrom, to: alias.effectiveTo))"
        }
        rates = preview.reviewRates.map { rate in
            let price = NSDecimalNumber(decimal: rate.usdPerMillion).stringValue
            return "\(rate.provider.rawValue) · \(rate.canonicalModelID) · \(rate.metric.rawValue) · $\(price) / 1M · \(Self.interval(from: rate.effectiveFrom, to: rate.effectiveTo)) · \(rate.provenanceURL.absoluteString) · verified \(rate.verifiedAt)"
        }
        provenanceURLs = preview.provenanceURLs.map(\.absoluteString).sorted()
        currentKnownUSD = ValueFormatter.usd(preview.currentKnownUSD)
        candidateKnownUSD = ValueFormatter.usd(preview.candidateKnownUSD)
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
    @State private var promptSource = AgentPricingSource.tokenboardRepository
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
                validationConflicts: pricing.validationConflicts
            ),
            allowsApply: pricing.canApply
        )
    }

    var body: some View {
        let pricing = model.settingsState.pricing
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Active catalog IDs") {
                Text(pricing.activeCatalogIDs.isEmpty
                    ? "Unavailable"
                    : pricing.activeCatalogIDs.joined(separator: ", "))
                    .textSelection(.enabled)
            }
            LabeledContent("Verified") {
                Text(pricing.verificationDates.isEmpty
                    ? "Unavailable"
                    : pricing.verificationDates.joined(separator: ", "))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Official provenance")
                    .font(.subheadline.weight(.medium))
                if pricing.provenanceURLs.isEmpty {
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pricing.provenanceURLs, id: \.absoluteString) { url in
                        Text(url.absoluteString)
                            .textSelection(.enabled)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Unpriced models")
                    .font(.subheadline.weight(.medium))
                Text(pricing.unpricedModels.isEmpty
                    ? "None in the selected period"
                    : pricing.unpricedModels.joined(separator: ", "))
                    .textSelection(.enabled)
            }

            HStack {
                Picker("Agent prompt source", selection: $promptSource) {
                    Text("Tokenboard Repository")
                        .tag(AgentPricingSource.tokenboardRepository)
                    Text("Official Research")
                        .tag(AgentPricingSource.officialResearch)
                }
                .pickerStyle(.menu)
                Button("Copy Agent Prompt") {
                    Task { await model.copyAgentPrompt(source: promptSource) }
                }
            }

            LabeledContent("Pending candidate") {
                Text(pricing.pendingCandidate?.catalog.catalogID ?? "None")
            }
            Text(inboxStatusDescription(pricing.inboxStatus))
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
                    case .reject:
                        Button("Reject", role: .destructive) {
                            Task { await model.rejectPendingPricing() }
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

    private func inboxStatusDescription(_ status: PricingInboxStatus) -> String {
        switch status {
        case .empty: "No candidate detected"
        case .valid: "Validated candidate ready for review"
        case let .invalid(reason):
            switch reason {
            case .invalidCatalog: "Candidate is invalid"
            case .unsafeFile: "Candidate file is unsafe"
            case .candidateTooLarge: "Candidate file is too large"
            case .unreadableCandidate: "Candidate file cannot be read safely"
            }
        case .applying: "Applying validated candidate"
        case .appliedFinalizing: "Pricing committed; finalizing files"
        case .rejecting: "Rejecting validated candidate"
        case .rejectedFinalizing: "Candidate rejected; finalizing files"
        }
    }
}
