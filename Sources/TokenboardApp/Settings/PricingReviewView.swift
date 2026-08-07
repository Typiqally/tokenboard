import SwiftUI
import TokenboardCore

struct PricingReviewView: View {
    @ObservedObject var model: AppModel
    let review: PricingReviewSelection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let content = review.content
        let isCurrent = review.isCurrent(in: model.settingsState.pricing)
        VStack(alignment: .leading, spacing: 14) {
            Text("Pricing Candidate Review")
                .font(.title2.weight(.semibold))

            Form {
                reviewRow("Models added", value: content.modelsAdded)
                reviewRow("Observed → canonical aliases", value: content.aliases.joined(separator: "\n"))
                reviewRow("USD per million rates", value: content.rates.joined(separator: "\n"))
                reviewRow("Official provenance URLs", value: content.provenanceURLs.joined(separator: "\n"))
                reviewRow("Current API-equivalent value", value: content.currentKnownUSD)
                reviewRow("Candidate API-equivalent value", value: content.candidateKnownUSD)
                reviewRow("Newly priced tokens", value: content.newlyPricedTokens)
                reviewRow("Remaining unpriced tokens", value: content.remainingUnpricedTokens)
                reviewRow("Conflicts and gaps", value: content.conflictsAndGaps.joined(separator: "\n"))
            }
            .formStyle(.grouped)

            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Button("Reject", role: .destructive) {
                    Task {
                        await model.rejectPendingPricing()
                        dismiss()
                    }
                }
                .disabled(!isCurrent)
                Button("Apply") {
                    Task {
                        await model.applyPendingPricing(reviewedIdentity: review.identity)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!review.allowsApply || !isCurrent)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 600)
    }

    @ViewBuilder
    private func reviewRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value.isEmpty ? "None" : value)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}
