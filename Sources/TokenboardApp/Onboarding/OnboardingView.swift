import SwiftUI
import TokenboardCore

struct OnboardingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Text("Only token counts, model IDs, and timestamps are read. Conversation content is never retained.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("History folders") {
                sourceRow(provider: .claudeCode, title: "Claude Code")
                sourceRow(provider: .codex, title: "Codex")
            }

            Section {
                Label(
                    "Tokenboard cannot recover conversations deleted before this first import.",
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
                .disabled(!model.canStartHistoricalImport)
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
