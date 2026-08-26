import SwiftUI
import TokenboardCore

struct SourceSettingsView: View {
    @ObservedObject var model: AppModel
    let provider: Provider

    var body: some View {
        let source = model.settingsState.sources[provider]
        VStack(alignment: .leading, spacing: 8) {
            Text(provider.displayName)
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
            if let source,
               let status = SourceSettingsPresentation.status(for: source.health) {
                Text(status)
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
        .accessibilityLabel("\(provider.displayName) source settings")
    }
}

enum SourceSettingsPresentation {
    static let providerOrder: [Provider] = [.claudeCode, .codex]

    static func status(for health: SourceHealth) -> String? {
        switch health {
        case .notGranted, .healthy, .warning:
            nil
        case let .indexing(fileCount):
            "Ready to scan \(fileCount) logs"
        }
    }
}
