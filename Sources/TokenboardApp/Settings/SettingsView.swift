import SwiftUI
import TokenboardCore

enum SettingsCopy {
    static let launchAtLogin = "Off by default. No helper process."
    static let privacy = "No remote network requests · No conversation content stored"
    static let technicalDetails = "Technical details"
}

enum DiscordPresenceSettingsPresentation {
    static let sectionTitle = "Discord Activity"
    static let toggleTitle = "Share activity on Discord"
    static let confirmationTitle = "Share activity on Discord?"
    static let confirmButtonTitle = "Share Activity"
    static let retryTitle = "Retry"
}

struct CompanionThemeOption: Equatable, Identifiable {
    let theme: CompanionTheme
    let isSelected: Bool

    var id: CompanionTheme { theme }

    var accessibilityLabel: String {
        let variants = CompanionCatalog.variants(for: theme)
        let description = variants.count == 1 ? variants[0].title : theme.subtitle
        return "\(theme.title). \(description)"
    }

    var accessibilityValue: String {
        isSelected ? "Selected" : "Not selected"
    }
}

enum CompanionSettingsPresentation {
    static func themeOptions(selected: CompanionTheme) -> [CompanionThemeOption] {
        CompanionTheme.allCases.map { theme in
            CompanionThemeOption(theme: theme, isSelected: theme == selected)
        }
    }
}

enum CompanionSettingsLayout {
    static let galleryColumnCount = 3
    static let galleryThumbnailHeight: CGFloat = 72
    static let galleryCardMinimumHeight: CGFloat = 112
    static let minimumPreviewWidth: CGFloat = 340
    static let maximumSceneWidth: CGFloat = 812
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
    @ObservedObject private var companionDiagnostics = CompanionDiagnostics.shared
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
        // The companion preview animates only while this window is on screen.
        .tracksCompanionSceneVisibility()
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
                    Text(UsageSelectionPresentation.currencyTitle(currency))
                        .tag(currency)
                        .disabled(!model.isDisplayCurrencyAvailable(currency))
                }
            }
            .pickerStyle(.menu)
        }
        .disabled(model.isDatabaseRecoveryActionLocked)

        Section("Companion") {
            CompanionSettingsPanel(model: model)

            Text("Companion stages follow today's tokens and reset at the start of each local day. Hiding the companion does not affect today's progress.")
                .foregroundStyle(.secondary)
        }
        .disabled(model.isDatabaseRecoveryActionLocked)

        DiscordPresenceSettingsSection(model: model, coordinator: model.discordPresence)
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
                    LabeledContent("Companion artwork") {
                        Text(companionDiagnostics.summary)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func databaseDescription(_ state: TokenboardHealth.DatabaseState) -> String {
        switch state {
        case .healthy: "Healthy"
        case let .recoveryRequired(message): "Recovery required · \(message)"
        }
    }
}

private struct DiscordPresenceSettingsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: DiscordPresenceCoordinator
    @State private var confirmationPresented = false

    var body: some View {
        Section(DiscordPresenceSettingsPresentation.sectionTitle) {
            Toggle(
                DiscordPresenceSettingsPresentation.toggleTitle,
                isOn: Binding(
                    get: { model.discordPresenceEnabled },
                    set: { enabled in
                        if !enabled {
                            Task { await model.setDiscordPresenceEnabled(false) }
                        } else if model.discordPresenceRequiresConsent {
                            confirmationPresented = true
                        } else {
                            Task { await model.setDiscordPresenceEnabled(true) }
                        }
                    }
                )
            )
            .disabled(!coordinator.isConfigured)

            LabeledContent("Preview") {
                let activity = model.discordPresencePreview
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Playing Tokenboard")
                        .font(.headline)
                    Text(activity.details)
                    Text(activity.state)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    DiscordPresencePresentation.accessibilityPreview(activity)
                )
            }

            if model.discordPresenceEnabled || !coordinator.isConfigured {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Text(coordinator.status.title)
                        if model.discordPresenceEnabled,
                           (coordinator.status == .discordNotRunning
                            || coordinator.status == .failed) {
                            Button(DiscordPresenceSettingsPresentation.retryTitle) {
                                Task { await model.retryDiscordPresence() }
                            }
                        }
                    }
                }
            }

            Text(DiscordPresencePresentation.disclosure)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert(
            DiscordPresenceSettingsPresentation.confirmationTitle,
            isPresented: $confirmationPresented
        ) {
            Button(DiscordPresenceSettingsPresentation.confirmButtonTitle) {
                Task { await model.confirmAndEnableDiscordPresence() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "\(DiscordPresencePresentation.accessibilityPreview(model.discordPresencePreview))\n\n\(DiscordPresencePresentation.disclosure)"
            )
        }
    }
}

