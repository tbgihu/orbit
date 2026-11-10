import AppKit

/// The `orbit` command, for people, scripts and AI agents. It decides nothing itself: what it shows is the
/// agent's `Snapshot`, and what it does is ask the agent for an `Action` the way a launcher does, then follow the
/// snapshots until the action is done. With no agent nothing runs, so it reads the state itself the same way.
@MainActor
enum CLI {
    /// The exit statuses. Errors go to stderr as `orbit: <message>`.
    enum Exit: Int32 {
        case ok = 0
        /// The orbit failed or was stopped while it started, or a change to orbits.json was refused.
        case failed = 1
        case usage = 2
        /// No orbit has that id or name, or two do.
        case notFound = 3
        /// orbits.json is missing or has a problem.
        case config = 4
        /// Still starting when the wait ended.
        case timedOut = 5
        /// Orbit itself could not be started or stopped answering.
        case unreachable = 6
    }

    private struct Failure: Error {
        let exit: Exit
        let message: String
    }

    /// Each command's arguments and what it does: the help, and the usage shown for a mistake.
    private static let commands: [(name: String, arguments: String, summary: String)] =
        [("list", "[<state>]", "every orbit and its state, or those in one state, like running or failed"),
         ("status", "<orbit>", "one orbit in detail")]
        + Action.allCases.map { ($0.rawValue, "<orbit>", $0.summary) }
        + [("open", "<orbit> [<address>]", "open where it answers: a web page, Screen Sharing or a terminal"),
           ("output", "<orbit>", "show its output in a terminal window that keeps following"),
           ("logs", "<orbit> [-f] [-n <lines>]", "its latest output; -f keeps following"),
           ("add", "<name> <options>", "add an orbit to orbits.json"),
           ("edit", "<orbit> <options>", "change an orbit; what isn't given stays"),
           ("rename", "<orbit> <new name>", "rename it; its launcher, log and history follow"),
           ("delete", "<orbit> [--yes] [--dry-run]", "remove an orbit that isn't running; asks first unless --yes, --dry-run only checks"),
           ("check", "[<file>]", "validate orbits.json, or another file")]
        + Request.allCases.map { ($0.rawValue, "", $0.summary) }
        + [("help", "[<command>]", "this, or one command's usage")]

    /// The options of `add` and `edit`, named like the keys of orbits.json.
    private static let keys = ["command", "script", "url", "cwd", "badge", "kind", "animate", "openInBrowser"]

    private static let options = """
        <options> of add and edit are named like the keys of orbits.json:
          --command <command> or --script <file> (add needs one), --url <addresses>, --cwd <folder>,
          --badge <abc | symbol:<name> | cards:<text> (or card, pill, disc, file)>,
          --kind <service | task | auto>, --animate <auto | starting | always | off>,
          --openInBrowser <true | false>, and for edit --name <name>. An empty value takes a key out again.
          --dry-run checks and prints the entry without saving.
        """

    private static func usage(_ name: String) -> String? {
        commands.first { $0.name == name }.map {
            "usage: orbit \($0.name) \($0.arguments)".trimmed + "\n       \($0.summary)"
                + (["add", "edit"].contains(name) ? "\n\n" + options : "")
        }
    }

    private static var help: String {
        let width = commands.map { $0.name.count + $0.arguments.count }.max()! + 3
        let lines = commands.map { ("  \($0.name) \($0.arguments)").padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.summary }
        return """
            usage: orbit <command> [--json]

            \(lines.joined(separator: "\n"))

            <orbit> is an orbit's id (web) or its name in any case ("web preview").
            <state> is \(Report.State.allCases.map(\.rawValue).joined(separator: ", ")).
            --json prints JSON instead of text.

            \(options)

            Exit status: 0 done, 1 the orbit failed or the change was refused, 2 usage, 3 no such orbit,
            4 orbits.json missing or invalid, 5 still starting after \(Int(Job.window)) s, 6 Orbit could not be reached.
            """
    }

    static func run(_ arguments: [String]) -> Int32 {
        var words = arguments.filter { $0 != "--json" }
        let json = words.count < arguments.count
        if let flag = words.firstIndex(where: { $0 == "--help" || $0 == "-h" }) {     // `orbit start --help`
            words.remove(at: flag)
            words = ["help"] + words.prefix(1)
        }
        do {
            guard let command = words.first else { throw Failure(exit: .usage, message: help) }
            try run(command, Array(words.dropFirst()), json: json)
            return Exit.ok.rawValue
        } catch let failure as Failure {
            let isUsage = failure.message.hasPrefix("usage:")
            FileHandle.standardError.write(Data(((isUsage ? "" : "orbit: ") + failure.message + "\n").utf8))
            return failure.exit.rawValue
        } catch {
            FileHandle.standardError.write(Data("orbit: \(Config.describe(error))\n".utf8))
            return Exit.failed.rawValue
        }
    }

