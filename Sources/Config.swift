import AppKit

/// One orbit: an entry of `~/.config/orbit/orbits.json` (documented by `orbits.schema.json`).
struct OrbitSpec: Decodable, Sendable {
    /// Up to 4 letters or digits. Everything Orbit keeps of an orbit goes by it (`Config.reconcile`), and it is
    /// the default badge.
    let id: String
    /// What you type in Spotlight; the launcher app's name.
    let name: String
    /// What the ring shows: text, an SF Symbol, or a shape with text. Defaults to `id`.
    let badge: Glyph.Content?
    /// Run by zsh with the terminal's environment in its own process group, with output in `<name>.log`. Either
    /// this or `script`.
    let command: String?
    /// A script file anywhere (`~` expanded). Run directly when executable, otherwise with the interpreter named on
    /// its `#!` line, or `/bin/sh`. Either this or `command`.
    let script: String?
    /// Working directory, `~` expanded. Defaults to the script's folder, else the home folder.
    let cwd: String?
    /// Where it answers (http, https, vnc, ssh or tcp): one address, or several separated by commas. Used to
    /// check readiness and to open and copy them.
    let url: String?
    /// Whether it runs until stopped (`service`) or ends by itself (`task`). When unset, KindGuess decides.
    let kind: Kind?

    /// How the badge's satellite moves. `auto` circles while starting and while a task runs, `starting` only while
    /// starting, `always` also while a service runs, `off` never. Defaults to `auto`.
    let animate: Animate?

    /// Opens its web pages once in the browser as they answer, unless the command opened them first. Without a
    /// url, only addresses that serve HTML open. Off, the command can't open web pages either. Defaults to true.
    let openInBrowser: Bool?

    enum Kind: String, Codable, Sendable { case service, task }

    enum Animate: String, Decodable, CaseIterable, Sendable { case auto, starting, always, off }

    /// Whether it runs to completion rather than until stopped, from `kind` or else KindGuess.
    @MainActor var isTask: Bool { (kind ?? KindGuess.resolve(self)) == .task }

    /// The satellite circles while the URL has not responded yet.
    var circlesWhileStarting: Bool { (animate ?? .auto) != .off }

    /// The satellite circles while it runs: with `always`, or with `auto` for a task.
    @MainActor var circlesWhileRunning: Bool {
        switch animate ?? .auto {
        case .auto: isTask
        case .always: true
        case .starting, .off: false
        }
    }

    var mark: Glyph.Content { badge ?? .text(id) }

    var opensInBrowser: Bool { openInBrowser ?? true }

    /// `url`'s addresses, in order; none when it has no url (Config.load has checked them).
    var addresses: [Address] { url.flatMap(Address.list) ?? [] }

    /// Where it runs: `cwd`, else the script's folder, else home as in Terminal. An app would otherwise start in /.
    var directory: String {
        cwd.map(\.expandingTilde)
            ?? scriptPath.map { ($0 as NSString).deletingLastPathComponent }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    var scriptPath: String? { script.map(\.expandingTilde) }

    /// What it runs, as written: the command or the script.
    var runs: String { command ?? script ?? "" }

    /// What zsh runs.
    var shellLine: String {
        guard let path = scriptPath else { return command ?? "" }
        if FileManager.default.isExecutableFile(atPath: path) { return "exec \(shellQuoted(path))" }
        return "exec \(Self.interpreter(of: path)) \(shellQuoted(path))"
    }

    /// The `#!` line's interpreter (with its arguments, e.g. `/usr/bin/env bash`), else `/bin/sh`.
    private static func interpreter(of path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path), let head = try? handle.read(upToCount: 256),
              let line = String(decoding: head, as: UTF8.self).split(separator: "\n").first,
              line.hasPrefix("#!") else { return "/bin/sh" }
        let interpreter = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return interpreter.isEmpty ? "/bin/sh" : interpreter
    }
}

