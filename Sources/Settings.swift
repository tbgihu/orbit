import AppKit

/// What a manual Check for Updates is doing, or how it went. Shown in Settings.
enum UpdateActivity: Equatable { case none, checking, downloading, upToDate, offline, failed }

/// Orbit's settings (⌘,): how updates arrive, Check for Updates with its progress and result, the update to
/// install, the terminal Show Output opens in, Export Configuration and Uninstall Orbit.
/// Updates are handled here in place, with no other windows.
@MainActor
final class Settings: NSObject, NSWindowDelegate {
    private let perform: (Command) -> Void
    private let updatesAvailable: Bool

    private let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
    private let mode = NSPopUpButton()
    private let note = NSTextField(wrappingLabelWithString: "")
    /// Download and Install (Manually mode) or Restart to Update. Greyed out while orbits run.
    private let install = NSButton(title: "Download and Install", target: nil, action: nil)
    private let check = NSButton(title: "Check for Updates", target: nil, action: nil)
    /// "Checking for Updates…" over an indeterminate bar, then how it went.
    private let status = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let progress = NSStackView()
    private var grid = NSGridView()
    private let terminal = NSPopUpButton()
    private let export = NSButton(title: "Export Configuration…", target: nil, action: nil)
    /// Greyed out while orbits run, with the note saying why.
    private let uninstall = NSButton(title: "Uninstall Orbit…", target: nil, action: nil)
    private let uninstallNote = NSTextField(labelWithString: "Stop every orbit to uninstall.")

    init(updatesAvailable: Bool, perform: @escaping (Command) -> Void) {
        (self.perform, self.updatesAvailable) = (perform, updatesAvailable)
        super.init()
        window.title = "Orbit Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self

        mode.addItems(withTitles: Updater.Mode.allCases.map(\.title))
        mode.selectItem(at: Updater.Mode.allCases.firstIndex(of: Updater.mode) ?? 0)
        mode.target = self
        mode.action = #selector(changed)
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = 240
        check.target = self
        check.action = #selector(checkNow)
        status.preferredMaxLayoutWidth = 240
        bar.style = .bar
        bar.isIndeterminate = true
        bar.controlSize = .small
        progress.setViews([status, bar], in: .leading)
        progress.orientation = .vertical
        progress.alignment = .leading
        progress.spacing = 6
        install.target = self
        install.action = #selector(installNow)
        install.keyEquivalent = "\r"                                      // the primary action, drawn blue

        terminal.target = self
        terminal.action = #selector(terminalChanged)
        fillTerminals()
        export.target = self
        export.action = #selector(exportNow)
        uninstall.target = self
        uninstall.action = #selector(confirmUninstall)
        uninstallNote.textColor = .secondaryLabelColor
        uninstallNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        grid = NSGridView(views: [
            [NSTextField(labelWithString: "Updates:"), mode],
            [NSGridCell.emptyContentView, note],
            [NSGridCell.emptyContentView, progress],
            [NSGridCell.emptyContentView, install],
            [NSGridCell.emptyContentView, check],
            [NSTextField(labelWithString: "Terminal:"), terminal],
            [NSTextField(labelWithString: "Orbits:"), export],
            [NSGridCell.emptyContentView, uninstall],
            [NSGridCell.emptyContentView, uninstallNote],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        row(progress).topPadding = 6
        row(progress).isHidden = true                                    // until a check runs or an update is known
        row(install).isHidden = true                                     // until a newer version is known
        for view in [terminal, export, uninstall] { row(view).topPadding = 14 }
        row(uninstallNote).isHidden = true                               // until an orbit runs
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
            mode.widthAnchor.constraint(equalToConstant: 170),
            bar.widthAnchor.constraint(equalToConstant: 240),
            terminal.widthAnchor.constraint(equalToConstant: 170),
        ])
        if !updatesAvailable {                                            // built from a ZIP, so there is nothing to update from
            mode.isEnabled = false
            check.isEnabled = false
        }
        describe()
        window.setContentSize(content.fittingSize)
    }