    /// What `orbit check` prints with `--json`.
    struct Check: Codable {
        let file: String
        let valid: Bool
        var problem: String?
    }

    /// What `orbit logs` prints with `--json`.
    struct Logs: Codable {
        let log: String
        let lines: [String]
    }

    private static func run(_ command: String, _ arguments: [String], json: Bool) throws {
        let mistake = Failure(exit: .usage, message: usage(command) ?? "\"\(command)\" is not an orbit command (see `orbit help`)")
        switch (command, arguments.count) {
        case ("list", 0...1):
            var snapshot = state().snapshot
            if let word = arguments.first {
                guard let state = Report.State(rawValue: word) else { throw mistake }
                snapshot.orbits.removeAll { $0.state != state }
            }
            print(snapshot, json: json) { table(snapshot) }
            if let problem = snapshot.problem { throw Failure(exit: .config, message: problem) }
        case ("status", 1):
            let orbit = try find(arguments[0], in: state().snapshot)
            print(orbit, json: json) {
                (["\(orbit.name) (\(orbit.id))", "  state    \(orbit.status)"] + (orbit.progress.map { ["  progress \($0)"] } ?? [])
                    + orbit.addresses.map { "  address  \($0)" }
                    + ["  kind     \(orbit.kind.rawValue)", "  log      \(orbit.log)"]).joined(separator: "\n")
            }
        case ("open", 1...2):
            let orbit = try find(arguments[0], in: state().snapshot)
            guard orbit.isActive else { throw Failure(exit: .failed, message: orbit.sentence) }
            let addresses = orbit.addresses.compactMap { URL(string: $0).flatMap(Address.init) }.filter { $0.opener != nil }
            guard let address = arguments.count == 1 ? addresses.first : addresses.first(where: { $0.named(arguments[1]) }) else {
                throw Failure(exit: .failed, message: addresses.isEmpty ? "\(orbit.name) has no address to open"
                    : "\(orbit.name) answers at \(addresses.map(\.hostname).joined(separator: ", ")), not at \(arguments[1])")
            }
            guard address.open() else { throw Failure(exit: .failed, message: "\(address.url.absoluteString) could not be opened") }
            print(orbit, json: json) { "Opened \(address.url.absoluteString)" }
        case ("output", 1):
            let orbit = try find(arguments[0], in: state().snapshot)
            guard Link.awaited({ Runtime.showOutput(orbit.name, then: $0) }) else {
                throw Failure(exit: .failed, message: "no terminal opened \(orbit.log)")
            }
            print(orbit, json: json) { orbit.log }
        case ("logs", 1...):
            try logs(arguments, json: json)
        case ("add", 1...), ("edit", 1...):
            var words = arguments
            let adding = command == "add", dry = take("--dry-run", from: &words)
            let given = try options(&words, adding ? keys : ["name"] + keys) ?? { throw mistake }()
            guard words.count == 1 else { throw mistake }
            guard adding || !given.isEmpty else { throw Failure(exit: .usage, message: "nothing to change: give edit an option, see orbit edit --help") }
            var draft = Config.Draft(), editing: String?
            if adding {
                draft.name = words[0]
            } else {
                Config.reload()
                editing = try find(words[0], in: Snapshot()).id
                draft = Config.orbit(editing!).map(Config.Draft.init) ?? draft
            }
            guard apply(given, to: &draft) else { throw mistake }
            let saved = try Config.save(draft, editing: editing, check: dry)
            if dry {
                let entry = try JSONSerialization.jsonObject(with: Data(saved.entry.utf8))
                let shown = try JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                Swift.print(String(decoding: shown, as: UTF8.self))
            } else {
                let orbit = try current(saved.id)
                print(orbit, json: json) { adding ? "Added \(orbit.name) (\(orbit.id))" : "Saved \(orbit.name)" }
            }
        case ("rename", 2):
            Config.reload()
            let orbit = try find(arguments[0], in: Snapshot())
            try Config.rename(orbit.id, to: arguments[1])
            let renamed = try current(orbit.id)
            print(renamed, json: json) { "\(orbit.name) is now \(renamed.name)" }
        case ("delete", 1...3):
            var words = arguments
            let yes = take("--yes", from: &words), dry = take("--dry-run", from: &words)
            guard words.count == 1 else { throw mistake }
            Config.reload()
            let orbit = try find(words[0], in: Snapshot())
            try Config.delete(orbit.id, check: true)                   // refused before anyone is asked
            if !yes, !dry {
                guard isatty(STDIN_FILENO) == 1 else {
                    throw Failure(exit: .usage, message: "delete asks first, and there is nobody to ask here: add --yes")
                }
                FileHandle.standardError.write(Data("Delete \(orbit.name) (\(orbit.id)) from orbits.json? [y/N] ".utf8))
                guard ["y", "yes"].contains(readLine()?.trimmed.lowercased() ?? "") else {
                    throw Failure(exit: .failed, message: "\(orbit.name) was kept")
                }
            }
            if !dry {
                try Config.delete(orbit.id)
                _ = state()                                            // an open window shows it at once
            }
            print(orbit, json: json) { dry ? "\(orbit.name) can be deleted" : "Deleted \(orbit.name)" }
        case ("check", 0...1):
            let file = arguments.first.map { URL(filePath: $0) } ?? Config.file
            do {
                let count = try Config.load(file).count
                print(Check(file: file.path, valid: true), json: json) { "\(file.path): \(count) \(count == 1 ? "orbit" : "orbits"), no problems" }
            } catch {
                let problem = Config.describe(error)
                if json { print(Check(file: file.path, valid: false, problem: problem), json: true) { "" } }
                throw Failure(exit: .config, message: "\(file.lastPathComponent): \(problem)")
            }
        case ("help", 0): Swift.print(help)
        case ("help", 1) where usage(arguments[0]) != nil: Swift.print(usage(arguments[0])!)
        case ("--version", 0):
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            Swift.print("orbit \(version) (\(Build[.commit] ?? "unbundled"))")
        case ("internal", 1...):
            guard let helper = Internal(rawValue: arguments[0]), try helper.run(Array(arguments.dropFirst())) else { throw mistake }
        case (_, 0):
            guard let request = Request(rawValue: command) else { throw mistake }
            try ask(request, json: json)
        case (_, 1):
            guard let action = Action(rawValue: command) else { throw mistake }
            try act(action, arguments[0], json: json)
        default:
            throw mistake
        }
    }