/// The orbits, read from the config file in the home folder, never from this repository or the app bundle.
@MainActor
enum Config {
    static let file = Build.path(.config)

    /// The orbits as last read, in the order set with `reorder`. When the file has an error, the last good list
    /// stays and `error` says what is wrong.
    private(set) static var orbits: [OrbitSpec] = []
    private(set) static var error: String?

    static func orbit(_ id: String) -> OrbitSpec? { orbits.first { $0.id == id } }

    /// Sets the order dragged in the window, by id. It is kept in defaults so orbits.json is never rewritten.
    /// Orbits it doesn't name yet follow in file order.
    static func reorder(_ ids: [String]) {
        Defaults.order = ids
        orbits = sorted(orbits)
    }

    private static func sorted(_ orbits: [OrbitSpec]) -> [OrbitSpec] {
        let order = Defaults.order
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return orbits.enumerated()
            .sorted { (rank[$0.element.id] ?? order.count + $0.offset, $0.offset) < (rank[$1.element.id] ?? order.count + $1.offset, $1.offset) }
            .map(\.element)
    }

    struct Invalid: LocalizedError, CustomStringConvertible {
        let description: String
        var errorDescription: String? { description }
    }

    /// orbits.json with no orbits yet.
    private static let emptyDocument = "{\n  \"orbits\": []\n}\n"

    /// Re-reads the file. At a few hundred bytes that is cheaper than watching it.
    static func reload() {
        do {
            orbits = sorted(try load(file))
            error = nil
            reconcile()
        } catch CocoaError.fileReadNoSuchFile {
            orbits = []
            error = "There is no \(file.path(percentEncoded: false)) yet."
        } catch {
            self.error = "\(file.lastPathComponent): \(describe(error))"
        }
    }

    /// Brings what Orbit keeps of each orbit in line with the file just read, by id: an id with another name is
    /// a rename (its log is renamed and its launcher replaced; order, last run and the rest stay), an id that is
    /// gone takes everything of its orbit with it, and a new id starts with nothing.
    /// It runs with every read and goes by what is on disk, so an edit made while Orbit ran, was quit or had
    /// crashed is treated the same, and renaming an orbit is nothing more than changing its name in the file.
    /// Not when the file has a problem, since it then says nothing about which orbits exist.
    private static func reconcile() {
        Defaults.prune(keeping: Set(orbits.map(\.id)))
        Runtime.reconcileLogs(orbits)
        Launchers.syncInBackground(orbits)
    }

    static func load(_ file: URL) throws -> [OrbitSpec] { try load(data: Data(contentsOf: file)) }

    static func load(data: Data) throws -> [OrbitSpec] {
        struct Document: Decodable { let orbits: [OrbitSpec] }
        let orbits = try JSONDecoder().decode(Document.self, from: data).orbits
        var ids = Set<String>(), names = Set<String>()
        for orbit in orbits {
            guard (1...4).contains(orbit.id.count), orbit.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            else { throw Invalid(description: "id \"\(orbit.id)\": use 1 to 4 letters or digits") }
            guard ids.insert(orbit.id).inserted else { throw Invalid(description: "id \"\(orbit.id)\" is used twice") }
            if let problem = nameProblem(orbit.name) { throw Invalid(description: problem) }
            guard names.insert(orbit.name.lowercased()).inserted
            else { throw Invalid(description: "name \"\(orbit.name)\" is used twice") }
            if let problem = orbit.mark.problem { throw Invalid(description: "\(orbit.name): \(problem)") }
            guard (orbit.command == nil) != (orbit.script == nil)
            else { throw Invalid(description: "\(orbit.name): give either \"command\" or \"script\"") }
            if let url = orbit.url, let problem = urlProblem(url) { throw Invalid(description: "\(orbit.name): \(problem)") }
        }
        return orbits
    }

