import AppKit

/// What can be done with one orbit, by name. The menu and the window ask for these with `Command.orbit`. A
/// launcher, the command line (`orbit toggle <orbit>`) and anything else outside Orbit name one in a URL,
/// `orbit://toggle/<id>`. The URLs, the subcommands and their help are all made from this list, so a new action
/// only has to say what it does (`Agent.perform`), how it reads in help (`summary`), when it is done
/// (`CLI.verdict`); the compiler asks for each.
enum Action: String, CaseIterable {
    case start, stop, restart, toggle
    /// Clears a failed run's "!".
    case dismiss

    var summary: String {
        switch self {
        case .start: "start it and wait until it runs, or answers at its address"
        case .stop: "stop it and wait until it has ended"
        case .restart: "stop it if it runs, then start it and wait as start does"
        case .toggle: "start it, or stop it if it runs, like its Spotlight launcher"
        case .dismiss: "clear the mark a failed run left"
        }
    }

    func url(_ id: String) -> URL { URL(string: "\(Build.scheme)://\(rawValue)/\(id)")! }   // an id is letters and digits
}

/// What can be asked of Orbit as a whole, by name, the way an `Action` is asked of one orbit: `orbit://window`,
/// `orbit window`. Each says what it does (`Agent.perform`), how it reads in help and when it is done
/// (`CLI.verdict`).
enum Request: String, CaseIterable {
    case stopAll = "stop-all"
    case window, settings

    var summary: String {
        switch self {
        case .stopAll: "stop every orbit and wait until all have ended"
        case .window: "open Orbit's window"
        case .settings: "open Orbit's settings"
        }
    }

    var url: URL { URL(string: "\(Build.scheme)://\(rawValue)")! }
}

/// Requests to the agent. The menu, the window, Settings, the New Orbit sheet, launchers and the command line
/// all go through `Agent.perform(_:)`.
enum Command {
    case orbit(Action, String)
    case app(Request)
    case reorder([String])
    /// Re-reads the config, which may have changed (menu opened, window focused, orbit saved or renamed).
    case reload
    case newOrbit, editOrbit(String)
    /// Show Output: a terminal window that follows the orbit's log.
    case showOutput(String)
    /// The config problem was clicked. Opens orbits.json, or New Orbit when there is no file yet.
    case editConfig
    case checkForUpdates, updateModeChanged
    /// Restart to Update, or Download and Install.
    case update
    /// Uninstall Orbit, confirmed in Settings: quits, then everything Orbit put on this Mac is removed.
    case uninstall
    case quit
    case windowClosed, settingsClosed, sheetClosed

    /// What an `orbit://<action>/<id>` or `orbit://<request>` URL asks for.
    init?(url: URL) {
        guard url.scheme == Build.scheme, let name = url.host() else { return nil }
        if let request = Request(rawValue: name) {
            self = .app(request)
        } else if let action = Action(rawValue: name), let id = url.pathComponents.dropFirst().first {
            self = .orbit(action, id)
        } else {
            return nil
        }
    }
}

/// Orbit itself, as opposed to a launcher. It runs only while an orbit runs or a window is open. Launchers and
/// the command line start it on demand with an `Action`'s URL and talk to it over its socket (`Link`) while it
/// runs; opening Orbit itself (Spotlight, Finder) shows the window.
@MainActor
final class Agent: NSObject, NSApplicationDelegate {
    private lazy var jobs = Jobs(changed: { [weak self] in self?.refresh() }, ended: { [weak self] in self?.jobEnded() },
                                 progressed: { [weak self] in self?.progressed() })
    private var menuBar: MenuBar?
    private var window: Window?
    /// The open New Orbit sheet, retained here because AppKit doesn't keep its buttons' target alive.
    private var sheet: NewOrbit?
    private var settings: Settings?
    /// A manual Check for Updates: what it is doing, then how it went. Shown in Settings.
    private var updateActivity = UpdateActivity.none
    /// Update was clicked while orbits ran. It installs once the last one stops; runs are never interrupted for it.
    private var updateScheduled = false

