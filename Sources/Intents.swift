import AppIntents
import AppKit
import os

/// Siri, Apple Intelligence, Shortcuts and Spotlight, through App Intents. macOS runs an intent inside Orbit.app,
/// starting it if need be. An intent that only looks (the orbits to choose from, a status) reads the agent's state
/// right here, the `Snapshot` the command line gets over the socket, so it answers at once and never waits on the
/// agent it runs in. One that does something runs the `orbit` command, so it can do nothing the command line can't,
/// and says nothing once done, as the menu bar shows the outcome and Siri confirms in its own words; when the
/// command fails, its message is the error. Nothing here runs until macOS asks.
/// Titles and descriptions are written for Apple Intelligence too, which goes by them to match a request.
///
/// The code is in every build, but macOS only runs the intents of one that has their metadata, which takes Xcode
/// to extract (scripts/build.sh), and a signature with a Team ID, which takes an Apple Development certificate
/// (`Build.siri`).
@MainActor
enum Intents {
    /// Intents being answered. Orbit stays until the last one is answered.
    private(set) static var pending = 0

    /// What the command said went wrong, which Siri says in turn.
    struct Failure: Error, CustomLocalizedStringResourceConvertible {
        let message: String
        var localizedStringResource: LocalizedStringResource { "\(message)" }

        init(_ message: String) { self.message = message }

        /// From what the command wrote as it failed: its own line, `orbit: <message>`, whatever else is there.
        init(said output: String) {
            let own = output.split(separator: "\n").last { $0.hasPrefix("orbit: ") }?.dropFirst(7)
            message = own.map(String.init) ?? output.trimmed
        }
    }

    /// Keeps Orbit running while an intent is answered.
    private static func answering<Value>(_ body: () async -> Value) async -> Value {
        let agent = NSApp.delegate as? Agent
        agent?.askedByIntent()
        pending += 1
        defer {
            pending -= 1
            agent?.quitIfIdle()
        }
        return await body()
    }

    /// Every orbit as the agent has it, as `orbit list --json` prints it, with the config read again first.
    static func snapshot() async throws -> Snapshot {
        guard let agent = NSApp.delegate as? Agent else { throw Failure("Orbit isn't running.") }
        return await answering { agent.snapshot() }
    }

    /// The orbits, all or those in one state, as `orbit list` finds them.
    static func orbits(_ state: Report.State? = nil) async throws -> [Report] {
        let snapshot = try await snapshot()
        if let problem = snapshot.problem { throw Failure(problem) }
        return snapshot.orbits.filter { state == nil || $0.state == state }
    }

    /// One orbit, as `orbit status` finds it.
    static func status(_ id: String) async throws -> Report {
        let snapshot = try await snapshot()
        guard let orbit = snapshot.orbits.first(where: { $0.id == id }) else {
            throw Failure(snapshot.problem ?? "there is no orbit \"\(id)\"")
        }
        return orbit
    }

    /// Runs `orbit <arguments> --json` and returns what it printed. When it fails, its message is the error.
    static func orbit<Output: Decodable & Sendable>(_ arguments: [String]) async throws -> Output {
        let (status, printed, message) = await run(arguments)
        guard status == 0, let output: Output = Snapshot.decode(printed) else {
            throw Failure(said: message)
        }
        return output
    }

    /// The longest a command may take: as long as it waits for an orbit to come up, and a little more.
    nonisolated static let timeout = Job.window + 10

