import AppKit
import UniformTypeIdentifiers

/// The terminal Show Output opens in. macOS has no default terminal setting; the closest is the app that opens
/// `.command` scripts (Open with, in Finder's Get Info), which is the default here. Settings can pick another app
/// that runs scripts. The script is opened as a document, so it gets a new window and leaves open ones alone.
@MainActor
enum Terminal {
    private static let scripts = [UTType("com.apple.terminal.shell-script"), UTType.unixExecutable].compactMap(\.self)
    /// Terminals offered by name when installed (others can still be chosen with Other…).
    private static let known = ["com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2",
                                "com.github.wez.wezterm", "net.kovidgoyal.kitty", "dev.warp.Warp-Stable"]

    /// The app that opens `.command` scripts.
    static var defaultApp: URL? { scripts.first.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } }

    /// Whether an app declares it can open scripts (and so run them).
    static func runsScripts(_ app: URL) -> Bool {
        scripts.contains { NSWorkspace.shared.urlsForApplications(toOpen: $0).map(\.standardizedFileURL).contains(app.standardizedFileURL) }
    }

    /// Installed terminals that run scripts, by bundle id and name, the chosen one included.
    static var installed: [(id: String, name: String)] {
        var ids = known
        if let chosen = Defaults.terminal, !ids.contains(chosen) { ids.append(chosen) }
        return ids.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), runsScripts(url) else { return nil }
            return (id, name(of: url))
        }
    }

    static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Opens `script` in the chosen terminal (a new window), else the default one. `done` hears whether it
    /// opened, on any thread.
    static func open(_ script: URL, then done: @escaping @Sendable (Bool) -> Void) {
        let app = Defaults.terminal.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } ?? defaultApp
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let app {
            NSWorkspace.shared.open([script], withApplicationAt: app, configuration: configuration) { app, _ in done(app != nil) }
        } else {
            done(NSWorkspace.shared.open(script))
        }
    }
}
