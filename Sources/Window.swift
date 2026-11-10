import AppKit

/// The window shown when Orbit is opened directly. It lists every orbit: click to start or stop, drag to reorder
/// (the menu bar follows), right-click to edit or rename. A config problem shows below the list and opens the file.
/// The title bar has + for New Orbit.
@MainActor
final class Window: NSObject, NSWindowDelegate {
    private let perform: (Command) -> Void
    private let window: NSWindow
    private let stack = NSStackView()
    private let list: OrbitList
    private let problem = Row()
    private let titleBar = NSTitlebarAccessoryViewController()
    private var shownError: String??

    init(perform: @escaping (Command) -> Void) {
        self.perform = perform
        list = OrbitList(perform: perform)
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: true)
        super.init()
        window.title = "Orbit"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self

        problem.action = { perform(.editConfig) }
        stack.setViews([list, problem], in: .top)
        stack.orientation = .vertical
        stack.spacing = OrbitList.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        let guide = window.contentLayoutGuide as! NSLayoutGuide          // the area below the title bar
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            stack.widthAnchor.constraint(equalToConstant: 284),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor),
            problem.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        // + at the trailing end of the title bar
        newButton.toolTip = "New Orbit"
        newButton.setAccessibilityLabel("New Orbit")
        for button in [newButton] {
            if #available(macOS 26, *) { button.bezelStyle = .glass } else { button.bezelStyle = .rounded }
            button.controlSize = .regular
        }
        if #available(macOS 26, *) {
            newButton.borderShape = .circle
        }
        let buttons = NSStackView(views: [newButton])
        buttons.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        titleBar.view = buttons
        titleBar.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(titleBar)
        fitTitleBar()
    }

    private lazy var newButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Orbit")!,
                                          target: self, action: #selector(newOrbit))

    private func fitTitleBar() {
        titleBar.view.frame.size = NSSize(width: titleBar.view.fittingSize.width, height: 28)
    }

    @objc private func newOrbit() { perform(.newOrbit) }

    /// Shows the New Orbit sheet on this window.
    func begin(_ sheet: NewOrbit) {
        present()
        sheet.begin(on: window)
    }

    func present() { window.present() }

    /// `failed` are the orbits whose failure the menu bar shows.
    func show(orbits: [OrbitSpec], jobs: [String: Job], failed: Set<String>, error: String?) {
        let resized = list.show(orbits, jobs: jobs, failed: failed)
        if shownError != .some(error) {
            shownError = .some(error)
            problem.isHidden = error == nil
            if let error {
                problem.show(symbol: "exclamationmark.triangle", title: orbits.isEmpty ? "Add Orbits" : "Check Orbits",
                             detail: error, help: "Opens orbits.json")
            }
            window.fitToContent(animate: window.isVisible)
        } else if resized {
            window.fitToContent(animate: window.isVisible)
        }
    }

    /// A task's progress moved on: redraws only the badges.
    func showProgress(jobs: [String: Job]) { list.showProgress(jobs) }

    func windowDidBecomeKey(_ notification: Notification) { perform(.reload) }

    func windowWillClose(_ notification: Notification) { perform(.windowClosed) }
}

/// The orbits, one row each. A click toggles one. A drag lifts the row and it follows the pointer within the list;
/// the others slide aside as soon as its centre enters their slot, and it settles into place on release. It all
/// happens inside this view, with no drag session or pasteboard, so nothing can leave the window.
@MainActor
private final class OrbitList: NSView {
    static let rowHeight: CGFloat = 44, spacing: CGFloat = 2