    // MARK: State

    /// Every orbit as it stands, from the agent if one runs, and the connection it came over. Asking has a
    /// running agent read orbits.json again.
    private static func state() -> (snapshot: Snapshot, agent: Link.Connection?) {
        if let agent = Link.Connection() {
            agent.send()
            if let snapshot = agent.next(until: Date().addingTimeInterval(10)) { return (snapshot, agent) }
        }
        Config.reload()
        return (Snapshot(), nil)
    }

    /// The orbit with that id, or else that name in any case. A word that is one orbit's id and another's name
    /// is refused rather than guessed at.
    private static func find(_ word: String, in snapshot: Snapshot) throws -> Report {
        let matches = snapshot.orbits.filter { $0.id == word || $0.name.lowercased() == word.lowercased() }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty, let problem = snapshot.problem { throw Failure(exit: .config, message: problem) }
        throw Failure(exit: .notFound, message: matches.isEmpty
            ? "there is no orbit \"\(word)\" (`orbit list` shows them)"
            : "\"\(word)\" could be " + matches.map { "\($0.name) (\($0.id))" }.joined(separator: " or ") + ": use the other one's id or name")
    }

    /// The orbit with that id as it stands now, after orbits.json was changed here.
    private static func current(_ id: String) throws -> Report {
        guard let orbit = state().snapshot.orbits.first(where: { $0.id == id }) else {
            throw Failure(exit: .notFound, message: "there is no orbit \"\(id)\" (`orbit list` shows them)")
        }
        return orbit
    }

    /// The orbits in columns: id, name, state.
    private static func table(_ snapshot: Snapshot) -> String {
        let width = snapshot.orbits.map(\.name.count).max() ?? 0
        return snapshot.orbits.map {
            $0.id.padding(toLength: 6, withPad: " ", startingAt: 0)
                + $0.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.status
        }.joined(separator: "\n")
    }

    // MARK: Changes

    /// Takes a flag out of the words; whether it was there.
    private static func take(_ flag: String, from words: inout [String]) -> Bool {
        let count = words.count
        words.removeAll { $0 == flag }
        return words.count < count
    }

    /// Takes the `--key value` options out of the words. Nil when one isn't among `keys` or has no value.
    private static func options(_ words: inout [String], _ keys: [String]) -> [String: String]? {
        var given: [String: String] = [:]
        while let index = words.firstIndex(where: { $0.hasPrefix("--") }) {
            let key = String(words[index].dropFirst(2))
            guard keys.contains(key), index + 1 < words.count else { return nil }
            given[key] = words[index + 1]
            words.removeSubrange(index...index + 1)
        }
        return given
    }