    /// Runs `orbit <arguments> --json` on a thread of its own and returns its exit status, what it printed and what
    /// it said went wrong. A command still running after `timeout` is stopped, so an intent always answers.
    static func run(_ arguments: [String]) async -> (status: Int32, printed: Data, message: String) {
        await answering {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: command(arguments + ["--json"])) }
            }
        }
    }

    /// Runs this binary as the command line and waits for it, reading what it prints and says as it goes so a
    /// long answer never stalls it.
    private nonisolated static func command(_ arguments: [String]) -> (status: Int32, printed: Data, message: String) {
        let process = Process(), output = Pipe(), problem = Pipe()
        process.executableURL = Bundle.main.executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = problem
        guard (try? process.run()) != nil else { return (-1, Data(), "Orbit could not run its command.") }
        let pid = process.processIdentifier, late = OSAllocatedUnfairLock(initialState: false)
        let stop = DispatchWorkItem {                                  // its output then ends, and so do the reads
            late.withLock { $0 = true }
            kill(pid, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let said = OSAllocatedUnfairLock(initialState: Data()), heard = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let message = problem.fileHandleForReading.readDataToEndOfFile()
            said.withLock { $0 = message }
            heard.signal()
        }
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        heard.wait()
        process.waitUntilExit()
        stop.cancel()
        if late.withLock({ $0 }) { return (-1, Data(), "Orbit didn't answer within \(Int(timeout)) seconds.") }
        return (process.terminationStatus, printed, String(decoding: said.withLock { $0 }, as: UTF8.self))
    }

    /// An orbit as the command line reports it, with its badge as drawn on its launcher.
    static func entity(_ orbit: Report) -> OrbitEntity {
        let icon = Config.orbit(orbit.id).flatMap { Glyph.appIcon($0.mark, pixels: 128) }
        return OrbitEntity(orbit, badge: icon.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) })
    }

    /// Tells macOS which orbits there are, for phrases like "Start web preview in Orbit". Only when they or the
    /// build changed since it was last told, and only in a build with Siri support, since macOS runs no intents
    /// of any other (`Build.siri`).
    static func refresh(_ orbits: [OrbitSpec]) {
        guard Build.siri else { return }
        let listed = ([Build.identity] + orbits.map { "\($0.id) \($0.name)" }).joined(separator: "\n")
        guard Defaults.shortcuts != listed else { return }
        Defaults.shortcuts = listed
        OrbitShortcuts.updateAppShortcutParameters()
    }
}

// MARK: What an intent is given and gives back

extension Report.State: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Orbit State"
    static let caseDisplayRepresentations: [Report.State: DisplayRepresentation] = [
        .starting: "Starting", .running: "Running", .done: "Done", .failed: "Failed", .stopped: "Stopped", .new: "Not Run Yet",
    ]
}

extension OrbitSpec.Animate: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Badge Animation"
    static let caseDisplayRepresentations: [OrbitSpec.Animate: DisplayRepresentation] = [
        .auto: "Automatic", .starting: "Starting Only", .always: "Always", .off: "Off",
    ]
}

/// An orbit's kind, as `orbit add --kind` takes it. An orbit itself is always one of the two.
enum OrbitKind: String, AppEnum {
    case auto, service, task

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Orbit Kind"
    static let caseDisplayRepresentations: [OrbitKind: DisplayRepresentation] = [
        .auto: "Automatic", .service: "Service", .task: "Task",
    ]
}

/// An orbit, as Siri and Shortcuts see it: everything `orbit status` reports, as values a shortcut can use.
struct OrbitEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Orbit"
    static let defaultQuery = OrbitQuery()

    let id: String
    /// Its launcher's icon, as PNG.
    let badge: Data?
    @Property(title: "Name") var name: String
    @Property(title: "State") var state: Report.State
    /// Its state in the menu's words.
    @Property(title: "Status") var status: String
    @Property(title: "Running") var isRunning: Bool
    @Property(title: "Kind") var kind: OrbitKind
    @Property(title: "Addresses") var addresses: [String]
    @Property(title: "Started") var since: Date?
    @Property(title: "Ended") var ended: Date?
    @Property(title: "Exit Code") var exitCode: Int?
    @Property(title: "Progress Percent") var percent: Int?
    @Property(title: "Step") var step: Int?
    @Property(title: "Steps") var steps: Int?
    @Property(title: "Log File") var log: String

    init(_ orbit: Report, badge: Data?) {
        (id, self.badge) = (orbit.id, badge)
        (name, state, status, isRunning) = (orbit.name, orbit.state, orbit.status, orbit.isActive)
        (kind, addresses, log) = (orbit.kind == .task ? .task : .service, orbit.addresses, orbit.log)
        (since, ended, exitCode) = (orbit.since, orbit.ended, orbit.exitCode.map(Int.init))
        (percent, step, steps) = (orbit.percent, orbit.step, orbit.steps)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(status)", image: badge.map { .init(data: $0) })
    }
}