    /// Why `name` can't be used for an orbit, or nil. The name becomes an app in ~/Applications/Orbit.
    static func nameProblem(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "A name cannot be empty." }
        if name != name.trimmingCharacters(in: .whitespaces) { return "A name cannot start or end with a space." }
        if name.contains("/") || name.contains(":") { return "A name cannot contain \"/\" or \":\"." }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "A name cannot contain line breaks or control characters."
        }
        if name.hasPrefix(".") { return "A name cannot start with \".\"." }
        if name.count > 100 { return "A name can have up to 100 characters." }
        if name.lowercased() == "orbit" { return "\"Orbit\" is Orbit's own name." }
        return nil
    }

    /// Why `url` can't be an orbit's addresses, or nil. http, https, vnc and ssh need a host; tcp needs a host
    /// and a port. Several are separated by commas.
    static func urlProblem(_ url: String) -> String? {
        guard Address.list(url) == nil else { return nil }
        return url.contains(",")
            ? "url must be full addresses separated by commas, e.g. http://localhost:3000, http://localhost:6006."
            : "url must be a full address, e.g. http://localhost:8080, vnc://localhost:5901 or tcp://localhost:6379."
    }

    /// Renames an orbit by changing only its "name" value in orbits.json, keeping the rest of the file as it is.
    /// Everything else follows by id when the file is read again (`reconcile`).
    static func rename(_ id: String, to newName: String) throws {
        reload()                                                       // pick up edits made since the last read
        let name = newName.trimmed
        guard error == nil, let orbit = orbit(id) else {
            throw Invalid(description: error ?? "This orbit is no longer in orbits.json.")
        }
        guard name != orbit.name else { return }
        if let problem = nameProblem(name) { throw Invalid(description: problem) }
        if orbits.contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) {
            throw Invalid(description: "Another orbit is already called \"\(name)\".")
        }

        var text = try String(contentsOf: file, encoding: .utf8)
        guard let entry = try? Layout(text).entry(id), let value = entry.value("name") else {
            throw Invalid(description: "Orbit couldn't find this orbit's name in orbits.json. Rename it there with File → Open Configuration File.")
        }
        text.replaceUTF8(value, with: literal(name))
        try text.write(to: file, atomically: true, encoding: .utf8)
        reload()
    }

    /// An orbit as entered in the form, or given to `orbit add` and `orbit edit`. Empty optional values are left
    /// out of orbits.json.
    struct Draft {
        var name = "", command = "", script = "", url = "", cwd = ""
        var badge: Glyph.Content?
        var kind: OrbitSpec.Kind?
        var animate: OrbitSpec.Animate?
        var openInBrowser = true

        init() {}

        /// An orbit as it is, to change.
        init(_ orbit: OrbitSpec) {
            (name, command, script) = (orbit.name, orbit.command ?? "", orbit.script ?? "")
            (url, cwd, badge) = (orbit.url ?? "", orbit.cwd ?? "", orbit.badge)
            (kind, animate, openInBrowser) = (orbit.kind, orbit.animate, orbit.opensInBrowser)
        }

        /// What it runs, as written.
        var runs: String { (script.trimmed.isEmpty ? command : script).trimmed }

        /// What to ask before it is saved, since it will run with the user's rights: `verb` is Add or Save.
        func question(_ verb: String, running: Bool) -> (title: String, detail: String) {
            let folder = cwd.trimmed.isEmpty ? (script.trimmed.isEmpty ? "your home folder" : "the script's folder") : cwd.trimmed
            return ("\(verb) “\(name.trimmed)”?",
                    "It will run as written below, with your permissions, in \(folder). Make sure it does what you intend."
                        + (running ? " It is running now, so the change applies from its next start." : ""))
        }
    }

    /// Adds an orbit at the end of "orbits", or with `editing` set, replaces that entry in place and keeps its id.
    /// The rest of the file is untouched. The resulting file is validated as a whole and nothing is written if
    /// anything is wrong. With `check` it stops before writing, so whoever asks can validate before asking for
    /// confirmation. Returns the orbit's id and its entry as written.
    @discardableResult
    static func save(_ draft: Draft, editing: String? = nil, check: Bool = false) throws -> (id: String, entry: String) {
        reload()
        let exists = Self.exists
        if exists, let error { throw Invalid(description: "orbits.json has a problem to fix first (File → Open Configuration File): \(error)") }

        let name = draft.name.trimmed, command = draft.command.trimmed, script = draft.script.trimmed
        let url = draft.url.trimmed, cwd = draft.cwd.trimmed
        if let problem = nameProblem(name) { throw Invalid(description: problem) }
        if let editing, orbit(editing) == nil {
            throw Invalid(description: "This orbit is no longer in orbits.json.")
        }
        if orbits.contains(where: { $0.id != editing && $0.name.lowercased() == name.lowercased() }) {
            throw Invalid(description: "Another orbit is already called \"\(name)\".")
        }
        guard command.isEmpty != script.isEmpty else { throw Invalid(description: "Give a command or a script.") }
        var isFolder: ObjCBool = false
        if !script.isEmpty, !FileManager.default.fileExists(atPath: script.expandingTilde, isDirectory: &isFolder) || isFolder.boolValue {
            throw Invalid(description: "There is no script at \(script).")
        }
        if !cwd.isEmpty, !(FileManager.default.fileExists(atPath: cwd.expandingTilde, isDirectory: &isFolder) && isFolder.boolValue) {
            throw Invalid(description: "There is no folder at \(cwd).")
        }
        if !url.isEmpty, let problem = urlProblem(url) {
            throw Invalid(description: problem)
        }
        if let problem = draft.badge?.problem { throw Invalid(description: problem.prefix(1).uppercased() + problem.dropFirst() + ".") }

        let id = editing ?? newID(for: name, taken: Set(orbits.map(\.id)))
        var fields: [(String, String)] = [("id", literal(id)), ("name", literal(name))]
        switch draft.badge {
        case .text(let text)?: fields.append(("badge", literal(text)))
        case .symbol(let symbol)?: fields.append(("badge", "{ \"symbol\": \(literal(symbol)) }"))
        case .shape(let shape, let text)?:
            fields.append(("badge", "{ \"shape\": \(literal(shape.rawValue)), \"text\": \(literal(text)) }"))
        case nil: break
        }
        fields.append(command.isEmpty ? ("script", literal(script)) : ("command", literal(command)))
        if let kind = draft.kind { fields.append(("kind", literal(kind.rawValue))) }
        if let animate = draft.animate, animate != .auto { fields.append(("animate", literal(animate.rawValue))) }
        if !cwd.isEmpty { fields.append(("cwd", literal(cwd))) }
        if !url.isEmpty { fields.append(("url", literal(url))) }
        if !draft.openInBrowser { fields.append(("openInBrowser", "false")) }

        var text = exists ? try String(contentsOf: file, encoding: .utf8) : emptyDocument
        let entry = try write(fields, replacing: editing, into: &text)
        _ = try load(data: Data(text.utf8))                            // validate the whole result before writing
        if check { return (id, entry) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        reload()
        return (id, entry)
    }

    /// Removes an orbit's entry from orbits.json, keeping the rest of the file as it is. Its launcher, log and
    /// history go when the file is read again (`reconcile`). An orbit that runs is not removed: stop it first.
    /// With `check` it stops before writing, to ask for confirmation.
    static func delete(_ id: String, check: Bool = false) throws {
        reload()
        guard error == nil, let orbit = orbit(id) else {
            throw Invalid(description: error ?? "This orbit is no longer in orbits.json.")
        }
        if Runtime.recorded(id) { throw Invalid(description: "\(orbit.name) is running. Stop it first.") }
        var text = try String(contentsOf: file, encoding: .utf8)
        let layout = try Layout(text)
        guard let index = layout.index(of: id) else { throw Invalid(description: "This orbit could not be found in orbits.json.") }
        // with the comma that parts it from a neighbour; the last one leaves an empty list
        let entries = layout.entries, range = entries[index].range
        if entries.count == 1 {
            text.replaceUTF8(layout.open + 1..<layout.close, with: "")
        } else if index == 0 {
            text.replaceUTF8(range.lowerBound..<entries[1].range.lowerBound, with: "")
        } else {
            text.replaceUTF8(entries[index - 1].range.upperBound..<range.upperBound, with: "")
        }
        _ = try load(data: Data(text.utf8))
        if check { return }
        try text.write(to: file, atomically: true, encoding: .utf8)
        reload()
    }

    /// An id from the name's initials ("web preview" → "wp"), made unique with a digit when taken.
    static func newID(for name: String, taken: Set<String>) -> String {
        let words = name.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        var base = String(words.compactMap(\.first).prefix(4))
        if base.count < 2 { base = String(words.joined().prefix(4)) }
        if base.isEmpty { base = "o" }
        if !taken.contains(base) { return base }
        for digit in 2...999 {
            let candidate = String(base.prefix(4 - String(digit).count)) + String(digit)
            if !taken.contains(candidate) { return candidate }
        }
        return base
    }

    /// Writes an entry into the top-level "orbits" array, indented like its neighbours, and returns it. It replaces
    /// the entry with id `replacing`, or is appended. The rest of the text is unchanged.
    private static func write(_ fields: [(String, String)], replacing id: String?, into text: inout String) throws -> String {
        let layout = try Layout(text)
        let bytes = layout.bytes
        func indentation(before index: Int) -> String {
            var start = index
            while start > 0, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
            return String(decoding: bytes[start..<index].prefix { $0 == 32 || $0 == 9 }, as: UTF8.self)
        }
        let outer = indentation(before: layout.close)
        let element = layout.entries.first.map { indentation(before: $0.range.lowerBound) } ?? outer + "  "
        let step = String(repeating: " ", count: max(2, element.count - outer.count))   // the file's own indent step
        let body = fields.map { "\(element)\(step)\"\($0.0)\": \($0.1)" }.joined(separator: ",\n")
        let entry = "{\n\(body)\n\(element)}"

        if let id {                                                     // replace that entry where it stands
            guard let target = layout.entry(id) else { throw Invalid(description: "This orbit could not be found in orbits.json.") }
            text.replaceUTF8(target.range, with: entry)
        } else if let last = layout.entries.last {                      // after the last entry
            text.replaceUTF8(last.range.upperBound..<last.range.upperBound, with: ",\n\(element)\(entry)")
        } else {                                                        // an empty list
            text.replaceUTF8(layout.open + 1..<layout.close, with: "\n\(element)\(entry)\n\(outer)")
        }
        return entry
    }

    /// UTF-8 offsets in orbits.json of the top-level "orbits" array's brackets, each entry, and each value within
    /// an entry. Found by scanning the JSON (respecting strings and escapes) so the file can be edited in place
    /// without losing its layout.
    private struct Layout {
        struct Entry {
            var range: Range<Int>
            var values: [(key: String, range: Range<Int>)] = []

            func value(_ key: String) -> Range<Int>? { values.first { $0.key == key }?.range }
        }

        let bytes: [UInt8]
        let open: Int, close: Int
        let entries: [Entry]

        init(_ text: String) throws {
            let bytes = Array(text.utf8)
            var depth = 0, inString = false, escaped = false, stringStart = 0
            var lastKey: String?, open: Int?, close: Int?
            var entries: [Entry] = [], entry: Entry?
            var key: String?, value: (key: String, start: Int)?
            func endValue(at end: Int) {
                guard let started = value else { return }
                let isSpace = { (i: Int) in [32, 9, 10, 13].contains(bytes[i]) }
                var start = started.start, end = end
                while start < end, isSpace(start) { start += 1 }
                while end > start, isSpace(end - 1) { end -= 1 }
                entry?.values.append((started.key, start..<end))
                value = nil
            }
            for (i, byte) in bytes.enumerated() {
                if inString {
                    if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true }
                    else if byte == UInt8(ascii: "\"") {
                        inString = false
                        let string = String(decoding: bytes[stringStart..<i], as: UTF8.self)
                        if depth == 1 { lastKey = string }
                        if depth == 3 { key = string }
                    }
                    continue
                }
                let inArray = open != nil && close == nil
                switch byte {
                case UInt8(ascii: "\""): inString = true; stringStart = i + 1
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    if byte == UInt8(ascii: "["), depth == 1, lastKey == "orbits", open == nil { open = i }
                    if byte == UInt8(ascii: "{"), depth == 2, inArray { entry = Entry(range: i..<i) }
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    if depth == 3 { endValue(at: i) }
                    depth -= 1
                    if byte == UInt8(ascii: "}"), depth == 2, inArray, var done = entry {
                        done.range = done.range.lowerBound..<(i + 1)
                        entries.append(done)
                        entry = nil
                    }
                    if byte == UInt8(ascii: "]"), depth == 1, let open, close == nil, open < i { close = i }
                case UInt8(ascii: ":"): if depth == 3, entry != nil, let key { value = (key, i + 1) }
                case UInt8(ascii: ","):
                    if depth == 1 { lastKey = nil }
                    if depth == 3 { endValue(at: i) }
                default: break
                }
            }
            guard let open, let close else { throw Invalid(description: "orbits.json has no \"orbits\" list.") }
            (self.bytes, self.open, self.close, self.entries) = (bytes, open, close, entries)
        }

        /// Where the entry whose "id" is `id` is among the entries.
        func index(of id: String) -> Int? {
            entries.firstIndex { entry in
                entry.value("id").flatMap { range in
                    try? JSONSerialization.jsonObject(with: Data(bytes[range]), options: .fragmentsAllowed) as? String
                } == id
            }
        }

        func entry(_ id: String) -> Entry? { index(of: id).map { entries[$0] } }
    }

    /// `value` as a JSON string literal, quotes included.
    private static func literal(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\(value)\""
    }

    /// Opens the file in the app that edits JSON here (TextEdit when none does), creating it first if needed.
    static func edit() {
        if !exists {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(emptyDocument.utf8).write(to: file)
        }
        let editor = NSWorkspace.shared.urlForApplication(toOpen: file)
            ?? URL(filePath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// Export Configuration…: a save panel as a sheet on `window`, then a copy of the file where it says. `then`
    /// runs once the panel, and the alert if the copy failed, are closed.
    static func export(on window: NSWindow, then: @escaping @MainActor () -> Void = {}) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let destination = panel.url else { return then() }
                do {
                    try copy(to: destination)
                    then()
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window) { _ in MainActor.assumeIsolated(then) }
                }
            }
        }
    }

    /// Copies the file as it is, byte for byte, errors and all. The copy appears whole or not at all.
    static func copy(to destination: URL) throws {
        try Data(contentsOf: file).write(to: destination, options: .atomic)
    }

    /// A decoding error as a sentence saying where in the file it is and what went wrong.
    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context): return "\(path(context)) is missing \"\(key.stringValue)\""
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        default: return error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return path.isEmpty ? "the file" : String(path.drop { $0 == "." })
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A path with `~` expanded.
    var expandingTilde: String { (self as NSString).expandingTildeInPath }

    /// A path with the home folder as `~`, for people.
    var abbreviatingTilde: String { (self as NSString).abbreviatingWithTildeInPath }
}

private extension String {
    /// Replaces the text between two UTF-8 offsets.
    mutating func replaceUTF8(_ range: Range<Int>, with replacement: String) {
        let start = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
        replaceSubrange(start..<utf8.index(start, offsetBy: range.count), with: replacement)
    }
}