    /// Sets what the options give; the rest of the draft stays. A file or folder given relative to where the
    /// command runs is written in full, since an orbit runs elsewhere. False when a value isn't one of its kind.
    private static func apply(_ given: [String: String], to draft: inout Config.Draft) -> Bool {
        let path = { (value: String) in
            value.isEmpty || value.hasPrefix("/") || value.hasPrefix("~") ? value : URL(filePath: value).standardizedFileURL.path
        }
        for (key, value) in given {
            switch key {
            case "name": draft.name = value
            case "command": (draft.command, draft.script) = (value, given["script"] ?? "")
            case "script": (draft.script, draft.command) = (path(value), given["command"] ?? "")
            case "url": draft.url = value
            case "cwd": draft.cwd = path(value)
            case "badge": draft.badge = value.isEmpty ? nil : Glyph.Content(key: value)
            case "kind":
                draft.kind = OrbitSpec.Kind(rawValue: value)
                guard draft.kind != nil || ["", "auto"].contains(value) else { return false }
            case "animate":
                draft.animate = OrbitSpec.Animate(rawValue: value)
                guard draft.animate != nil || value.isEmpty else { return false }
            case "openInBrowser":
                guard let opens = ["": true, "true": true, "false": false][value] else { return false }
                draft.openInBrowser = opens
            default: return false
            }
        }
        return true
    }

    // MARK: Actions

    /// How an action went, once the orbit's state shows it; nil while it is still under way. `asked` is when it
    /// was requested, which tells a run or an end it caused from an earlier one. An orbit without an address
    /// counts as running the moment it starts, so it is given a second (`settle`) in which a command that fails
    /// at once still shows as failed.
    private static func verdict(_ action: Action, _ orbit: Report, asked: Date) -> Exit? {
        let caused = (orbit.isActive ? orbit.since : orbit.ended).map { $0 >= asked } ?? false
        switch action {
        case .dismiss: return .ok
        case .stop: return orbit.isActive ? nil : .ok
        case .start, .restart, .toggle:
            switch orbit.state {
            case .starting: return nil
            case .running: return caused ? (settled(orbit) ? .ok : nil) : action == .start ? .ok : nil   // to be stopped first
            case .failed: return caused ? .failed : nil
            case .stopped:                                             // a toggle's end, a restart's middle
                return !caused || action == .restart ? nil : action == .toggle ? .ok : .failed     // a start someone else stopped
            case .done, .new: return caused ? .ok : nil                // not begun yet, else over already
            }
        }
    }

    /// How a request went, once the state shows it. `sent` says whether the agent has it yet.
    private static func verdict(_ request: Request, _ snapshot: Snapshot, sent: Bool) -> Exit? {
        switch request {
        case .stopAll: snapshot.orbits.contains(where: \.isActive) ? nil : .ok
        case .window, .settings: sent ? .ok : nil
        }
    }

    private static let settle: TimeInterval = 1

    private static func settled(_ orbit: Report) -> Bool {
        !orbit.addresses.isEmpty || orbit.since.map { $0.timeIntervalSinceNow <= -settle } ?? true
    }

    /// Sends the agent a request, starting it if there is something to do, and follows the state until `verdict`
    /// says how it went or the wait is over, which is as long as Orbit itself looks for a starting orbit's
    /// addresses. Returns the state at the end.
    private static func follow(_ request: URL, from start: (snapshot: Snapshot, agent: Link.Connection?),
                               verdict: (Snapshot, _ sent: Bool) throws -> Exit?) throws -> (Snapshot, Exit) {
        var (snapshot, agent) = start
        var exit = agent == nil ? try verdict(snapshot, false) : nil     // with no agent nothing runs
        if let agent {
            agent.send(request)
        } else if exit == nil {
            agent = Link.launch(request) ? Link.Connection.awaited() : nil
            agent?.send()
        }
        let deadline = Date().addingTimeInterval(Job.window)
        while exit == nil {
            guard let agent, !agent.closed else {                        // no agent, no runs: the records say how it went
                Config.reload()
                snapshot = Snapshot()
                guard let over = try verdict(snapshot, true) else {
                    throw Failure(exit: .unreachable, message: "Orbit quit before this was done")
                }
                return (snapshot, over)
            }
            if let next = agent.next(until: min(Date().addingTimeInterval(settle), deadline)) {
                snapshot = next
            } else if agent.closed {
                continue
            } else if Date() >= deadline {
                return (snapshot, .timedOut)
            }
            exit = try verdict(snapshot, true)
        }
        return (snapshot, exit!)
    }

