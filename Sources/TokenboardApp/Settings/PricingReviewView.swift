import SwiftUI
import TokenboardCore

struct PricingReviewView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let pricing = model.settingsState.pricing
        let preview = pricing.preview
        VStack(alignment: .leading, spacing: 14) {
            Text("Pricing Candidate Review")
                .font(.title2.weight(.semibold))

            Form {
                reviewRow("Models added", value: preview?.diff.modelsAdded.joined(separator: ", ") ?? "0")
                reviewRow("Aliases added", value: "\(preview?.diff.aliasesAdded ?? 0)")
                reviewRow("Rates added", value: "\(preview?.diff.ratesAdded ?? 0)")
                reviewRow("Effective-date intervals", value: effectiveIntervals.joined(separator: "\n"))
                reviewRow("Official provenance URLs", value: provenanceURLs.joined(separator: "\n"))
                reviewRow(
                    "Current API-equivalent value",
                    value: ValueFormatter.usd(preview?.currentKnownUSD ?? .zero)
                )
                reviewRow(
                    "Candidate API-equivalent value",
                    value: ValueFormatter.usd(preview?.candidateKnownUSD ?? .zero)
                )
                reviewRow(
                    "Newly priced tokens",
                    value: ValueFormatter.exactTokens(preview?.newlyPricedTokens ?? 0)
                )
                reviewRow(
                    "Remaining unpriced tokens",
                    value: ValueFormatter.exactTokens(preview?.remainingUnpricedTokens ?? 0)
                )
                reviewRow("Conflicts and gaps", value: conflictsAndGaps.joined(separator: "\n"))
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
                .disabled(pricing.pendingCandidate == nil)
                Button("Apply") {
                    Task {
                        await model.applyPendingPricing()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!pricing.canApply)
            }
        }
        .padding(20)
        .frame(minWidth: 660, minHeight: 540)
    }

    @ViewBuilder
    private func reviewRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value.isEmpty ? "None" : value)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    private var effectiveIntervals: [String] {
        guard let candidate = model.settingsState.pricing.pendingCandidate?.catalog else {
            return []
        }
        var values: [String] = []
        for model in candidate.models {
            values.append(contentsOf: model.aliases.map {
                "Alias \(model.provider.rawValue)/\($0.observedModelID): \($0.effectiveFrom) → \($0.effectiveTo ?? "open")"
            })
            values.append(contentsOf: model.rates.map {
                "Rate \(model.provider.rawValue)/\(model.canonicalModelID): \($0.effectiveFrom) → \($0.effectiveTo ?? "open")"
            })
        }
        return Array(Set(values)).sorted()
    }

    private var provenanceURLs: [String] {
        model.settingsState.pricing.preview?.provenanceURLs
            .map(\.absoluteString)
            .sorted() ?? []
    }

    private var conflictsAndGaps: [String] {
        let pricing = model.settingsState.pricing
        var values = pricing.validationConflicts
        values.append(contentsOf: pricing.preview?.diff.conflicts ?? [])
        if let remaining = pricing.preview?.remainingUnpricedTokens, remaining > 0 {
            values.append("\(ValueFormatter.exactTokens(remaining)) tokens remain unpriced")
        }
        return values.isEmpty ? ["None"] : values
    }
}
