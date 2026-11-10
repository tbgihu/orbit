import AppKit

/// Orbit's settings (⌘,): the terminal Show Output opens in.
@MainActor
final class Settings: NSObject, NSWindowDelegate {
    private let perform: (Command) -> Void

    private let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
    private var grid = NSGridView()
    private let terminal = NSPopUpButton()

    init(perform: @escaping (Command) -> Void) {
        self.perform = perform
        super.init()
        window.title = "Orbit Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self

        terminal.target = self
        terminal.action = #selector(terminalChanged)
        fillTerminals()

        grid = NSGridView(views: [
            [NSTextField(labelWithString: "Terminal:"), terminal],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        terminal.toolTip = "Show Output opens a new window in this terminal."
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        window.contentView = content
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            terminal.widthAnchor.constraint(equalToConstant: 170),
        ])
        window.setContentSize(content.fittingSize)
    }

    func present() { window.present() }

    // MARK: Terminal

    /// Lists Default (the app that opens .command scripts), the installed terminals that run scripts, and Other….
    private func fillTerminals() {
        terminal.removeAllItems()
        let fallback = Terminal.defaultApp.map(Terminal.name(of:)) ?? "Terminal"
        terminal.addItem(withTitle: "Default (\(fallback))")
        let defaultID = Terminal.defaultApp.flatMap { Bundle(url: $0)?.bundleIdentifier }
        for app in Terminal.installed where app.id != defaultID || Defaults.terminal == app.id {   // no duplicate
            terminal.addItem(withTitle: app.name)
            terminal.lastItem?.representedObject = app.id
        }
        terminal.menu?.addItem(.separator())
        terminal.addItem(withTitle: "Other…")
        let chosen = terminal.itemArray.first { Defaults.terminal != nil && $0.representedObject as? String == Defaults.terminal }
        terminal.select(chosen ?? terminal.item(at: 0))
    }

    @objc private func terminalChanged() {
        guard terminal.indexOfSelectedItem != terminal.numberOfItems - 1 else { return chooseTerminal() }
        Defaults.terminal = terminal.selectedItem?.representedObject as? String
    }

    /// Other… accepts any app that can run scripts.
    private func chooseTerminal() {
        let open = NSOpenPanel()
        open.directoryURL = URL(filePath: "/Applications")
        open.allowedContentTypes = [.application]
        open.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.fillTerminals() }
                guard response == .OK, let app = open.url else { return }
                guard Terminal.runsScripts(app), let id = Bundle(url: app)?.bundleIdentifier else {
                    let alert = NSAlert()
                    alert.messageText = "\(Terminal.name(of: app)) can’t run scripts."
                    alert.informativeText = "Show Output needs a terminal that opens .command scripts."
                    alert.beginSheetModal(for: self.window)
                    return
                }
                Defaults.terminal = id
            }
        }
    }

    func windowWillClose(_ notification: Notification) { perform(.settingsClosed) }
}
