import AppKit

#if DEBUG
if CommandLine.arguments.dropFirst().first == "--review-discord-preview" {
    guard CommandLine.arguments.count == 3 else {
        fputs("usage: TokenboardApp --review-discord-preview <output-directory>\n", stderr)
        exit(64)
    }
    do {
        try DiscordArtworkExporter.exportSettingsReview(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        exit(0)
    } catch {
        fputs("Discord preview review failed: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.dropFirst().first == "--export-discord-assets" {
    guard CommandLine.arguments.count == 3 else {
        fputs("usage: TokenboardApp --export-discord-assets <new-directory>\n", stderr)
        exit(64)
    }
    do {
        try DiscordArtworkExporter.export(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        exit(0)
    } catch {
        fputs("Discord artwork export failed: \(error)\n", stderr)
        exit(1)
    }
}
#endif

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