    private let perform: (Command) -> Void
    private var ids: [String] = []
    private var rows: [String: Row] = [:]
    private var specs: [String: OrbitSpec] = [:]
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)

    /// The pressed row, where it was grabbed, whether it moved far enough to be a drag, and the order before.
    private struct Drag { let id: String; let grab: CGFloat; let start: NSPoint; var lifted = false; let before: [String] }
    private var drag: Drag?
    /// The orbit whose name is being edited in place.
    private var editing: String?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The list takes every click itself (rows only draw and hover), except inside a name being edited.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        if let editing, let row = rows[editing], row.frame.contains(convert(point, from: superview)) {
            return super.hitTest(point) ?? self
        }
        return self
    }

    /// Right-click: Edit…, Rename…, Show Output.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.y / (Self.rowHeight + Self.spacing))
        guard drag == nil, editing == nil, ids.indices.contains(index) else { return nil }
        let menu = NSMenu()
        for (title, selector) in [("Edit…", #selector(edit(_:))), ("Rename…", #selector(rename(_:))),
                                  ("Show Output", #selector(showLog(_:)))] {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = ids[index]
        }
        return menu
    }

    @objc private func edit(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform(.editOrbit(id))
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let row = rows[id] else { return }
        editing = id
        row.beginEditing { [weak self] name in
            self?.editing = nil
            if let name { self?.rename(id, to: name) }
        }
    }

    /// Changes only the name in orbits.json; the launcher and the log follow. On failure the row keeps its old
    /// name and an alert explains why.
    private func rename(_ id: String, to name: String) {
        do {
            try Config.rename(id, to: name)
        } catch {
            if let window {
                let alert = NSAlert()
                alert.messageText = "“\(name)” can’t be used"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
        perform(.reload)
    }

    @objc private func showLog(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform(.showOutput(id))
    }

    init(perform: @escaping (Command) -> Void) {
        self.perform = perform
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        height.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows `orbits` in order with their state; true when the list's height changed.
    func show(_ orbits: [OrbitSpec], jobs: [String: Job], failed: Set<String>) -> Bool {
        specs = Dictionary(orbits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = orbits.map(\.id)
        if newIDs != ids, drag == nil {
            for (id, row) in rows where specs[id] == nil { row.removeFromSuperview(); rows[id] = nil }
            for id in newIDs where rows[id] == nil {
                let row = Row()
                row.setAccessibilityCustomActions([
                    NSAccessibilityCustomAction(name: "Move Up") { [weak self] in self?.move(id, by: -1) ?? false },
                    NSAccessibilityCustomAction(name: "Move Down") { [weak self] in self?.move(id, by: 1) ?? false },
                ])
                row.action = { [weak self] in self?.perform(.orbit(.toggle, id)) }
                rows[id] = row
                addSubview(row)
            }
            ids = newIDs
            needsLayout = true
        }
        for (id, row) in rows { if let spec = specs[id] { row.show(spec, jobs[id], failed: failed.contains(id)) } }
        let total = max(0, CGFloat(ids.count) * (Self.rowHeight + Self.spacing) - Self.spacing)
        isHidden = ids.isEmpty
        guard height.constant != total else { return false }
        height.constant = total
        return true
    }

    func showProgress(_ jobs: [String: Job]) {
        for (id, row) in rows { if let job = jobs[id] { row.showBadge(job) } }
    }

    private func slot(_ index: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(index) * (Self.rowHeight + Self.spacing), width: bounds.width, height: Self.rowHeight)
    }

    override func layout() {
        super.layout()
        for (index, id) in ids.enumerated() {
            if id == drag?.id, drag?.lifted == true { rows[id]?.frame.size.width = bounds.width } else { rows[id]?.frame = slot(index) }
        }
    }

    /// Slides every row but the dragged one to its slot.
    private func settle(except dragged: String?) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            for (index, id) in ids.enumerated() where id != dragged { rows[id]?.animator().frame = slot(index) }
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if editing != nil { window?.makeFirstResponder(nil); return }     // a click elsewhere ends the edit
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.y / (Self.rowHeight + Self.spacing))
        guard ids.indices.contains(index), slot(index).contains(point) else { return }
        drag = Drag(id: ids[index], grab: point.y - slot(index).minY, start: point, before: ids)
        rows[ids[index]]?.pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag, let row = rows[drag.id] else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !drag.lifted {
            guard hypot(point.x - drag.start.x, point.y - drag.start.y) >= 3 else { return }   // still a click
            drag.lifted = true
            row.pressed = false
            row.lifted = true
            addSubview(row, positioned: .above, relativeTo: nil)
        }
        let last = CGFloat(ids.count - 1) * (Self.rowHeight + Self.spacing)
        row.frame.origin.y = min(max(point.y - drag.grab, 0), last)
        let target = min(max(Int((row.frame.midY) / (Self.rowHeight + Self.spacing)), 0), ids.count - 1)
        if let current = ids.firstIndex(of: drag.id), current != target {
            ids.insert(ids.remove(at: current), at: target)
            settle(except: drag.id)
        }
        self.drag = drag
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag, let row = rows[drag.id] else { return }
        self.drag = nil
        row.pressed = false
        guard drag.lifted else {
            if row.frame.contains(convert(event.locationInWindow, from: nil)) { perform(.orbit(.toggle, drag.id)) }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            row.animator().frame = slot(ids.firstIndex(of: drag.id) ?? 0)
        }, completionHandler: { MainActor.assumeIsolated { row.lifted = false } })
        if ids != drag.before { perform(.reorder(ids)) }
    }

    /// VoiceOver's Move Up / Move Down.
    private func move(_ id: String, by offset: Int) -> Bool {
        guard drag == nil, let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return false }
        ids.swapAt(index, index + offset)
        settle(except: nil)
        perform(.reorder(ids))
        return true
    }
}

/// A row with an icon, a title and a status line. Highlighted on hover and press, raised while dragged.
/// Outside the list (the problem row) a click runs `action`.
@MainActor
private final class Row: NSView, NSTextFieldDelegate {
    var action: (() -> Void)?
    var pressed = false { didSet { needsDisplay = true } }
    var lifted = false {
        didSet {
            needsDisplay = true
            shadow = lifted ? { let s = NSShadow(); s.shadowBlurRadius = 10; s.shadowOffset = NSSize(width: 0, height: -2)
                                s.shadowColor = .black.withAlphaComponent(0.22); return s }() : nil
        }
    }

