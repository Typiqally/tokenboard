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

enum PricingUpdateCopy {
    static let explanation = "Tokenboard never connects to the internet. Copy an update prompt and run it in Claude Code or Codex. The prompt tells the agent to use only the source you choose and save a candidate in Tokenboard’s local inbox for your review."

    static func sourceTitle(_ source: AgentPricingSource) -> String {
        switch source {
        case .tokenboardRepository: "Tokenboard Catalog"
        case .officialResearch: "Official Provider Sites"
        }
    }

    static func sourceDescription(_ source: AgentPricingSource) -> String {
        switch source {
        case .tokenboardRepository:
            "The agent may fetch only Tokenboard’s published pricing catalog from GitHub."
        case .officialResearch:
            "The agent may research pricing only on official OpenAI and Anthropic websites."
        }
    }

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

            Divider()

            Text("Update pricing")
                .font(.headline)
            Text(PricingUpdateCopy.explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Allowed source", selection: $promptSource) {
                Text(PricingUpdateCopy.sourceTitle(.tokenboardRepository))
                    .tag(AgentPricingSource.tokenboardRepository)
                Text(PricingUpdateCopy.sourceTitle(.officialResearch))
                    .tag(AgentPricingSource.officialResearch)
            }
            .pickerStyle(.menu)
            Text(PricingUpdateCopy.sourceDescription(promptSource))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Copy Update Prompt") {
                Task { await model.copyAgentPrompt(source: promptSource) }
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
}