    func present() { window.present() }

    /// The grid row that holds `view`.
    private func row(_ view: NSView) -> NSGridRow { grid.cell(for: view)!.row! }

    /// Describes the selected mode in one line.
    private func describe() {
        note.stringValue = switch Updater.mode {
        case .automatic: "Downloads updates automatically and installs them when no orbit is running."
        case .downloadOnly: "Downloads updates automatically and installs them when you click Restart to Update."
        case .manual: "Checks only when you click Check for Updates."
        }
    }

    @objc private func changed() {
        Updater.mode = Updater.Mode.allCases[mode.indexOfSelectedItem]
        describe()
        perform(.updateModeChanged)
    }

    @objc private func checkNow() { perform(.checkForUpdates) }

    /// Greys the button at once. It shows "Installing…" while Orbit quits into the installer, or the pending state
    /// that show(update:activity:) sets when orbits are running.
    @objc private func installNow() {
        install.isEnabled = false
        install.title = "Installing…"
        perform(.update)
    }

    /// Updates the update section in place: a check's progress and result, and once a newer version is known, its
    /// summary and button (Download and Install, or Restart to Update once downloaded), greyed while it waits for
    /// the orbits to stop. Check for Updates is greyed while a check runs.
    /// Export needs a file to copy. Uninstall is greyed while an orbit runs (`idle` false) or when this build
    /// has no uninstaller (it runs outside its bundle).
    func show(update: UpdateState, activity: UpdateActivity, idle: Bool) {
        export.isEnabled = Config.exists
        export.toolTip = export.isEnabled ? nil : "There is no orbits.json yet."
        uninstall.isEnabled = idle && Uninstall.script != nil
        row(uninstallNote).isHidden = idle
        let busy = activity == .checking || activity == .downloading
        check.isEnabled = !busy && mode.isEnabled
        busy ? bar.startAnimation(nil) : bar.stopAnimation(nil)
        bar.isHidden = !busy
        status.stringValue = switch activity {
        case .checking: "Checking for Updates…"
        case .downloading: "Downloading Update…"
        case _ where update != .none: update.summary
        case .upToDate: "Orbit is up to date."
        case .offline: "Couldn’t check for updates. Try again when online."
        case .failed: "Couldn’t check for updates. Details are in \(Runtime.logFile("Orbit").abbreviatingTilde)."
        case .none: ""
        }
        row(progress).isHidden = status.stringValue.isEmpty
        row(install).isHidden = update == .none || busy
        install.isEnabled = update.actionable
        install.title = update == .none ? install.title : update.title
        window.fitToContent()
    }

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

    // MARK: Export and uninstall

    @objc private func exportNow() { Config.export(on: window) }

    /// Asks before anything is removed. Export… saves the orbits, then asks again.
    @objc private func confirmUninstall() {
        uninstallAlert().beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch response {
                case .alertSecondButtonReturn: self.perform(.uninstall)
                case .alertThirdButtonReturn: Config.export(on: self.window) { [weak self] in self?.confirmUninstall() }
                default: break
                }
            }
        }
    }

    /// Uninstall is marked destructive, so no button answers Return and Escape cancels. Export… is there when
    /// there are orbits to keep.
    func uninstallAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Uninstall Orbit and delete all its code and data?"
        let code = Build[.source]
            .map { "Orbit, its Spotlight launchers and the folder you cloned (\($0.abbreviatingTilde))" }
            ?? "Orbit and its Spotlight launchers"
        alert.informativeText = "This deletes Orbit’s code: \(code). It also deletes your orbits "
            + "(\(Config.file.path.abbreviatingTilde)), settings, logs and Orbit’s signing identity. Export your orbits "
            + "first to keep them."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Uninstall").hasDestructiveAction = true
        if Config.exists { alert.addButton(withTitle: "Export…") }
        return alert
    }

    func windowWillClose(_ notification: Notification) { perform(.settingsClosed) }
}
