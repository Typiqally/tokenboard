import SwiftUI
import TokenboardCore

enum SettingsCopy {
    static let launchAtLogin = "Off by default. No helper process."
    static let privacy = "No network entitlement · No conversation content stored"
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var launchAtLogin: LaunchAtLoginController

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { enabled in
                        do {
                            try launchAtLogin.setEnabled(enabled)
                        } catch {
                            // The controller publishes the inline error.
                        }
                    }
                ))
                Text(SettingsCopy.launchAtLogin)
                    .foregroundStyle(.secondary)
                if let error = launchAtLogin.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Launch at Login error: \(error)")
                }
            }
            .disabled(model.isDatabaseRecoveryActionLocked)

            Section("Sources") {
                SourceSettingsView(model: model, provider: .claudeCode)
                Divider()
                SourceSettingsView(model: model, provider: .codex)
            }
            .disabled(model.isDatabaseRecoveryActionLocked)

            Section("Pricing") {
                PricingSettingsView(model: model)
            }
            .disabled(model.isDatabaseRecoveryActionLocked)

            Section("Diagnostics") {
                if case .recoveryRequired = model.health.database {
                    DatabaseRecoveryView(model: model)
                }
                LabeledContent("Database") {
                    Text(databaseDescription(model.health.database))
                }
                LabeledContent("Last successful scan") {
                    if let date = model.health.lastSuccessfulScan {
                        Text(date.formatted(date: .abbreviated, time: .standard))
                    } else {
                        Text("Never")
                    }
                }
                LabeledContent("Skipped records") {
                    Text("\(model.health.skippedRecordCount)")
                }
                LabeledContent("Unpriced tokens") {
                    Text(ValueFormatter.exactTokens(model.health.unpricedTokens))
                }
                ForEach(Provider.allCases, id: \.rawValue) { provider in
                    LabeledContent("\(provider.displayName) parser") {
                        Text("v\(model.settingsState.diagnostics.parserVersions[provider, default: 0])")
                    }
                }
                Button("Reveal Local Data") {
                    model.revealLocalData()
                }
                Text(SettingsCopy.privacy)
                    .foregroundStyle(.secondary)
            }

            if let status = model.settingsState.statusMessage {
                Section {
                    Text(status)
                        .accessibilityLabel("Tokenboard status: \(status)")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 680, minHeight: 540)
        .disabled(model.settingsState.isLoading || model.isDatabaseRestoreInProgress)
    }

    var actionState: SettingsActionState {
        SettingsActionState(
            controlsEnabled: !model.settingsState.isLoading
                && !model.isDatabaseRestoreInProgress
                && !model.isDatabaseRecoveryActionLocked
        )
    }

    private func databaseDescription(_ state: TokenboardHealth.DatabaseState) -> String {
        switch state {
        case .healthy: "Healthy"
        case let .recoveryRequired(message): "Recovery required · \(message)"
        }
    }
}

struct SettingsActionState: Equatable {
    let controlsEnabled: Bool
}

private extension Provider {
    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}