/// Finds orbits by id, by what was said or typed, or all of them to choose from.
struct OrbitQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [OrbitEntity] {
        try await Intents.orbits().filter { identifiers.contains($0.id) }.map(Intents.entity)
    }

    @MainActor func entities(matching string: String) async throws -> [OrbitEntity] {
        try await Intents.orbits().filter { $0.name.localizedCaseInsensitiveContains(string) }.map(Intents.entity)
    }

    @MainActor func suggestedEntities() async throws -> [OrbitEntity] { try await Intents.orbits().map(Intents.entity) }
}

/// What `orbit check` found, as values a shortcut can use.
struct ConfigurationCheck: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Configuration Check"

    @Property(title: "Valid") var valid: Bool
    @Property(title: "Problem") var problem: String?
    @Property(title: "File") var file: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(problem ?? "No problems")") }
}

extension AppIntent {
    /// Asks before orbits.json changes, whoever runs the intent and however sure they are.
    func confirm(_ question: String, _ action: ConfirmationActionName) async throws {
        try await requestConfirmation(actionName: action, dialog: "\(question)")
    }
}

// MARK: One orbit

extension Action {
    /// The intent that asks for this action. Every action has one, so a new action needs an intent to compile.
    var intent: any OrbitIntent.Type {
        switch self {
        case .start: StartOrbit.self
        case .stop: StopOrbit.self
        case .restart: RestartOrbit.self
        case .toggle: ToggleOrbit.self
        case .dismiss: DismissOrbit.self
        }
    }
}

/// An intent about one orbit.
protocol OrbitIntent: AppIntent {
    var orbit: OrbitEntity { get }
}

extension OrbitIntent {
    /// Runs `orbit <command> <id> …`, which waits until that is done, and returns the orbit as it then stands.
    func run(_ command: String, _ more: [String] = []) async throws -> some IntentResult & ReturnsValue<OrbitEntity> {
        let report: Report = try await Intents.orbit([command, orbit.id] + more)
        return await .result(value: Intents.entity(report))
    }

    /// Asks for the `Action` this intent stands for (`Action.intent`).
    func act() async throws -> some IntentResult & ReturnsValue<OrbitEntity> {
        guard let action = Action.allCases.first(where: { $0.intent == Self.self }) else {
            throw CocoaError(.featureUnsupported)
        }
        return try await run(action.rawValue)
    }
}

struct StartOrbit: OrbitIntent {
    static let title: LocalizedStringResource = "Start Orbit"
    static let description = IntentDescription(
        "Starts an orbit, a background task or service such as a web server or a sync, and waits until it runs or answers at its address.",
        categoryName: "Run", resultValueName: "Orbit")
    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$orbit)") }
    @Parameter(title: "Orbit", description: "The orbit to start.") var orbit: OrbitEntity

    func perform() async throws -> some IntentResult & ReturnsValue<OrbitEntity> { try await act() }
}

struct StopOrbit: OrbitIntent {
    static let title: LocalizedStringResource = "Stop Orbit"
    static let description = IntentDescription("Stops a running orbit and waits until it has ended.",
                                               categoryName: "Run", resultValueName: "Orbit")
    static var parameterSummary: some ParameterSummary { Summary("Stop \(\.$orbit)") }
    @Parameter(title: "Orbit", description: "The orbit to stop.") var orbit: OrbitEntity

    func perform() async throws -> some IntentResult & ReturnsValue<OrbitEntity> { try await act() }
}

struct RestartOrbit: OrbitIntent {
    static let title: LocalizedStringResource = "Restart Orbit"
    static let description = IntentDescription(
        "Stops an orbit if it runs, then starts it again and waits until it runs or answers at its address.",
        categoryName: "Run", resultValueName: "Orbit")
    static var parameterSummary: some ParameterSummary { Summary("Restart \(\.$orbit)") }
    @Parameter(title: "Orbit", description: "The orbit to restart.") var orbit: OrbitEntity

    func perform() async throws -> some IntentResult & ReturnsValue<OrbitEntity> { try await act() }
}