    /// Asks the agent for an action on an orbit and reports the orbit once the action is done.
    private static func act(_ action: Action, _ word: String, json: Bool) throws {
        let asked = Date().addingTimeInterval(-0.002)                    // dates cross the socket in milliseconds
        let start = state()
        var orbit = try find(word, in: start.snapshot)
        let (_, exit) = try follow(action.url(orbit.id), from: start) { snapshot, _ in
            guard let current = snapshot.orbits.first(where: { $0.id == orbit.id }) else {
                // gone from the file; if it ran until now, it was removed while running and has just ended
                throw Failure(exit: orbit.isActive ? .ok : .notFound, message: "\(orbit.name) is no longer in orbits.json")
            }
            orbit = current
            return verdict(action, orbit, asked: asked)
        }
        print(orbit, json: json) { exit == .ok ? orbit.sentence : "" }
        if exit != .ok { throw Failure(exit: exit, message: orbit.sentence) }
    }

    /// Asks the agent for something that is not about one orbit and reports every orbit once it is done.
    private static func ask(_ request: Request, json: Bool) throws {
        let (snapshot, exit) = try follow(request.url, from: state()) { verdict(request, $0, sent: $1) }
        print(snapshot, json: json) { request == .stopAll ? table(snapshot) : "" }
        if exit != .ok { throw Failure(exit: exit, message: "not done after \(Int(Job.window)) s") }
    }

    // MARK: Output

    /// `orbit logs <orbit> [-f] [-n <lines>]`: `tail` does the work, or with `--json` the lines are read here.
    private static func logs(_ arguments: [String], json: Bool) throws {
        var words = arguments, follow = false, count = 100
        if let flag = words.firstIndex(of: "-f") { words.remove(at: flag); follow = true }
        if let flag = words.firstIndex(of: "-n"), flag + 1 < words.count, let lines = Int(words[flag + 1]), lines >= 0 {
            words.removeSubrange(flag...flag + 1)
            count = lines
        }
        guard words.count == 1, !(json && follow) else { throw Failure(exit: .usage, message: usage("logs")!) }
        let orbit = try find(words[0], in: state().snapshot)
        if json {
            let text = (try? String(decoding: Data(contentsOf: URL(filePath: orbit.log)), as: UTF8.self)) ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") || text.isEmpty ? 1 : 0)
            print(Logs(log: orbit.log, lines: lines.suffix(count).map(String.init)), json: true) { "" }
        } else if follow || FileManager.default.fileExists(atPath: orbit.log) {
            let argv = (["tail", "-n", String(count)] + (follow ? ["-F"] : []) + [orbit.log]).map { strdup($0) } + [nil]
            execv("/usr/bin/tail", argv)
        }
    }

    /// Prints `value` as JSON, or else `text`, unless it is empty.
    private static func print(_ value: some Encodable, json: Bool, text: () -> String) {
        let output = json ? String(decoding: Snapshot.encode(value, pretty: true), as: UTF8.self) : text()
        if !output.isEmpty { Swift.print(output) }
    }
}

/// Orbit's own helpers, which the agent and the install scripts run as `orbit internal <helper>`. They are not
/// commands for people, so help doesn't list them.
@MainActor
enum Internal: String {
    /// `watchdog <pid>` blocks until that process (the agent) ends, then stops the orbits it left.
    case watchdog
    /// `sync` creates or removes the Spotlight launchers to match orbits.json (installed Orbit only).
    case sync
    /// `icon <text:… | symbol:… | cards:…> <out.icns>` draws an icon; build.sh makes Orbit's own with it.
    case icon

    nonisolated func arguments(_ rest: String...) -> [String] { ["internal", rawValue] + rest }

    /// False when the arguments don't fit.
    func run(_ arguments: [String]) throws -> Bool {
        switch (self, arguments.count) {
        case (.watchdog, 1):
            guard let pid = pid_t(arguments[0]) else { return false }
            Runtime.waitForExit(of: [pid], until: .distantFuture)
            Runtime.reapOrphans()
        case (.sync, 0):
            // a missing file means no orbits; an unreadable one says nothing about them, so it throws and the
            // launchers stay
            let orbits: [OrbitSpec]
            do { orbits = try Config.load(Config.file) } catch CocoaError.fileReadNoSuchFile { orbits = [] }
            Launchers.sync(orbits)
        case (.icon, 2):
            try Glyph.writeICNS(Glyph.Content(key: arguments[0]), to: URL(filePath: arguments[1]))
        default:
            return false
        }
        return true
    }
}
