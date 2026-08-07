import SwiftUI
import TokenboardCore

enum SettingsCopy {
    static let launchAtLogin = "Off by default. No helper process."
    static let privacy = "No network entitlement · No conversation content stored"
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case sources
    case pricing
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .sources: "Sources"
        case .pricing: "Pricing"
        case .diagnostics: "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .sources: "folder"
        case .pricing: "dollarsign.circle"
        case .diagnostics: "wrench.and.screwdriver"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @State private var selectedSection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 210)
        } detail: {
            settingsForm
        }
        .frame(minWidth: 760, minHeight: 540)
        .disabled(model.settingsState.isLoading || model.isDatabaseRestoreInProgress)
    }

    private var settingsForm: some View {
        Form {
            switch selectedSection ?? .general {
            case .general:
                generalSection
            case .sources:
                sourcesSection
            case .pricing:
                pricingSection
            case .diagnostics:
                diagnosticsSection
            }

            if let status = model.settingsState.statusMessage {
                Section("Status") {
                    Text(status)
                        .accessibilityLabel("Tokenboard status: \(status)")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var generalSection: some View {
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
    }

    private var sourcesSection: some View {
        Section("Sources") {
            SourceSettingsView(model: model, provider: .claudeCode)
            Divider()
            SourceSettingsView(model: model, provider: .codex)
        }
        .disabled(model.isDatabaseRecoveryActionLocked)
    }

    private var pricingSection: some View {
        Section("Pricing") {
            PricingSettingsView(model: model)
        }
        .disabled(model.isDatabaseRecoveryActionLocked)
    }

    private var diagnosticsSection: some View {
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