struct ToggleOrbit: OrbitIntent {
    static let title: LocalizedStringResource = "Toggle Orbit"
    static let description = IntentDescription("Starts an orbit, or stops it if it runs, like its Spotlight launcher.",
                                               categoryName: "Run", resultValueName: "Orbit")
    static var parameterSummary: some ParameterSummary { Summary("Toggle \(\.$orbit)") }
    @Parameter(title: "Orbit", description: "The orbit to start or stop.") var orbit: OrbitEntity

    func perform() async throws -> some IntentResult & ReturnsValue<OrbitEntity> { try await act() }
}

struct DismissOrbit: OrbitIntent {
    static let title: LocalizedStringResource = "Dismiss Failed Orbit"
    static let description = IntentDescription("Clears the mark a failed run left on an orbit's badge in the menu bar.",
                                               categoryName: "Run", resultValueName: "Orbit")
    static var parameterSummary: some ParameterSummary { Summary("Dismiss the failure of \(\.$orbit)") }
    @Parameter(title: "Orbit", description: "The orbit whose last run failed.") var orbit: OrbitEntity

    func perform() async throws -> some IntentResult & ReturnsValue<OrbitEntity> { try await act() }
}

/// "Is web preview running?": says how the orbit stands and returns it with all its details.
struct OrbitStatus: OrbitIntent {
    static let title: LocalizedStringResource = "Get Orbit Status"
    static let description = IntentDescription(
        "Says how an orbit stands, and returns its details: state, whether it runs, addresses, kind, when it started or ended, exit code and progress.",
        categoryName: "Look", resultValueName: "Orbit")
    static var parameterSummary: some ParameterSummary { Summary("Get the status of \(\.$orbit)") }
    @Parameter(title: "Orbit", description: "The orbit to look at.") var orbit: OrbitEntity

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<OrbitEntity> {
        let report = try await Intents.status(orbit.id)
        return await .result(value: Intents.entity(report), dialog: "\(report.sentence)")
    }
}

/// The addresses of the orbit chosen in Open Orbit Address, to pick one from.
struct OrbitAddresses: DynamicOptionsProvider {
    @IntentParameterDependency<OpenOrbitAddress>(\.$orbit) var intent

    func results() async throws -> [String] { intent?.orbit.addresses ?? [] }
}

struct OpenOrbitAddress: OrbitIntent {
    static let title: LocalizedStringResource = "Open Orbit Address"
    static let description = IntentDescription(
        "Opens where a running orbit answers: its web page in the browser, a vnc address in Screen Sharing, an ssh address in a terminal.",
        categoryName: "Look", resultValueName: "Orbit")
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$orbit)") { \.$address } }
    @Parameter(title: "Orbit", description: "The running orbit whose address to open.") var orbit: OrbitEntity
    @Parameter(title: "Address", description: "Which address, for an orbit that has several, such as localhost:8080. Without one, the first opens.",
               optionsProvider: OrbitAddresses())
    var address: String?

    func perform() async throws -> some IntentResult & ReturnsValue<OrbitEntity> {
        try await run("open", address.map { [$0] } ?? [])
    }
}

struct ShowOrbitOutput: OrbitIntent {
    static let title: LocalizedStringResource = "Show Orbit Output"
    static let description = IntentDescription("Opens a terminal window that shows an orbit's output and keeps following it.",
                                               categoryName: "Look", resultValueName: "Orbit")
    static var parameterSummary: some ParameterSummary { Summary("Show the output of \(\.$orbit)") }
    @Parameter(title: "Orbit", description: "The orbit whose output to show.") var orbit: OrbitEntity

    func perform() async throws -> some IntentResult & ReturnsValue<OrbitEntity> { try await run("output") }
}

struct GetOrbitOutput: OrbitIntent {
    static let title: LocalizedStringResource = "Get Orbit Output"
    static let description = IntentDescription("Returns the last lines an orbit's latest run wrote, as text.",
                                               categoryName: "Look", resultValueName: "Output")
    static var parameterSummary: some ParameterSummary { Summary("Get the last \(\.$lines) lines of \(\.$orbit)") }
    @Parameter(title: "Orbit", description: "The orbit whose output to get.") var orbit: OrbitEntity
    @Parameter(title: "Lines", description: "How many lines, counted from the end.", default: 100, inclusiveRange: (1, 10000))
    var lines: Int

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let output: CLI.Logs = try await Intents.orbit(["logs", orbit.id, "-n", String(lines)])
        return .result(value: output.lines.joined(separator: "\n"))
    }
}