    /// The update shown in the title bar, the menu and Settings: one already downloaded, or in Manually mode a newer
    /// version that a check found.
    private var updateState: UpdateState {
        guard updater.ready || Updater.mode == .manual && updater.newer else { return .none }
        return updateScheduled ? .pending : updater.ready ? .restart : .download
    }
    private let updater = Updater()
    /// Where launchers and the command line reach this agent while it runs.
    private var link: Link.Server?
    private var signalSources: [DispatchSourceSignal] = []
    private var terminating = false
    /// A prepared update is installed before a request Orbit was started with; the new Orbit gets the request.
    private var updatingOnLaunch = false
    private var deferred: [URL] = []
    /// It is not yet known why this Orbit was started (`classifyLaunch`).
    private var launchUndecided = false
    /// Another Orbit is already running, so this one hands over its requests and quits.
    private var duplicate = false
    /// Quit without asking (logout, shutdown, sleep, a signal, an update restart).
    private var quietQuit = false

    /// Runs before any URL is delivered (a launch URL arrives before `applicationDidFinishLaunching`).
    func applicationWillFinishLaunching(_ notification: Notification) {
        duplicate = !Runtime.claimInstance()
        guard !duplicate else { return }
        updatingOnLaunch = updater.installsByItself
        guard !updatingOnLaunch else { return }
        prepare()
    }

    /// What an Orbit that stays does before anything else.
    private func prepare() {
        Runtime.reapOrphans()          // before any job of this instance exists
        Config.reload()
        ShellEnvironment.refresh()
        launchUndecided = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDefault = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) == true
        if duplicate {
            handOver(deferred, showWindow: isDefault)
            return
        }
        if updatingOnLaunch, !deferred.isEmpty {
            updater.install(reopen: deferred.map(\.absoluteString))
            terminating = true
            NSApp.terminate(nil)
            return
        }
        if updatingOnLaunch {          // no request to pass on
            updatingOnLaunch = false
            prepare()
        }

