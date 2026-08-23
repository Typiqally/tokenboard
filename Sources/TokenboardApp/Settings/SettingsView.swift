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

        Section("Companion") {
            CompanionThemeShelf(model: model)

            CompanionSettingsPreview(model: model)

            if model.companionState.isVisible {
                Toggle("Show companion in menu bar", isOn: Binding(
                    get: { model.companionState.showInMenuBar },
                    set: { model.setShowCompanionInMenuBar($0) }
                ))
            }

            Text("Every scene is built into Tokenboard. Progress stays on this Mac and continues when the companion is hidden.")
                .foregroundStyle(.secondary)
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

private struct CompanionThemeShelf: View {
    @ObservedObject var model: AppModel
    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 92), spacing: 8),
        count: CompanionTheme.allCases.count
    )

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(CompanionTheme.allCases) { theme in
                    Button {
                        Task { await model.select(companionTheme: theme) }
                    } label: {
                        CompanionThemeShelfLabel(
                            theme: theme,
                            isSelected: model.companionState.theme == theme,
                            presentation: presentation(for: theme, date: context.date)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(theme.title). \(theme.subtitle)")
                    .accessibilityValue(
                        model.companionState.theme == theme ? "Selected" : "Not selected"
                    )
                }
            }
        }
    }

    private func presentation(
        for theme: CompanionTheme,
        date: Date
    ) -> CompanionPresentation? {
        var state = model.companionState
        state.theme = theme
        return CompanionPresentation.make(
            state: state,
            date: date,
            calendar: .current
        )
    }
}

private struct CompanionThemeShelfLabel: View {
    let theme: CompanionTheme
    let isSelected: Bool
    let presentation: CompanionPresentation?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .underPageBackgroundColor))

                if let presentation {
                    CompanionSceneView(presentation: presentation)
                } else {
                    Image(systemName: "minus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(theme.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct CompanionSettingsPreview: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let companion = CompanionPresentation.make(
                state: model.companionState,
                date: context.date,
                calendar: .current
            ) {
                HStack(alignment: .center, spacing: 18) {
                    CompanionSceneView(presentation: companion)
                        .frame(maxWidth: .infinity, minHeight: 142, maxHeight: 142)
                        .background(Color(nsColor: .underPageBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor))
                        }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(companion.theme.title) · \(companion.variant.title)")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.45)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(companion.stageTitle)
                            .font(.title3.weight(.semibold))
                        Text("Stage \(companion.stage + 1) of 8")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        ProgressView(value: companion.progressFraction)
                            .progressViewStyle(.linear)
                            .accessibilityLabel("Progress to next stage")
                        if let remaining = companion.tokensUntilNextStage {
                            Text("\(remaining.formatted()) tokens to the next scene")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Journey complete")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 250, maxWidth: 290, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
