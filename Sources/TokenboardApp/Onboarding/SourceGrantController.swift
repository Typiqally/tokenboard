import AppKit
import TokenboardCore

@MainActor
final class SourceGrantController {
    private let store: SourceGrantStore

    init(store: SourceGrantStore) {
        self.store = store
    }

    @discardableResult
    func select(provider: Provider) throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant Read-Only Access"
        panel.message = "Tokenboard will read token, model, and timestamp fields from this folder. It never modifies source files or stores conversation content."
        if let suggestedDirectory = suggestedDirectory(for: provider) {
            panel.directoryURL = suggestedDirectory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try store.save(url: url, for: provider)
        return url
    }

    private func suggestedDirectory(for provider: Provider) -> URL? {
        let relativePath = switch provider {
        case .claudeCode: ".claude/projects"
        case .codex: ".codex/sessions"
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: relativePath, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return directory
    }
}
