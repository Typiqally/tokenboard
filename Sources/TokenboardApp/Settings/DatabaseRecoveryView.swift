import AppKit
import SwiftUI
import TokenboardCore

struct DatabaseRecoveryView: View {
    @ObservedObject var model: AppModel
    var quit: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    @State private var confirmsRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(databaseMessage)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Database recovery required: \(databaseMessage)")

            if let backup = model.settingsState.recoveryBackups.first {
                Text("Latest backup · \(backup.modificationDate.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reveal Data") { model.revealLocalData() }
                    Button(model.settingsState.isRestoringDatabase
                        ? "Restoring…"
                        : "Restore Latest Backup") {
                        confirmsRestore = true
                    }
                    .disabled(model.isDatabaseRestoreInProgress)
                    Button("Quit") { quit() }
                }
                .alert(
                    "Restore backup from \(backup.modificationDate.formatted(date: .long, time: .shortened))?",
                    isPresented: $confirmsRestore
                ) {
                    Button("Cancel", role: .cancel) {}
                    Button("Restore", role: .destructive) {
                        Task { await model.restoreBackup(backup) }
                    }
                } message: {
                    Text("Tokenboard will stop local scanning and replace only ledger.sqlite after shutdown completes.")
                }
                .disabled(model.isDatabaseRestoreInProgress)
            } else {
                Text("No matching migration backup is available.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reveal Data") { model.revealLocalData() }
                    Button("Quit") { quit() }
                }
            }
        }
    }

    var actionState: DatabaseRecoveryActionState {
        let enabled = !model.isDatabaseRestoreInProgress
        return DatabaseRecoveryActionState(
            canReveal: enabled,
            canRestore: enabled && !model.settingsState.recoveryBackups.isEmpty,
            canQuit: enabled
        )
    }

    private var databaseMessage: String {
        switch model.health.database {
        case .healthy:
            "Database healthy"
        case let .recoveryRequired(message):
            message
        }
    }
}

struct DatabaseRecoveryActionState: Equatable {
    let canReveal: Bool
    let canRestore: Bool
    let canQuit: Bool
}
