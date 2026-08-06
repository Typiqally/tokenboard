import SwiftUI
import TokenboardCore

enum OnboardingCopy {
    static let privacy = "Only token counts, model IDs, and timestamps are read. Conversation content is never retained."
    static let coverageWarning = "Tokenboard cannot recover conversations deleted before this first import."
}

struct OnboardingActionState: Equatable {
    let canStartHistoricalImport: Bool
    let canSelectSources: Bool

    init(state: AppPublishedState) {
        canStartHistoricalImport = state.canStartHistoricalImport
        canSelectSources = state.lifecycle == .ready && !state.isImporting
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel

    var actionState: OnboardingActionState {
        OnboardingActionState(state: model.state)
    }

    var body: some View {
        Form {
            Section {
                Text(OnboardingCopy.privacy)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("History folders") {
                sourceRow(provider: .claudeCode, title: "Claude Code")
                sourceRow(provider: .codex, title: "Codex")
            }

            Section {
                Label(
                    OnboardingCopy.coverageWarning,
                    systemImage: "exclamationmark.triangle"
                )
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Start Historical Import") {
                    Task { await model.startHistoricalImport() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!actionState.canStartHistoricalImport)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func sourceRow(provider: Provider, title: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(sourceDetail(provider))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.hasActiveGrant(for: provider) ? "Change" : "Grant") {
                Task { await model.chooseSource(provider) }
            }
            .disabled(model.isSourceMutationInProgress)
            .disabled(!actionState.canSelectSources)
            .accessibilityLabel(
                model.hasActiveGrant(for: provider)
                    ? "Change \(title) folder"
                    : "Grant \(title) folder access"
            )
        }
    }

    private func sourceDetail(_ provider: Provider) -> String {
        guard model.hasActiveGrant(for: provider) else { return "Access required" }
        let count = model.sourceFileCounts[provider, default: 0]
        return count == 1 ? "1 JSONL log found" : "\(count) JSONL logs found"
    }
}