// MARK: All orbits, and Orbit itself

/// "Which orbits are running?": the orbits, all or those in one state.
struct FindOrbits: AppIntent {
    static let title: LocalizedStringResource = "Find Orbits"
    static let description = IntentDescription(
        "Lists your orbits with their states, all of them or only those in one state, such as running or failed.",
        categoryName: "Look", resultValueName: "Orbits")
    static var parameterSummary: some ParameterSummary { Summary("Find orbits that are \(\.$state)") }
    @Parameter(title: "State", description: "Only orbits in this state. Without one, every orbit.") var state: Report.State?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[OrbitEntity]> {
        let orbits = try await Intents.orbits(state)
        let said = orbits.isEmpty ? "No orbits." : orbits.map(\.sentence).joined(separator: "\n")
        return .result(value: orbits.map(Intents.entity), dialog: "\(said)")
    }
}

struct StopAllOrbits: AppIntent {
    static let title: LocalizedStringResource = "Stop All Orbits"
    static let description = IntentDescription("Stops every running orbit and waits until all have ended.", categoryName: "Run")

    func perform() async throws -> some IntentResult {
        let _: Snapshot = try await Intents.orbit([Request.stopAll.rawValue])
        return .result()
    }
}

/// Orbit's own windows, as the command line names them (`Request`).
enum OrbitWindow: String, AppEnum {
    case window, settings

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Orbit Window"
    static let caseDisplayRepresentations: [OrbitWindow: DisplayRepresentation] = [.window: "Orbits", .settings: "Settings"]
}

struct OpenOrbit: AppIntent {
    static let title: LocalizedStringResource = "Open Orbit"
    static let description = IntentDescription("Opens Orbit's window, which lists your orbits, or its settings.", categoryName: "Orbit")
    static var parameterSummary: some ParameterSummary { Summary("Open Orbit's \(\.$showing)") }
    @Parameter(title: "Window", description: "The list of orbits, or Orbit's settings.", default: .window) var showing: OrbitWindow

    func perform() async throws -> some IntentResult {
        let _: Snapshot = try await Intents.orbit([showing.rawValue])
        return .result()
    }
}

struct CheckConfiguration: AppIntent {
    static let title: LocalizedStringResource = "Check Orbit Configuration"
    static let description = IntentDescription(
        "Checks orbits.json, the file that lists your orbits, and returns whether it is valid, or what is wrong with it.",
        categoryName: "Configure", resultValueName: "Check")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<ConfigurationCheck> {
        let (_, printed, message) = await Intents.run(["check"])
        guard let found: CLI.Check = Snapshot.decode(printed) else {
            throw Intents.Failure(said: message)
        }
        let check = ConfigurationCheck()
        (check.valid, check.problem, check.file) = (found.valid, found.problem, found.file)
        return .result(value: check, dialog: "\(found.problem ?? "orbits.json has no problems.")")
    }
}

// MARK: Changing orbits.json

/// What `orbit add` and `orbit edit` take, as the parameters of the two intents. One left out is not passed on.
protocol OrbitFields: AppIntent {
    var command: String? { get }
    var script: String? { get }
    var url: String? { get }
    var folder: String? { get }
    var badge: String? { get }
    var kind: OrbitKind? { get }
    var animate: OrbitSpec.Animate? { get }
    var openInBrowser: Bool? { get }
}

extension OrbitFields {
    /// The options for the command line.
    var options: [String] {
        let given = [("command", command), ("script", script), ("url", url), ("cwd", folder), ("badge", badge),
                     ("kind", kind?.rawValue), ("animate", animate?.rawValue), ("openInBrowser", openInBrowser?.description)]
        return given.flatMap { key, value in value.map { ["--\(key)", $0] } ?? [] }
    }

