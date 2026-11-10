import AppKit

/// The New Orbit sheet, also used as Edit Orbit with the fields filled in and Save instead of Add. Name and what
/// runs are required. The other fields are optional.
@MainActor
final class NewOrbit: NSObject, NSTextFieldDelegate {
    private let perform: (Command) -> Void

    private let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    private let name = NewOrbit.field("Required")
    private let run = NSSegmentedControl(labels: ["Command", "Script"], trackingMode: .selectOne, target: nil, action: nil)
    private let runValue = NewOrbit.field("Required")
    private let url = NewOrbit.field("Automatic")
    private let folder = NewOrbit.field("Optional")
    private let badgeKind = NSPopUpButton()
    private let badgeValue = NewOrbit.field("")
    private let preview = NSImageView()
    /// Wide enough for the badge text: a few characters, or a longer symbol name.
    private lazy var badgeWidth = badgeValue.widthAnchor.constraint(equalToConstant: 80)
    private let kind = NSPopUpButton()
    private let animate = NSPopUpButton()
    private let opens = NSButton(checkboxWithTitle: "Open web page when ready", target: nil, action: nil)
    private lazy var chooseScript = NSButton(title: "Choose…", target: self, action: #selector(pickScript))
    private lazy var add = NSButton(title: "Add", target: self, action: #selector(confirm))

    private static let badges: [(title: String, shape: Glyph.Shape?)] =
        [("Initials", nil), ("Text", nil), ("Symbol", nil), ("Cards", .cards), ("Card", .card), ("Pill", .pill), ("Disc", .disc), ("File", .file)]

    /// The orbit being edited, or nil for a new one. When `running`, changes apply from its next start.
    private let editing: OrbitSpec?
    private let running: Bool

    init(editing: OrbitSpec? = nil, running: Bool = false, perform: @escaping (Command) -> Void) {
        self.editing = editing
        self.running = running
        self.perform = perform
        super.init()
        panel.title = editing == nil ? "New Orbit" : "Edit Orbit"
        add.title = editing == nil ? "Add" : "Save"
        run.selectedSegment = 0
        opens.state = .on
        run.target = self
        run.action = #selector(changed)
        badgeKind.addItems(withTitles: Self.badges.map(\.title))
        badgeKind.target = self
        badgeKind.action = #selector(changed)
        kind.addItems(withTitles: ["Auto", "Service", "Task"])
        animate.addItems(withTitles: ["Auto", "Starting only", "Always", "Off"])
        for field in [name, runValue, badgeValue] { field.delegate = self }
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.contentTintColor = .labelColor

        let chooseFolder = NSButton(title: "Choose…", target: self, action: #selector(pickFolder))
        let grid = NSGridView(views: [
            [label("Name"), name, NSGridCell.emptyContentView],
            [label("Runs"), row(run, runValue, chooseScript), NSGridCell.emptyContentView],
            [label("URL"), url, info("The address this orbit answers at. Left empty, Orbit finds the ports a service listens on.\nSet it to pick a page or port, e.g. http://localhost:8080/docs or vnc://localhost:5901.\nThe orbit shows as starting until the address answers; the menu then offers Open and Copy.")],
            [NSGridCell.emptyContentView, row(opens), info("If this orbit serves a web page, it opens in your browser as soon as it answers.")],
            [label("Run folder"), row(folder, chooseFolder), info("The folder this orbit runs in, where its relative paths start.\nLeft empty, a script runs in its own folder and a command in your home folder.")],
            [label("Badge"), row(badgeKind, badgeValue, preview), NSGridCell.emptyContentView],
            [label("Kind"), row(kind), info("Service: runs until stopped.\nTask: runs to completion.\nAuto: Orbit decides from earlier runs, the command and the URL.")],
            [label("Animation"), row(animate), info("How the badge's satellite moves.\nAuto: while starting, and while a task runs.\nStarting only: until the URL answers.\nAlways: also while a service runs.\nOff: never.")],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 380
        grid.column(at: 1).xPlacement = .fill
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(dismiss))
        cancel.keyEquivalent = "\u{1b}"
        add.keyEquivalent = "\r"                                           // the default button
        let buttons = NSStackView(views: [cancel, add])
        buttons.spacing = 12

        let content = NSView()
        for view in [grid, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        panel.contentView = content
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            cancel.widthAnchor.constraint(equalTo: add.widthAnchor),
            add.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            preview.widthAnchor.constraint(equalToConstant: 22), preview.heightAnchor.constraint(equalToConstant: 22),
            badgeWidth,
        ] + [badgeKind, kind, animate].map { $0.widthAnchor.constraint(equalToConstant: 130) })
        if let editing { fill(editing) }
        changed()
    }

    private func fill(_ orbit: OrbitSpec) {
        name.stringValue = orbit.name
        run.selectedSegment = orbit.script == nil ? 0 : 1
        runValue.stringValue = orbit.script ?? orbit.command ?? ""
        url.stringValue = orbit.url ?? ""
        folder.stringValue = orbit.cwd ?? ""
        switch orbit.badge {
        case nil:
            badgeKind.selectItem(at: 0)
        case .text(let text)?:
            badgeKind.selectItem(at: 1)
            badgeValue.stringValue = text
        case .symbol(let name)?:
            badgeKind.selectItem(at: 2)
            badgeValue.stringValue = name
        case .shape(let shape, let text)?:
            badgeKind.selectItem(at: Self.badges.firstIndex { $0.shape == shape } ?? 0)
            badgeValue.stringValue = text
        }
        kind.selectItem(at: [nil, OrbitSpec.Kind.service, .task].firstIndex(of: orbit.kind) ?? 0)
        opens.state = orbit.opensInBrowser ? .on : .off
        let animation: OrbitSpec.Animate? = orbit.animate == .auto ? nil : orbit.animate
        animate.selectItem(at: [nil, OrbitSpec.Animate.starting, .always, .off].firstIndex(of: animation) ?? 0)
    }

    func begin(on window: NSWindow) {
        window.beginSheet(panel)
        panel.makeFirstResponder(name)
    }

    // MARK: Fields

    private static func field(_ placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)   // fields take the row's free width
        return field
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 6
        return stack
    }

    /// An ⓘ button that shows `text` in a popover.
    private func info(_ text: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About this field")!,
                              target: self, action: #selector(showInfo(_:)))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = text
        button.setAccessibilityHelp(text)
        return button
    }

    @objc private func showInfo(_ sender: NSButton) {
        let text = NSTextField(wrappingLabelWithString: sender.toolTip ?? "")
        text.preferredMaxLayoutWidth = 260
        let content = NSStackView(views: [text])
        content.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let controller = NSViewController()
        controller.view = content
        content.layoutSubtreeIfNeeded()
        controller.preferredContentSize = content.fittingSize          // a stack view has no size of its own
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }

    /// How many characters the selected badge type holds. Symbol names can be long.
    private var badgeLimit: Int {
        let choice = badgeKind.indexOfSelectedItem
        return choice == 1 ? Glyph.Content.textLimit : choice == 2 ? 100 : Self.badges[choice].shape?.limit ?? 100
    }

    /// Refuses input past a field's limit with a beep: 100 characters for names, the badge type's limit for badges.
    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField {
            let limit = field === name ? 100 : field === badgeValue ? badgeLimit : Int.max
            if field.stringValue.count > limit {
                field.stringValue = String(field.stringValue.prefix(limit))
                NSSound.beep()
            }
        }
        changed()
    }

    /// Updates the script picker, the badge field and preview, and enables Add once the required fields are filled.
    @objc private func changed() {
        let script = run.selectedSegment == 1
        chooseScript.isHidden = !script
        runValue.placeholderString = "Required"
        // the placeholder shows the default: the script's folder once a path is given, else home
        let scriptFolder = (runValue.stringValue.trimmingCharacters(in: .whitespaces) as NSString).deletingLastPathComponent
        folder.placeholderString = !script ? "~" : scriptFolder.isEmpty ? "The script's folder" : scriptFolder

        let choice = badgeKind.indexOfSelectedItem
        badgeValue.isHidden = choice == 0
        badgeValue.placeholderString = ["", "e.g. 25m", "e.g. globe", "e.g. L", "e.g. WEB", "e.g. API", "e.g. DB", "e.g. D"][choice]
        badgeWidth.constant = choice == 2 ? 200 : 80
        if badgeValue.stringValue.count > badgeLimit { badgeValue.stringValue = String(badgeValue.stringValue.prefix(badgeLimit)) }
        let content = badge() ?? .text(editing?.id ?? Config.newID(for: name.stringValue, taken: []))   // editing keeps its id
        preview.image = content.problem == nil ? Glyph.strip([.init(content: content, label: "")]) : nil

        add.isEnabled = !name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
            && !runValue.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func badge() -> Glyph.Content? {
        let value = badgeValue.stringValue.trimmingCharacters(in: .whitespaces)
        switch badgeKind.indexOfSelectedItem {
        case 0: return nil
        case 1: return .text(value)
        case 2: return .symbol(value)
        case let index: return Self.badges[index].shape.map { .shape($0, value) }
        }
    }

    @objc private func pickScript() { pick(folders: false) { self.runValue.stringValue = $0; self.changed() } }
    @objc private func pickFolder() { pick(folders: true) { self.folder.stringValue = $0 } }

    private func pick(folders: Bool, _ done: @escaping (String) -> Void) {
        let open = NSOpenPanel()
        open.canChooseFiles = !folders
        open.canChooseDirectories = folders
        open.beginSheetModal(for: panel) { response in
            guard response == .OK, let url = open.url else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            done(url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path)
        }
    }

    // MARK: Buttons

    @objc private func confirm() {
        var draft = Config.Draft()
        draft.name = name.stringValue
        if run.selectedSegment == 1 { draft.script = runValue.stringValue } else { draft.command = runValue.stringValue }
        draft.url = url.stringValue
        draft.openInBrowser = opens.state == .on
        draft.cwd = folder.stringValue
        draft.badge = badge()
        draft.kind = [nil, .service, .task][kind.indexOfSelectedItem]
        draft.animate = [nil, .starting, .always, .off][animate.indexOfSelectedItem]
        do { try Config.save(draft, editing: editing?.id, check: true) } catch { return fail(error) }

        // Confirm what will run and where before saving. When editing, only if that changed.
        if let editing, draft.command.trimmed == (editing.command ?? "").trimmed,
           draft.script.trimmed == (editing.script ?? "").trimmed, draft.cwd.trimmed == (editing.cwd ?? "").trimmed {
            return save(draft)
        }
        let verb = editing == nil ? "Add" : "Save"
        let alert = NSAlert()
        (alert.messageText, alert.informativeText) = draft.question(verb, running: running)
        let command = NSTextField(wrappingLabelWithString: draft.runs)
        command.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        command.isSelectable = true
        command.preferredMaxLayoutWidth = 260
        command.frame.size = command.fittingSize
        alert.accessoryView = command
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn else { return }
                self.save(draft)
            }
        }
    }

    private func save(_ draft: Config.Draft) {
        do { try Config.save(draft, editing: editing?.id) } catch { return fail(error) }
        perform(.reload)                                                 // shown at once; the launcher follows
        dismiss()
    }

    private func fail(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = editing == nil ? "The orbit can’t be added" : "The changes can’t be saved"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: panel)
    }

    @objc private func dismiss() {
        panel.sheetParent?.endSheet(panel)
        perform(.sheetClosed)
    }
}
