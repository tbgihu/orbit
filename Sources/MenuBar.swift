import AppKit

/// An orbit in the menu: running, failed (until dismissed), or idle. Active entries get a badge and an open section.
@MainActor
enum Entry {
    case running(Job)
    case failed(OrbitSpec)
    case idle(OrbitSpec)

    var spec: OrbitSpec {
        switch self {
        case .running(let job): job.spec
        case .failed(let spec), .idle(let spec): spec
        }
    }

    var isActive: Bool { if case .idle = self { false } else { true } }
}

/// Orbit's single menu bar item, as the HIG asks: the badges side by side, and one menu with a collapsible
/// section per orbit.
///
/// Each badge is `Glyph.Badge(_:job:failed:)`, as in the window (by default a task's satellite circles, like Time
/// Machine's icon during a backup). A failed run shows "!" until dismissed or run again. Reduce Motion stops the
/// turning but not the progress.
@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private let perform: (Command) -> Void

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var entries: [Entry] = []
    private var update = UpdateState.none
    /// Open sections, reset to the active orbits whenever that set changes.
    private var expanded = Set<String>()
    private var expandedFor: [String] = []
    /// The badges the strip image was last drawn for (`Badge.inStrip`), to skip needless redraws.
    private var drawn: [Glyph.Badge]?

    init(perform: @escaping (Command) -> Void) {
        self.perform = perform
        super.init()
        item.autosaveName = "orbit"                 // keeps a ⌘-dragged position across runs
        item.isVisible = true
        item.button?.setAccessibilityLabel("Orbit")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    /// Reduce Motion changed, so start or stop the turning right away.
    @objc private func displayOptionsChanged() { render() }

    /// Shows every orbit in display order, active ones open. `update` is a prepared update to restart into.
    func show(_ entries: [Entry], update: UpdateState) {
        self.entries = entries
        self.update = update
        let active = entries.filter(\.isActive).map(\.spec.id)
        if active != expandedFor {
            expandedFor = active
            expanded = Set(active)
        }
        item.button?.toolTip = entries.compactMap { entry in
            switch entry {
            case .failed: "\(current(entry.spec).name) failed"
            case .running: current(entry.spec).name
            case .idle: nil
            }
        }.joined(separator: ", ")
        render()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    /// When every badge is hidden, an empty ring keeps the menu reachable. Failures are never hidden.
    func render() {
        let hidden = Defaults.hiddenInMenuBar
        let badges: [Glyph.Badge] = entries.compactMap { entry in
            let spec = current(entry.spec)
            switch entry {
            case .failed: return Glyph.Badge(spec, job: nil, failed: true)
            case .running(let job) where !hidden.contains(spec.id): return Glyph.Badge(spec, job: job, failed: false)
            case .running, .idle: return nil
            }
        }
        show(badges.isEmpty ? [Glyph.Badge(content: .text(""), label: "Orbit")] : badges)
    }

    /// Draws the badges as one still template image, with a Ring view over each turning or filling badge that Core
    /// Animation rotates without redrawing the image. Each orbit keeps its own Ring, by name, so a change to another
    /// badge never restarts its turning. Nothing turns with Reduce Motion.
    private func show(_ badges: [Glyph.Badge]) {
        guard let button = item.button else { return }
        let badges = badges.map(\.shown)
        let strip = badges.map(\.inStrip)
        if strip != drawn {
            drawn = strip
            button.image = Glyph.strip(badges)
        }
        let width = Glyph.cell(badges.count - 1).maxX
        var rings = Dictionary(button.subviews.compactMap { $0 as? Ring }.map { ($0.identifier, $0) }) { first, _ in first }
        for (index, badge) in badges.enumerated() where badge.ringApart {
            let id = NSUserInterfaceItemIdentifier(badge.label)
            let ring = rings.removeValue(forKey: id) ?? ring(in: button, id)
            let offset = Glyph.cell(index).midX - width / 2
            if ring.offset?.constant != offset { ring.offset?.constant = offset }
            ring.show(.init(dimmed: badge.dimmed, turn: badge.turn, progress: badge.progress))
        }
        rings.values.forEach { $0.removeFromSuperview() }
    }

    /// A Ring over the button for the badge labelled `id`, drawn by its cell so it gets the same tint, placed by its
    /// offset from the centre.
    private func ring(in button: NSStatusBarButton, _ id: NSUserInterfaceItemIdentifier) -> Ring {
        let ring = Ring(frame: NSRect(x: 0, y: 0, width: Glyph.side, height: Glyph.side))
        ring.identifier = id
        ring.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(ring)
        ring.offset = ring.centerXAnchor.constraint(equalTo: button.centerXAnchor)
        NSLayoutConstraint.activate([
            ring.offset!, ring.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: Glyph.side), ring.heightAnchor.constraint(equalToConstant: Glyph.side),
        ])
        return ring
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        perform(.reload)                                              // pick up config edits before the menu opens
        menu.removeAllItems()
        for (index, entry) in entries.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            let spec = current(entry.spec)
            var items: [NSMenuItem] = []
            switch entry {
            case .running(let job):
                let hidden = Defaults.hiddenInMenuBar.contains(spec.id)
                items.append(status(RunStatus(job.spec, job).text(.menu)))
                items += addressItems(job.addresses, spec.id)
                items.append(action("Show Output", symbol: "terminal", #selector(showLog), spec.id))
                items.append(hidden
                             ? action("Show in Menu Bar", symbol: "eye", #selector(toggleHidden), spec.id)
                             : action("Hide from Menu Bar", symbol: "eye.slash", #selector(toggleHidden), spec.id))
                items.append(action("Stop Process", symbol: "stop.circle", #selector(stopProcess), spec.id))
            case .failed:
                items.append(status(RunStatus(spec, nil).text(.menu)))
                items.append(action("Show Output", symbol: "terminal", #selector(showLog), spec.id))
                items.append(action("Run Again", symbol: "arrow.clockwise", #selector(runAgain), spec.id))
                items.append(action("Dismiss", symbol: "xmark.circle", #selector(dismiss), spec.id))
            case .idle:
                items.append(status(RunStatus(spec, nil).text(.menu)))
                items.append(action("Start", symbol: "play.circle", #selector(runAgain), spec.id))
                if FileManager.default.fileExists(atPath: Runtime.logFile(spec.name)) {
                    items.append(action("Show Output", symbol: "terminal", #selector(showLog), spec.id))
                }
            }

            let open = expanded.contains(spec.id)
            items.forEach { $0.isHidden = !open }
            let header = NSMenuItem()
            header.view = SectionHeader(title: spec.name, expanded: open) { [weak self] header in
                guard let self else { return }
                let open = !self.expanded.contains(spec.id)
                if open { self.expanded.insert(spec.id) } else { self.expanded.remove(spec.id) }
                header.expanded = open
                items.forEach { $0.isHidden = !open }
            }
            menu.addItem(header)
            items.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        menu.addItem(action("Open Orbit", symbol: "macwindow", #selector(openWindow), nil))
        menu.addItem(action("Settings…", symbol: "gearshape", #selector(openSettings), nil))
        if entries.filter({ if case .running = $0 { true } else { false } }).count > 1 {
            menu.addItem(action("Stop All", symbol: "stop.circle.fill", #selector(stopAll), nil))
        }
        if update != .none {
            menu.addItem(.separator())
            let title = update.title
            let item = action(title, symbol: "arrow.triangle.2.circlepath", #selector(restartToUpdate), nil)
            item.isEnabled = update.actionable
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = action("Quit Orbit", symbol: "power", #selector(quitOrbit), nil)
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    @objc private func quitOrbit(_ sender: NSMenuItem) { perform(.quit) }

    /// The orbit as configured now, so a rename or new badge shows even while an earlier run goes on.
    private func current(_ spec: OrbitSpec) -> OrbitSpec {
        Config.orbit(spec.id) ?? spec
    }

    private func status(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    @objc private func openAddress(_ sender: NSMenuItem) { address(sender)?.open() }

    @objc private func copyAddress(_ sender: NSMenuItem) {
        guard let host = address(sender)?.hostname else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(host, forType: .string)
    }

    /// Open and Copy for an orbit's addresses, as for one address. With several, each item gets a submenu of
    /// them by hostname. Its title is the one they share, else "Open" or "Copy Address" (mixed kinds); each entry
    /// still opens its own way. Plain tcp addresses have no Open.
    private func addressItems(_ addresses: [Address], _ id: String) -> [NSMenuItem] {
        let all = Array(addresses.enumerated()), openable = all.filter { $0.element.opener != nil }
        let opens = Set(openable.compactMap { $0.element.opener?.title }), copies = Set(all.map(\.element.copyTitle))
        let open = opens.count == 1 ? openable[0].element.opener! : (title: "Open", symbol: "arrow.up.forward.app")
        return [
            choice(open.title, symbol: open.symbol, #selector(openAddress), id, openable),
            choice(copies.count == 1 ? copies.first! : "Copy Address", symbol: "doc.on.doc", #selector(copyAddress), id, all),
        ].compactMap { $0 }
    }

    /// An item for one address (its index as tag), or with a submenu choosing among several.
    private func choice(_ title: String, symbol: String, _ selector: Selector, _ id: String,
                        _ addresses: [(offset: Int, element: Address)]) -> NSMenuItem? {
        guard let first = addresses.first else { return nil }
        let item = action(title, symbol: symbol, selector, id)
        item.tag = first.offset
        guard addresses.count > 1 else { return item }
        item.action = nil                                     // AppKit then has it open the submenu
        item.submenu = NSMenu()
        for (index, address) in addresses {               // each opens its own way, but all copy alike
            let icon = selector == #selector(openAddress) ? address.opener?.symbol ?? symbol : symbol
            let entry = action(address.hostname, symbol: icon, selector, id)
            entry.tag = index
            item.submenu?.addItem(entry)
        }
        return item
    }

    /// The address an Open or Copy item stands for: its tag indexes the orbit's addresses.
    private func address(_ sender: NSMenuItem) -> Address? {
        for case .running(let job) in entries where job.spec.id == sender.representedObject as? String {
            return job.addresses.indices.contains(sender.tag) ? job.addresses[sender.tag] : nil
        }
        return nil
    }

    @objc private func toggleHidden(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if Defaults.hiddenInMenuBar.remove(id) == nil { Defaults.hiddenInMenuBar.insert(id) }
        render()
    }

    @objc private func stopProcess(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform(.orbit(.stop, id))
    }

    @objc private func showLog(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform(.showOutput(id))
    }

    @objc private func runAgain(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform(.orbit(.start, id))
    }

    @objc private func dismiss(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform(.orbit(.dismiss, id))
    }

    @objc private func stopAll(_ sender: NSMenuItem) { perform(.app(.stopAll)) }

    @objc private func openWindow(_ sender: NSMenuItem) { perform(.app(.window)) }

    @objc private func openSettings(_ sender: NSMenuItem) { perform(.app(.settings)) }

    @objc private func restartToUpdate(_ sender: NSMenuItem) { perform(.update) }

    private func action(_ title: String, symbol: String, _ selector: Selector, _ id: String?) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = id
        menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return menuItem
    }
}

/// A section header that opens and closes its section without closing the menu, like "Other Networks" in the
/// Wi-Fi menu, with a trailing chevron and a hover highlight.
@MainActor
private final class SectionHeader: NSView {
    var expanded: Bool { didSet { update() } }

    private let toggle: (SectionHeader) -> Void
    private let title: NSTextField
    private let chevron = NSImageView()
    private var hovered = false { didSet { needsDisplay = true } }

    init(title: String, expanded: Bool, toggle: @escaping (SectionHeader) -> Void) {
        self.expanded = expanded
        self.toggle = toggle
        self.title = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        autoresizingMask = .width

        self.title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        self.title.textColor = .secondaryLabelColor
        self.title.lineBreakMode = .byTruncatingTail
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = .secondaryLabelColor
        for view in [self.title, chevron] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            self.title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            self.title.centerYAnchor.constraint(equalTo: centerYAnchor),
            self.title.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(title)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        setAccessibilityValue(expanded ? 1 : 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.quaternarySystemFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { toggle(self) }
    override func accessibilityPerformPress() -> Bool { toggle(self); return true }
}