    /// Checks the change without saving, asks whether to save what would be written, then saves and returns the orbit.
    func save(_ arguments: [String], _ verb: String, _ action: ConfirmationActionName, running: Bool) async throws
        -> some IntentResult & ReturnsValue<OrbitEntity> {
        let entry: OrbitSpec = try await Intents.orbit(arguments + ["--dry-run"])
        let draft = Config.Draft(entry), question = draft.question(verb, running: running)
        try await confirm("\(question.title) \(question.detail)\n\(draft.runs)", action)
        let report: Report = try await Intents.orbit(arguments)
        return await .result(value: Intents.entity(report))
    }
}

struct AddOrbit: OrbitFields {
    static let title: LocalizedStringResource = "Add Orbit"
    static let description = IntentDescription(
        "Adds an orbit: a command or a script to start from Spotlight and watch in the menu bar. Asks before it saves.",
        categoryName: "Configure", resultValueName: "Orbit")
    static var parameterSummary: some ParameterSummary {
        Summary("Add an orbit named \(\.$name)") { \.$command; \.$script; \.$url; \.$folder; \.$badge; \.$kind; \.$animate; \.$openInBrowser }
    }
    @Parameter(title: "Name", description: "What you type in Spotlight to start it.") var name: String
    @Parameter(title: "Command", description: "What it runs, as you would type it in a terminal. Give this or a script.") var command: String?
    @Parameter(title: "Script", description: "The path of a script file to run. Give this or a command.") var script: String?
    @Parameter(title: "URL", description: "The address it answers at, such as http://localhost:8080. Without one, Orbit finds a service's addresses by itself.")
    var url: String?
    @Parameter(title: "Run Folder", description: "The folder it runs in. Without one, a script's own folder, or your home folder.") var folder: String?
    @Parameter(title: "Badge", description: "What its ring shows: up to 4 characters, symbol: and an SF Symbol name, or a shape and text such as cards:L. Without one, its id.")
    var badge: String?
    @Parameter(title: "Kind", description: "A service runs until stopped, a task ends by itself. Without one, Orbit decides.") var kind: OrbitKind?
    @Parameter(title: "Animation", description: "When the badge's satellite turns.") var animate: OrbitSpec.Animate?
    @Parameter(title: "Open Web Page When Ready", description: "Whether its web page opens in the browser as soon as it answers. On unless turned off.")
    var openInBrowser: Bool?

    func perform() async throws -> some IntentResult & ReturnsValue<OrbitEntity> {
        try await save(["add", name] + options, "Add", .add, running: false)
    }
}

struct EditOrbit: OrbitFields {
    static let title: LocalizedStringResource = "Edit Orbit"
    static let description = IntentDescription(
        "Changes an orbit. Only what is given changes, and an empty text takes a setting out again. Asks before it saves.",
        categoryName: "Configure", resultValueName: "Orbit")
    static var parameterSummary: some ParameterSummary {
        Summary("Edit \(\.$orbit)") { \.$name; \.$command; \.$script; \.$url; \.$folder; \.$badge; \.$kind; \.$animate; \.$openInBrowser }
    }
    @Parameter(title: "Orbit", description: "The orbit to change.") var orbit: OrbitEntity
    @Parameter(title: "Name", description: "A new name. Its launcher, log and history follow.") var name: String?
    @Parameter(title: "Command", description: "What it runs, as you would type it in a terminal. Replaces a script.") var command: String?
    @Parameter(title: "Script", description: "The path of a script file to run. Replaces a command.") var script: String?
    @Parameter(title: "URL", description: "The address it answers at, such as http://localhost:8080.") var url: String?
    @Parameter(title: "Run Folder", description: "The folder it runs in.") var folder: String?
    @Parameter(title: "Badge", description: "What its ring shows: up to 4 characters, symbol: and an SF Symbol name, or a shape and text such as cards:L.")
    var badge: String?
    @Parameter(title: "Kind", description: "A service runs until stopped, a task ends by itself. Automatic lets Orbit decide.") var kind: OrbitKind?
    @Parameter(title: "Animation", description: "When the badge's satellite turns.") var animate: OrbitSpec.Animate?
    @Parameter(title: "Open Web Page When Ready", description: "Whether its web page opens in the browser as soon as it answers.")
    var openInBrowser: Bool?