    private let icon = NSImageView()
    private let badge = BadgeView()
    private var orbit: OrbitSpec?
    private let title = NSTextField(labelWithString: "")
    private lazy var editWidth = title.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
    /// Set while the name is being edited. Called with the new name, or nil when cancelled.
    private var edited: ((String?) -> Void)?
    private var cancelling = false
    private let detail = NSTextField(labelWithString: "")
    private var hovered = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 284, height: OrbitList.rowHeight))
        wantsLayer = true
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        title.lineBreakMode = .byTruncatingTail                       // the tooltip has the full name
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        icon.imageScaling = .scaleProportionallyUpOrDown
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let line = NSStackView(views: [icon, badge, text])
        line.spacing = 10
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows an orbit's badge as the menu bar does (faint when it shows none), and its state.
    func show(_ orbit: OrbitSpec, _ job: Job?, failed alert: Bool) {
        self.orbit = orbit
        let status = RunStatus(orbit, job), failed = status.isFailure
        icon.isHidden = true
        badge.isHidden = false
        badge.show(Glyph.Badge(orbit, job: job, failed: alert), tint: job == nil && !alert ? .tertiaryLabelColor : .labelColor)
        detail.textColor = failed ? .systemRed : .secondaryLabelColor
        set(title: edited == nil ? orbit.name : title.stringValue, detail: status.text(.window),
            help: job == nil ? "Starts \(orbit.name)" : "Stops \(orbit.name)")
        toolTip = failed ? "Output: \(Runtime.logFile(orbit.name).abbreviatingTilde)" : nil
    }

    func showBadge(_ job: Job) {
        if let orbit { badge.show(Glyph.Badge(orbit, job: job, failed: false), tint: .labelColor) }
    }

    func show(symbol: String, title: String, detail: String, help: String) {
        badge.isHidden = true
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = .secondaryLabelColor
        set(title: title, detail: detail, help: help)
    }

    private func set(title: String, detail: String, help: String) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        toolTip = "\(title)\n\(detail)"
        setAccessibilityLabel("\(title), \(detail)")
        setAccessibilityHelp(help)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        if lifted {
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
        }
        guard lifted || hovered || pressed else { return }
        (pressed ? NSColor.tertiarySystemFill : NSColor.quaternarySystemFill).setFill()
        shape.fill()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { pressed = true }

    // MARK: Renaming in place, as in Finder (Return or a click elsewhere saves, Escape cancels)

    func beginEditing(_ done: @escaping (String?) -> Void) {
        edited = done
        title.isEditable = true
        title.isSelectable = true
        title.drawsBackground = true
        title.backgroundColor = .textBackgroundColor
        title.delegate = self
        editWidth.isActive = true
        window?.makeFirstResponder(title)
        title.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): cancelling = true
        case #selector(NSResponder.insertNewline(_:)): break
        default: return false
        }
        window?.makeFirstResponder(nil)                                   // ends editing, which calls controlTextDidEndEditing
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let done = edited else { return }
        let name = cancelling ? nil : title.stringValue
        edited = nil
        cancelling = false
        title.isEditable = false
        title.isSelectable = false
        title.drawsBackground = false
        editWidth.isActive = false
        done(name)
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        if pressed, bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { action?(); return true }
}

extension NSWindow {
    /// Brings the window to the front, centred when it first opens. Orbit shows in the Dock and ⌘-Tab meanwhile.
    func present() {
        NSApp.setInDock(true)
        if !isVisible { center() }
        makeKeyAndOrderFront(nil)
        NSApp.bringToFront()
    }

    /// Resizes the window to fit its content, keeping the top edge in place.
    func fitToContent(animate: Bool = false) {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        var fitted = frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
        fitted.origin = NSPoint(x: frame.minX, y: frame.maxY - fitted.height)
        setFrame(fitted, display: true, animate: animate)
    }
}

extension NSApplication {
    /// In the Dock and ⌘-Tab only while one of Orbit's windows is open.
    func setInDock(_ shown: Bool) { setActivationPolicy(shown ? .regular : .accessory) }

    /// Brings Orbit's windows to the front when they were asked for (opening Orbit or Settings). The cooperative
    /// `activate()` is refused when Orbit was launched by a process that isn't frontmost (a Spotlight launcher),
    /// leaving the window behind.
    /// `activate(ignoringOtherApps:)` still works and has no replacement for this case. Calling it through a
    /// protocol keeps the build free of its deprecation warning.
    func bringToFront() { (self as any ForcedActivation).activate(ignoringOtherApps: true) }
}

@MainActor private protocol ForcedActivation { func activate(ignoringOtherApps: Bool) }
extension NSApplication: ForcedActivation {}