struct CompanionSettingsPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 16) {
                CompanionThemeGallery(model: model, date: context.date)

                Divider()

                if let companion = model.companionPresentation(at: context.date) {
                    CompanionSettingsPreview(
                        companion: companion,
                        showInMenuBar: Binding(
                            get: { model.companionState.showInMenuBar },
                            set: { model.setShowCompanionInMenuBar($0) }
                        )
                    )
                } else {
                    ContentUnavailableView(
                        "No companion selected",
                        systemImage: "rectangle.slash",
                        description: Text("Choose a theme to begin today's journey.")
                    )
                    .frame(
                        minWidth: CompanionSettingsLayout.minimumPreviewWidth,
                        maxWidth: .infinity,
                        minHeight: 280
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CompanionThemeGallery: View {
    @ObservedObject var model: AppModel
    let date: Date

    var body: some View {
        let options = CompanionSettingsPresentation.themeOptions(
            selected: model.companionState.theme
        )

        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(minimum: 150), spacing: 12),
                count: CompanionSettingsLayout.galleryColumnCount
            ),
            spacing: 12
        ) {
            ForEach(options) { option in
                Button {
                    Task { await model.select(companionTheme: option.theme) }
                } label: {
                    CompanionThemeGalleryLabel(
                        theme: option.theme,
                        isSelected: option.isSelected,
                        presentation: presentation(for: option.theme)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.accessibilityLabel)
                .accessibilityValue(option.accessibilityValue)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Companion theme")
    }

    // Gallery thumbnails show a fixed, art-directed stage per theme so every
    // thumbnail is immediately recognizable regardless of current progress.
    // Pokémon still follows the day's starter family.
    private func presentation(for theme: CompanionTheme) -> CompanionPresentation? {
        guard let live = model.companionPresentation(
            at: date,
            overridingTheme: theme
        ) else { return nil }
        return live.preview(
            stage: CompanionAssetCatalog.shelfPreviewStage(for: theme),
            progressFraction: live.progressFraction,
            tokensUntilNextStage: live.tokensUntilNextStage,
            accessibilityLabel: "\(theme.title) preview"
        )
    }
}

private struct CompanionThemeGalleryLabel: View {
    let theme: CompanionTheme
    let isSelected: Bool
    let presentation: CompanionPresentation?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: CompanionSettingsLayout.galleryThumbnailHeight)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(theme.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(
            maxWidth: .infinity,
            minHeight: CompanionSettingsLayout.galleryCardMinimumHeight,
            alignment: .leading
        )
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CompanionSettingsPreview: View {
    let companion: CompanionPresentation
    @Binding var showInMenuBar: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CompanionSceneView(
                presentation: companion,
                isAmbientMotionActive: true
            )
            .aspectRatio(
                TokenboardSurfaceMetrics.popoverContentWidth
                    / TokenboardSurfaceMetrics.companionSceneHeight,
                contentMode: .fit
            )
            .frame(maxWidth: CompanionSettingsLayout.maximumSceneWidth)
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(companion.theme.title) · \(companion.variant.title)")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.45)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(companion.stageTitle)
                        .font(.title3.weight(.semibold))
                    Text("Stage \(companion.stage + 1) of \(CompanionJourney.thresholds.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 8)

                if let remaining = companion.tokensUntilNextStage {
                    Text("\(remaining.formatted()) tokens\nto the next scene")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                } else {
                    Text("Journey complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: companion.progressFraction)
                .progressViewStyle(.linear)
                .accessibilityLabel("Progress to next stage")

            Divider()

            Toggle("Show companion in menu bar", isOn: $showInMenuBar)
        }
        .frame(
            minWidth: CompanionSettingsLayout.minimumPreviewWidth,
            maxWidth: .infinity,
            alignment: .leading
        )
    }
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selectedSection: SettingsSection

    init(selectedSection: SettingsSection = .general) {
        self.selectedSection = selectedSection
    }
}
