import SwiftUI
import TokenboardCore

struct SourceSettingsView: View {
    @ObservedObject var model: AppModel
    let provider: Provider

    var body: some View {
        let source = model.settingsState.sources[provider]
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            LabeledContent("Resolved root") {
                Text(source?.resolvedPath ?? "Not granted")
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Access") {
                Text(source?.accessStatus ?? "Not granted")
            }
            LabeledContent("Logs") {
                Text("\(source?.fileCount ?? 0)")
            }
            LabeledContent("Last scan") {
                if let date = source?.lastScan {
                    Text(date.formatted(date: .abbreviated, time: .standard))
                } else {
                    Text("Never")
                }
            }
            if let source {
                Text(healthDescription(source.health))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(source?.resolvedPath == nil ? "Grant" : "Change") {
                    Task { await model.changeSource(provider) }
                }
                Button("Revoke", role: .destructive) {
                    Task { await model.revokeSource(provider) }
                }
                .disabled(source?.resolvedPath == nil)
            }
            .disabled(model.settingsState.isSourceMutationInProgress)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) source settings")
    }

    private var title: String {
        switch provider {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    private func healthDescription(_ health: SourceHealth) -> String {
        switch health {
        case .notGranted:
            "Access not granted"
        case let .indexing(fileCount):
            "Ready to scan \(fileCount) logs"
        case let .healthy(fileCount, _):
            "Healthy · \(fileCount) logs"
        case let .warning(_, message):
            "Needs attention · \(message)"
        }
    }
}
