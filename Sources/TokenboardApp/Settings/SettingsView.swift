import SwiftUI
import TokenboardCore

enum SettingsCopy {
    static let launchAtLogin = "Off by default. No helper process."
    static let privacy = "No network entitlement · No conversation content stored"
    static let technicalDetails = "Technical details"
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

enum SettingsNavigationPresentation {
    static let sections = SettingsSection.allCases
}

struct SettingsDiagnosticIssue: Equatable, Identifiable {
    let provider: Provider
    let message: String

    var id: String { provider.rawValue }

    static func current(in health: TokenboardHealth) -> [SettingsDiagnosticIssue] {
        Provider.allCases.compactMap { provider in
            switch health.source(provider) {
            case .notGranted:
                SettingsDiagnosticIssue(provider: provider, message: "Access required")
            case .indexing, .healthy:
                nil
            case let .warning(_, message):
                SettingsDiagnosticIssue(provider: provider, message: message)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var navigation: SettingsNavigationModel
    @State private var technicalDetailsExpanded = false

    init(
        model: AppModel,
        launchAtLogin: LaunchAtLoginController,
        navigation: SettingsNavigationModel = SettingsNavigationModel()
    ) {
        self.model = model
        self.launchAtLogin = launchAtLogin
        self.navigation = navigation
    }

    var body: some View {
        TabView(selection: $navigation.selectedSection) {
            ForEach(SettingsNavigationPresentation.sections) { section in
                settingsForm(for: section)
                    .tabItem {
                        Label(section.title, systemImage: section.systemImage)
                    }
                    .tag(section)
            }
        }
        .frame(minWidth: 940, minHeight: 600)
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .disabled(model.settingsState.isLoading || model.isDatabaseRestoreInProgress)
    }

    private func settingsForm(for section: SettingsSection) -> some View {
        Form {
            switch section {
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

    @ViewBuilder
    private var generalSection: some View {
        Section("Menu Bar") {
            Picker("Display", selection: Binding(
                get: { model.selectedDisplayMetric },
                set: { metric in
                    Task { await model.select(displayMetric: metric) }
                }
            )) {
                ForEach(UsageSelectionPresentation.displayMetrics, id: \.rawValue) { metric in
                    Text(UsageSelectionPresentation.displayMetricTitle(metric))
                        .tag(metric)
                }
            }
            .pickerStyle(.segmented)

            Picker("Period", selection: Binding(
                get: { model.selectedPeriod },
                set: { period in
                    Task { await model.select(period: period) }
                }
            )) {
                ForEach(UsageSelectionPresentation.periods, id: \.rawValue) { period in
                    Text(UsageSelectionPresentation.periodTitle(period))
                        .tag(period)
                }
            }

            Picker("Currency", selection: Binding(
                get: { model.selectedDisplayCurrency },
                set: { model.select(displayCurrency: $0) }
            )) {
                ForEach(UsageSelectionPresentation.currencies, id: \.rawValue) { currency in
                    Text(currency.rawValue).tag(currency)
                }
            }
            .pickerStyle(.menu)
        }
        .disabled(model.isDatabaseRecoveryActionLocked)

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

        Section("About") {
            LabeledContent("Version") {
                Text(BuildInfo.currentVersionDescription)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
        }
    }

    private var sourcesSection: some View {
        Section("Sources") {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(
                    Array(SourceSettingsPresentation.providerOrder.enumerated()),
                    id: \.element
                ) { index, provider in
                    if index > 0 {
                        Divider()
                    }
                    SourceSettingsView(model: model, provider: provider)
                }
            }
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
            Button("Reveal Local Data") {
                model.revealLocalData()
            }
            Text(SettingsCopy.privacy)
                .foregroundStyle(.secondary)

            DisclosureGroup(
                SettingsCopy.technicalDetails,
                isExpanded: $technicalDetailsExpanded
            ) {
                let issues = SettingsDiagnosticIssue.current(in: model.health)
                VStack(alignment: .leading, spacing: 10) {
                    if issues.isEmpty {
                        Text("No source issues")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(issues) { issue in
                            LabeledContent(issue.provider.displayName) {
                                Text(issue.message)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    LabeledContent("Skipped records") {
                        Text("\(model.health.skippedRecordCount)")
                    }
                    ForEach(Provider.allCases, id: \.rawValue) { provider in
                        LabeledContent("\(provider.displayName) parser") {
                            Text("v\(model.settingsState.diagnostics.parserVersions[provider, default: 0])")
                        }
                    }
                }
                .padding(.top, 6)
            }
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

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selectedSection: SettingsSection

    init(selectedSection: SettingsSection = .general) {
        self.selectedSection = selectedSection
    }
}