    func perform() async throws -> some IntentResult & ReturnsValue<OrbitEntity> {
        try await save(["edit", orbit.id] + (name.map { ["--name", $0] } ?? []) + options, "Save", .continue, running: orbit.isRunning)
    }
}

struct DeleteOrbit: OrbitIntent {
    static let title: LocalizedStringResource = "Delete Orbit"
    static let description = IntentDescription(
        "Removes an orbit that is not running, with its Spotlight launcher, log and history. Asks before it deletes.",
        categoryName: "Configure")
    static var parameterSummary: some ParameterSummary { Summary("Delete \(\.$orbit)") }
    @Parameter(title: "Orbit", description: "The orbit to delete. Stop it first if it runs.") var orbit: OrbitEntity

    func perform() async throws -> some IntentResult {
        let _: Report = try await Intents.orbit(["delete", orbit.id, "--dry-run"])        // refused while it runs
        try await confirm("Delete “\(orbit.name)”? Its Spotlight launcher, log and history go with it.",
                          .custom(acceptLabel: "Delete", acceptAlternatives: [], denyLabel: "Cancel", denyAlternatives: [], destructive: true))
        let _: Report = try await Intents.orbit(["delete", orbit.id, "--yes"])
        return .result()
    }
}

/// What can be said to Siri or typed in Spotlight without setting anything up. macOS takes ten at most, so
/// these are the ones worth saying; the rest are in Shortcuts and open to Apple Intelligence.
struct OrbitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartOrbit(),
                    phrases: ["Start \(\.$orbit) in \(.applicationName)", "Start \(.applicationName) \(\.$orbit)"],
                    shortTitle: "Start Orbit", systemImageName: "play.circle")
        AppShortcut(intent: StopOrbit(),
                    phrases: ["Stop \(\.$orbit) in \(.applicationName)", "Stop \(.applicationName) \(\.$orbit)"],
                    shortTitle: "Stop Orbit", systemImageName: "stop.circle")
        AppShortcut(intent: RestartOrbit(),
                    phrases: ["Restart \(\.$orbit) in \(.applicationName)", "Restart \(.applicationName) \(\.$orbit)"],
                    shortTitle: "Restart Orbit", systemImageName: "arrow.clockwise.circle")
        AppShortcut(intent: ToggleOrbit(),
                    phrases: ["Toggle \(\.$orbit) in \(.applicationName)", "Toggle \(.applicationName) \(\.$orbit)"],
                    shortTitle: "Toggle Orbit", systemImageName: "playpause.circle")
        AppShortcut(intent: OrbitStatus(),
                    phrases: ["Is \(\.$orbit) running in \(.applicationName)", "\(.applicationName) status of \(\.$orbit)"],
                    shortTitle: "Orbit Status", systemImageName: "questionmark.circle")
        AppShortcut(intent: FindOrbits(),
                    phrases: ["Which orbits are \(\.$state) in \(.applicationName)", "What is running in \(.applicationName)"],
                    shortTitle: "Find Orbits", systemImageName: "list.bullet.circle")
        AppShortcut(intent: StopAllOrbits(),
                    phrases: ["Stop everything in \(.applicationName)", "Stop all orbits in \(.applicationName)"],
                    shortTitle: "Stop All Orbits", systemImageName: "stop.circle.fill")
        AppShortcut(intent: OpenOrbitAddress(),
                    phrases: ["Open \(\.$orbit) in \(.applicationName)", "Open \(.applicationName) \(\.$orbit)"],
                    shortTitle: "Open Orbit Address", systemImageName: "safari")
        AppShortcut(intent: ShowOrbitOutput(),
                    phrases: ["Show the output of \(\.$orbit) in \(.applicationName)", "Show \(.applicationName) output of \(\.$orbit)"],
                    shortTitle: "Show Orbit Output", systemImageName: "terminal")
        AppShortcut(intent: DeleteOrbit(),
                    phrases: ["Delete \(\.$orbit) in \(.applicationName)", "Delete \(.applicationName) \(\.$orbit)"],
                    shortTitle: "Delete Orbit", systemImageName: "trash.circle")
    }
}
