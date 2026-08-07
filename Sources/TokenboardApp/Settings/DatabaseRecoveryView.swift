import AppKit
import SwiftUI
import TokenboardCore

struct DatabaseRecoveryView: View {
    @ObservedObject var model: AppModel
    var quit: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    @State private var confirmedBackup: DatabaseBackup?

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
                        .disabled(!actionState.canReveal)
                    Button(model.settingsState.isRestoringDatabase
                        ? "Restoring…"
                        : "Restore Latest Backup") {
                        confirmedBackup = backup
                    }
                    .disabled(!actionState.canRestore)
                    Button("Quit") { quit() }
                        .disabled(!actionState.canQuit)
                    if model.databaseRecoveryPreservationRetryRequired {
                        Button("Retry Preservation") {
                            Task { await model.retryDatabasePreservation() }
                        }
                        .disabled(!actionState.canRetryPreservation)
                    }
                }
                .alert(item: $confirmedBackup) { selectedBackup in
                    Alert(
                        title: Text("Restore backup from \(selectedBackup.modificationDate.formatted(date: .long, time: .shortened))?"),
                        message: Text("Tokenboard will stop local scanning and replace only ledger.sqlite after shutdown completes."),
                        primaryButton: .destructive(Text("Restore")) {
                            Task { await model.restoreBackup(selectedBackup) }
                        },
                        secondaryButton: .cancel()
                    )
                }
            } else {
                Text("No matching migration backup is available.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reveal Data") { model.revealLocalData() }
                        .disabled(!actionState.canReveal)
                    Button("Quit") { quit() }
                        .disabled(!actionState.canQuit)
                    if model.databaseRecoveryPreservationRetryRequired {
                        Button("Retry Preservation") {
                            Task { await model.retryDatabasePreservation() }
                        }
                        .disabled(!actionState.canRetryPreservation)
                    }
                }
            }
        }
    }

    var actionState: DatabaseRecoveryActionState {
        let enabled = !model.isDatabaseRestoreInProgress
        return DatabaseRecoveryActionState(
            canReveal: enabled,
            canRestore: enabled
                && !model.isDatabaseRecoveryActionLocked
                && !model.settingsState.recoveryBackups.isEmpty,
            canQuit: enabled && !model.databaseRecoveryPreservationRetryRequired,
            canRetryPreservation: enabled && model.databaseRecoveryPreservationRetryRequired
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
    let canRetryPreservation: Bool

    init(
        canReveal: Bool,
        canRestore: Bool,
        canQuit: Bool,
        canRetryPreservation: Bool = false
    ) {
        self.canReveal = canReveal
        self.canRestore = canRestore
        self.canQuit = canQuit
        self.canRetryPreservation = canRetryPreservation
    }
}