        // stop everything on sleep, since tunnels would die anyway
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.quit(quietly: true) } }

        // kill, pkill and launchd at logout quit through the normal path so children are stopped
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.quit(quietly: true) } }
            source.resume()
            signalSources.append(source)
        }

        // only now, so a request can't overtake the one in the URL this agent was started with
        link = Link.Server(state: { [unowned self] in Snapshot(jobs) }, request: { [unowned self] request in
            receive(URL(string: request).flatMap(Command.init).map { [$0] } ?? [], from: "the socket")
        }, left: { [unowned self] in quitIfIdle() })
        NSApp.mainMenu = mainMenu()
        updater.onChange = { [weak self] in self?.refresh() }
        updater.start()

        if !isDefault {
            classifyLaunch(person: false, "not a default launch")
        } else if NSApp.isActive {
            classifyLaunch(person: true, "active at launch")
        } else {
            // macOS rarely activates a menu bar app it opens, so a default launch asked nothing is a person's
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.classifyLaunch(person: true, "asked nothing for a second") }
            }
        }
        // started with nothing to do after all, e.g. restored at login
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in MainActor.assumeIsolated { self?.quitIfIdle() } }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        classifyLaunch(person: true, "activated")
    }

    func applicationWillTerminate(_ notification: Notification) { classifyLaunch(person: false, "never activated") }

    /// Something asked Orbit for something (a URL or the socket), so this launch was not a person opening it.
    func asked(by asker: String) {
        lastAsked = .now
        classifyLaunch(person: false, "asked by \(asker)")
    }
    /// When something last asked Orbit for something, so a reopen around then is taken as theirs.
    private var lastAsked = Date.distantPast

    /// Settles, once, why Orbit was started, by the launch itself rather than by when anything arrives. A launch to
    /// open a URL (a launcher, the command line, an update) or restored at login is not a default launch. A default
    /// launch is a person opening Orbit (Finder, Spotlight, the Dock, `open -a`) when Orbit becomes active, or when
    /// nothing asks for anything within a second, since macOS seldom activates a menu bar app it opens. A
    /// person gets the window, after installing a prepared update, since nothing runs yet. Orbit.log says how each
    /// launch was taken and why.
    private func classifyLaunch(person: Bool, _ signal: String) {
        guard launchUndecided else { return }
        launchUndecided = false
        Runtime.log("launched \(person ? "by a person" : "in the background"): \(signal)")
        guard person else { return }
        guard updater.installsByItself else { return showWindow() }
        updater.install(reopen: [Request.window.url.absoluteString])
        quit(quietly: true)
    }

    /// Orbit opened again while it runs. A person doing so (Finder, Spotlight, the Dock, `open -a`) gets the window,
    /// at once when macOS activates Orbit, else after a second in which nothing asked for anything, as at launch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !NSApp.isActive else { showWindow(); return false }
        let reopened = Date.now
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.terminating else { return }
                if abs(self.lastAsked.timeIntervalSince(reopened)) < 1 { Runtime.log("reopened in the background: asked") }
                else { self.showWindow() }
            }
        }
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let urls = urls.filter { Command(url: $0) != nil }
        guard !updatingOnLaunch, !duplicate else { deferred += urls; return }
        receive(urls.compactMap(Command.init), from: "a URL")
    }

    /// Requests from outside, by URL or over the socket. The config is read again first, since whoever asks
    /// may have just changed it; with no commands that is all there is to do.
    private func receive(_ commands: [Command], from asker: String) {
        asked(by: asker)
        reloadConfig()
        commands.forEach(perform)
        quitIfIdle()
    }

    /// Passes this second instance's requests to the Orbit already running, then quits.
    private func handOver(_ urls: [URL], showWindow: Bool) {
        terminating = true
        let me = getpid()
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != me }), let otherURL = other.bundleURL else { NSApp.terminate(nil); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = showWindow
        let done: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        if urls.isEmpty {
            NSWorkspace.shared.openApplication(at: otherURL, configuration: configuration, completionHandler: done)  // its window
        } else {
            NSWorkspace.shared.open(urls, withApplicationAt: otherURL, configuration: configuration, completionHandler: done)
        }
    }

    private func quit(quietly: Bool) {
        quietQuit = quietQuit || quietly
        NSApp.terminate(nil)
    }

    /// Quits at once when nothing runs. Otherwise a quit from ⌘Q, the menu or the Dock asks first (unless turned
    /// off), then the orbits are stopped in the background (SIGTERM, then SIGKILL after a grace period) and Orbit
    /// quits once they are gone, so the interface never blocks.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = jobs.inOrder
        guard !running.isEmpty || !jobs.lingering.isEmpty else { terminating = true; return .terminateNow }
        if !running.isEmpty, !quietQuit, !systemQuit(), Defaults.askBeforeQuit {
            let names = running.map { "“\($0.spec.name)”" }
            let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
            let alert = NSAlert()
            alert.messageText = "Quit Orbit?"
            alert.informativeText = "\(list) \(running.count == 1 ? "is" : "are") running and will be stopped."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            NSApp.bringToFront()
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return .terminateCancel }
            if alert.suppressionButton?.state == .on { Defaults.askBeforeQuit = false }
        }
        terminating = true
        // While AppKit waits for the reply it runs a run loop mode that doesn't service the main queue (exit events,
        // timers), so the jobs are stopped off the main thread and the reply is delivered into that mode.
        jobs.terminateAll(grace: 1.5) {
            RunLoop.main.perform(inModes: [.modalPanel, .default]) {
                MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }

    /// Quitting because macOS logs out, restarts or shuts down (no one to ask).
    private func systemQuit() -> Bool {
        guard let reason = quitRequest("why?")?.enumCodeValue else { return false }
        return ["logo", "rlgo", "rest", "rrst", "shut", "rsdn"].map(Self.fourCC).contains(reason)
    }

    /// The attribute `keyword` of the Apple event being handled, the quit request; nil when there is none.
    private func quitRequest(_ keyword: String) -> NSAppleEventDescriptor? {
        NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: Self.fourCC(keyword))
    }

    /// A four-character code, as Apple events name attributes and values, as its number.
    private static func fourCC(_ code: String) -> FourCharCode { code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func perform(_ command: Command) {
        switch command {
        case .orbit(.start, let id): jobs.start(id)
        case .orbit(.stop, let id): jobs.stop(id)
        case .orbit(.restart, let id): jobs.restart(id)
        case .orbit(.toggle, let id): jobs.toggle(id)
        case .orbit(.dismiss, let id):
            jobs.dismiss(id)
            refresh()
            quitIfIdle()
        case .app(.stopAll): jobs.stopAll()
        case .app(.window): showWindow()
        case .app(.settings): showSettings()
        case .showOutput(let id):
            if let orbit = Config.orbit(id) ?? jobs[id]?.spec { Runtime.showOutput(orbit.name) }
        case .reorder(let ids):
            Config.reorder(ids)
            refresh()
        case .reload: reloadConfig()
        case .newOrbit: openSheet(editing: nil)
        case .editOrbit(let id): openSheet(editing: id)
        case .editConfig: if Config.exists { Config.edit() } else { openSheet(editing: nil) }
        case .checkForUpdates: checkForUpdates()
        case .updateModeChanged:
            updater.start()
            showUpdate()
        case .update: restartToUpdate()
        case .uninstall:
            guard jobs.running.isEmpty, Uninstall.start() else { return }
            quit(quietly: true)
        case .quit: NSApp.terminate(nil)
        case .windowClosed:
            window = nil
            windowsChanged()
        case .settingsClosed:
            settings = nil
            if updateActivity != .checking, updateActivity != .downloading { updateActivity = .none }
            windowsChanged()
        case .sheetClosed: sheet = nil
        }
    }

    // MARK: Jobs

    private func jobEnded() {
        guard !terminating else { return }
        refresh()
        if updateScheduled, jobs.running.isEmpty {                   // install the update clicked earlier
            updateScheduled = false
            restartToUpdate()
            return
        }
        quitIfIdle()
    }

    /// Quits once nothing runs, the window is closed and nobody waits for an answer (a client on
    /// the socket), installing a prepared update on the way out.
    func quitIfIdle() {
        guard idle else { return }
        if updater.installsByItself { updater.install(reopen: []) }
        NSApp.terminate(nil)
    }

    /// Nothing runs, waits, is shown or is being asked, so Orbit has nothing to stay for.
    private var idle: Bool {
        jobs.running.isEmpty && jobs.restarting.isEmpty && jobs.waiting.isEmpty && jobs.failures.isEmpty
            && window == nil && settings == nil && link?.busy != true && !terminating
    }

    // MARK: Updates

    /// Update was clicked. With orbits running it waits until the last one stops, since they are never interrupted.
    /// Otherwise Orbit restarts into the update, and the installer makes sure it is the newest version.
    private func restartToUpdate() {
        guard updater.ready || updater.newer else { return }
        guard jobs.running.isEmpty else {
            updateScheduled = true
            refresh()
            return
        }
        updater.install(reopen: window != nil ? [Request.window.url.absoluteString] : [])
        quit(quietly: true)
    }

    // MARK: Interface

    /// Re-reads the config when it may have just been edited, which also brings the launchers, logs and settings
    /// in line with it, and refreshes everything, including an update prepared meanwhile. Cheap: a small file,
    /// the launchers' Info.plists and a few stats.
    private func reloadConfig() {
        Config.reload()
        refresh()
    }

    /// Updates the window, the menu bar item, which exists only while some orbit is active, and whoever follows
    /// over the socket.
    private func refresh() {
        jobs.forgetRemoved()
        link?.publish()
        let entries: [Entry] = Config.orbits.map { spec in
            if let job = jobs[spec.id] { return .running(job) }
            if jobs.failures.contains(spec.id) { return .failed(spec) }
            return .idle(spec)
        } + jobs.unlisted.map(Entry.running)
        window?.show(orbits: Config.orbits, jobs: jobs.running, failed: jobs.failures, error: Config.error,
                     update: updateState)
        showUpdate()
        if !entries.contains(where: \.isActive) {
            menuBar?.remove()
            menuBar = nil
            return
        }
        if menuBar == nil { menuBar = MenuBar { [weak self] in self?.perform($0) } }
        menuBar?.show(entries, update: updateState)
    }

    /// A task's progress moved on (its whole percentage or its step), so only the badges change, and whoever
    /// follows over the socket hears of it.
    private func progressed() {
        link?.publish()
        menuBar?.render()
        window?.showProgress(jobs: jobs.running)
    }

    private func showWindow() {
        if window == nil { window = Window { [weak self] in self?.perform($0) } }
        window?.show(orbits: Config.orbits, jobs: jobs.running, failed: jobs.failures, error: Config.error,
                     update: updateState)
        window?.present()
    }

    /// The New Orbit sheet, or Edit Orbit when `editing` is an id. Saving writes orbits.json, shows the change at
    /// once and creates or renames the launcher.
    @objc private func newOrbit() { openSheet(editing: nil) }

    private func openSheet(editing id: String?) {
        if window == nil { showWindow() }
        guard sheet == nil else { window?.present(); return }
        let orbit = id.flatMap(Config.orbit)
        let sheet = NewOrbit(editing: orbit, running: id.map { jobs[$0] != nil } ?? false) { [weak self] in self?.perform($0) }
        self.sheet = sheet
        window?.begin(sheet)
    }

    /// Orbit is in the Dock and ⌘-Tab only while one of its windows is open. With none open, it quits once idle.
    private func windowsChanged() {
        NSApp.setInDock(window != nil || settings != nil)
        quitIfIdle()
    }

    @objc private func showSettings() {
        if settings == nil {
            settings = Settings(updatesAvailable: updater.available) { [weak self] in self?.perform($0) }
        }
        showUpdate()
        settings?.present()
    }

    /// The menus a regular app has while one of its windows is open.
    private func mainMenu() -> NSMenu {
        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        if updater.available {
            app.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Orbit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Orbit…", action: #selector(newOrbit), keyEquivalent: "n").target = self
        file.addItem(withTitle: "Open Configuration File", action: #selector(openConfiguration), keyEquivalent: "").target = self
        file.addItem(withTitle: "Export Configuration…", action: #selector(exportConfiguration), keyEquivalent: "").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        // The standard Edit menu. Its key equivalents are what make ⌘C, ⌘V, ⌘Z and the rest work in every text
        // field: with no target, each goes to whatever is being edited. macOS adds its own items below these.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
            .keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let bar = NSMenu()
        for (title, menu) in [("Orbit", app), ("File", file), ("Edit", edit)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            bar.addItem(item)
        }
        return bar
    }

    @objc private func openConfiguration() { Config.edit() }

    @objc private func exportConfiguration() {
        if let window = NSApp.mainWindow ?? NSApp.keyWindow { Config.export(on: window) }
    }

    /// Refreshes the update section of Settings.
    private func showUpdate() {
        settings?.show(update: updateState, activity: updateActivity, idle: jobs.running.isEmpty)
    }

    /// Check for Updates, from Settings or the Orbit menu (which opens Settings). Checks now whatever the mode and
    /// shows progress and the result in Settings. In Manually mode it only checks, and Settings then offers
    /// Download and Install. Otherwise it also downloads, and Settings offers Restart to Update.
    @objc private func checkForUpdates() {
        showSettings()
        guard updateActivity != .checking, updateActivity != .downloading else { return }   // one check at a time
        updateActivity = .checking
        showUpdate()
        updater.onBuilding = { [weak self] in self?.updateActivity = .downloading; self?.showUpdate() }
        if updater.building { updateActivity = .downloading; showUpdate() }      // joining one already downloading
        let report: @MainActor @Sendable (Updater.Check) -> Void = { [weak self] check in
            guard let self else { return }
            self.updater.onBuilding = nil
            self.updateActivity = switch check {
            case .done, .available: .upToDate                 // shown only when no newer version is known
            case .offline: .offline
            case .failed: .failed
            }
            self.showUpdate()
        }
        if Updater.mode == .manual { updater.check(then: report) } else { updater.prepare(then: report) }
    }
}

extension Agent: NSMenuItemValidation {
    /// Export Configuration… needs a file to export.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(exportConfiguration) || Config.exists
    }
}
