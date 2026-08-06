import SwiftUI
import TokenboardCore

struct PricingSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var promptSource = AgentPricingSource.tokenboardRepository
    @State private var showsReview = false

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
            HStack {
                Button("Review") { showsReview = true }
                    .disabled(pricing.pendingCandidate == nil)
                Button("Apply") {
                    Task { await model.applyPendingPricing() }
                }
                .disabled(!pricing.canApply)
                Button("Reject", role: .destructive) {
                    Task { await model.rejectPendingPricing() }
                }
                .disabled(pricing.pendingCandidate == nil)
            }
        }
        .sheet(isPresented: $showsReview) {
            PricingReviewView(model: model)
        }
    }
}
