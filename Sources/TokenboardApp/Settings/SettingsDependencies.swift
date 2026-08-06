import AppKit
import Foundation

@MainActor
protocol AppPlainTextCopying: AnyObject {
    @discardableResult
    func replace(with value: String) -> Bool
}

@MainActor
final class GeneralPasteboardTextCopier: AppPlainTextCopying {
    @discardableResult
    func replace(with value: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
    }
}

@MainActor
protocol AppLocalDataRevealing: AnyObject {
    func reveal(_ urls: [URL])
}

@MainActor
final class WorkspaceLocalDataRevealer: AppLocalDataRevealing {
    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
