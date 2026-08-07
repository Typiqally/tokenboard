import AppKit
import TokenboardCore

@MainActor
protocol AppSourcePicking: Sendable {
    func select(provider: Provider) throws -> URL?
}

@MainActor
final class SourceGrantController: AppSourcePicking {
    @discardableResult
    func select(provider: Provider) throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant Read-Only Access"
        panel.message = "Tokenboard will read token, model, and timestamp fields from this folder. It never modifies source files or stores conversation content."
        panel.directoryURL = Self.suggestedDirectory(
            for: provider,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL
    }

    static func suggestedDirectory(for provider: Provider, homeDirectory: URL) -> URL {
        let relativePath = switch provider {
        case .claudeCode: ".claude/projects"
        case .codex: ".codex/sessions"
        }
        return homeDirectory.appending(path: relativePath, directoryHint: .isDirectory)
    }
}
