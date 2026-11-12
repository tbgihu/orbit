import Foundation

/// The update state shown in the window's title bar, the menu and Settings, kept in one place so they agree:
/// nothing to install, a newer version found but not downloaded (Manually), one downloaded, or one requested while
/// orbits run, which installs once the last one stops.
enum UpdateState: Equatable {
    case none, download, restart, pending

    var title: String {
        switch self {
        case .none: ""
        case .download: "Download and Install"
        case .restart: "Restart to Update"
        case .pending: "Update Pending"
        }
    }

    var summary: String {
        switch self {
        case .none: ""
        case .download: "A new version of Orbit is available."
        case .restart: "A new version of Orbit is ready."
        case .pending: "A new version of Orbit is ready and installs as soon as no orbit is running."
        }
    }

    /// Whether its button is enabled. Pending shows it greyed out.
    var actionable: Bool { self == .download || self == .restart }
}

/// Updates come from the git clone Orbit was built from (Info.plist `OrbitSource`), through its
/// `scripts/update.sh`, in two halves:
///
/// - **prepare**, every 2 h while Orbit runs: fetch, and when the clone's upstream is ahead of this build, build
///   that commit into a stage (`Build.Key.stage`). Nothing installed changes.
/// - **install**, once a stage is ready: Orbit quits, the installer fast-forwards the clone, swaps in the staged
///   app and reopens what was open. This happens automatically when nothing would be interrupted (a fresh launch,
///   or the last orbit stopping); otherwise you choose Restart to Update.
///
/// Siri support comes the same way, in every mode as an automatic update would (`poll`). Once Xcode and an Apple
/// Development certificate can add it (`SiriSupport`) every build has it, so in Automatically mode one install
/// brings both a new version and Siri support. In the other modes it is added to this version alone, since there
/// new versions wait for the user.
@MainActor
final class Updater {
    static let interval: TimeInterval = 2 * 60 * 60

    /// The Updates setting. Automatically checks every 2 h, prepares, and installs when nothing would be interrupted.
    /// Download Only checks and prepares, then installs on Update. Manually checks only on Check for Updates.
    enum Mode: String, CaseIterable {
        case automatic, downloadOnly = "download", manual

        var title: String {
            switch self {
            case .automatic: "Automatically"
            case .downloadOnly: "Download Only"
            case .manual: "Manually"
            }
        }
    }

    static var mode: Mode {
        get { Defaults.updates.flatMap(Mode.init) ?? .automatic }
        set { Defaults.updates = newValue.rawValue }
    }

    /// Whether the update script is at work right now, building or installing: its lock names a live process
    /// (`lock` in scripts/lib.sh).
    nonisolated static var busy: Bool {
        guard let holder = try? String(contentsOfFile: Build.path(.stage).path + ".lock", encoding: .utf8),
              let pid = pid_t(holder.trimmed) else { return false }
        return kill(pid, 0) == 0
    }

    /// Updates come from a git clone; a copy built from a downloaded ZIP has none.
    var available: Bool { script != nil }

    /// Whether to install without asking when nothing would be interrupted (a fresh launch, the last orbit stopping):
    /// in Automatically mode whatever is staged, a new version, Siri support or both. In the other modes only this
    /// version with Siri support, since Siri support arrives in every mode as an automatic update would.
    var installsByItself: Bool { Self.mode == .automatic ? staged != nil : addsSiri }

    let siri = SiriSupport()

    var onChange: (() -> Void)?
    /// A prepare found something newer and is building it ("Downloading Update…").
    var onBuilding: (() -> Void)?
    /// A prepare is building an update right now, so a check that joins it shows "Downloading Update…" at once.
    private(set) var building = false

    private let script: URL?
    private let stage = Build.path(.stage)
    /// The prepare under way, by whether it rebuilds this version (`installed`), and the ones asked for with
    /// whoever waits for each.
    private var running: Bool?
    private var waiting: [Bool: [@MainActor @Sendable (Check) -> Void]] = [:]
    /// The last prepare ran with Xcode ready, so only the timer tries Siri support again: a build that failed is
    /// not retried each time Settings comes to the front.
    private var triedSiri = false
    private var timer: Timer?

    init() {
        script = Build[.source]
            .map { URL(filePath: $0).appending(path: "scripts/update.sh") }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    /// The build waiting in the stage when it brings something: its commit and whether it has Siri support. A build
    /// of this commit with no more Siri support than this one brings nothing, as when build.sh fell back to Orbit
    /// Local Signing after the Apple Development certificate expired, so it is never installed over this one. The
    /// update script applies the same rule (`prepare` in scripts/update.sh).
    var staged: (commit: String, intents: Bool)? {
        guard script != nil,
              FileManager.default.fileExists(atPath: stage.appending(path: "Orbit.app").path),
              let staged = (try? String(contentsOf: stage.appending(path: "commit"), encoding: .utf8))?.trimmed,
              staged != Build.identity, staged + " intents" != Build.identity else { return nil }
        let commit = staged.replacing(" intents", with: "")
        return (commit, commit != staged)
    }

    /// A newer version is staged.
    var ready: Bool { staged.map { $0.commit != Build.commit } ?? false }

    /// The stage holds this version with Siri support added.
    var addsSiri: Bool { staged.map { $0.commit == Build.commit && $0.intents } ?? false }

    /// Polls now, then every interval while Orbit runs. At launch, and again when the mode changes. In Manually
    /// mode only while Siri support may still come.
    func start() {
        timer?.invalidate()
        timer = nil
        poll()
        guard script != nil, Self.mode != .manual || !Build.siri else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(due: true) }
        }
        timer?.tolerance = 600
    }

    /// Looks at Xcode and the certificate, then prepares what is due, at launch, on the timer (`due`), after Check
    /// for Updates and when Orbit or its Settings comes to the front. Siri support is due in every mode once Xcode
    /// can add it and the stage lacks it; outside Automatically mode it is built for this version alone, and a new
    /// version waits until it is in. A new version is due every interval, except in Manually mode.
    func poll(due: Bool = false) {
        siri.look { [weak self] in
            guard let self else { return }
            onChange?()
            guard script != nil, running == nil else { return }
            let checked = (try? stage.appending(path: "checked").resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let update = due || Date().timeIntervalSince(checked) >= Self.interval
            let siriDue = siri.state == .adding && staged?.intents != true && (due || !triedSiri)
            switch Self.mode {
            case .automatic: if update || siriDue { prepare() }
            case _ where siri.state == .adding: if siriDue { prepare(installed: true) }
            case .downloadOnly: if update { prepare() }
            case .manual: break
            }
        }
    }

    enum Check { case done, available, offline, failed }

    /// In Manually mode, a check found a newer version that isn't downloaded yet.
    private(set) var newer = false

    /// Fetches and compares only, for Manually mode. Nothing is downloaded or built.
    func check(then: @escaping @MainActor @Sendable (Check) -> Void) {
        guard let script else { then(.failed); return }
        let process = run(script, ["check"])
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in
                self?.newer = status == 10
                self?.onChange?()
                then(status == 0 ? .done : status == 10 ? .available : status == 3 ? .offline : .failed)
            }
        }
        if (try? process.run()) == nil { then(.failed) }
    }

    /// Fetches and, when there is something new, a newer version or Siri support, builds it into the stage. With
    /// `installed`, it builds this version with Siri support instead, which never brings in a new version. `then`
    /// gets the result. One prepare runs at a time: one asked for meanwhile joins it when it is the same kind,
    /// else follows it.
    func prepare(installed: Bool = false, then: (@MainActor @Sendable (Check) -> Void)? = nil) {
        waiting[installed, default: []] += then.map { [$0] } ?? []
        if running == nil { start(installed) }
    }

    private func start(_ installed: Bool) {
        guard let script else { return finish(installed, .failed) }
        running = installed
        let process = run(script, ["prepare"] + (installed ? ["--installed"] : [])) { [weak self] output in
            // a newer version, not this one again with Siri support
            guard !installed, output.contains("building"), !output.contains("building  \(Build.commit)") else { return }
            Task { @MainActor in self?.building = true; self?.onBuilding?() }
        }
        process.qualityOfService = .userInitiated
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.finish(installed, status == 0 ? .done : status == 3 ? .offline : .failed) }
        }
        if (try? process.run()) == nil { finish(installed, .failed) }
    }

    /// Looks at Xcode again first, since a build that failed at Siri support rules out this version of Xcode.
    private func finish(_ installed: Bool, _ check: Check) {
        building = false
        siri.look { [weak self] in
            guard let self else { return }
            running = nil
            triedSiri = siri.state == .adding
            onChange?()
            waiting.removeValue(forKey: installed)?.forEach { $0(check) }
            if let next = waiting.keys.first { start(next) }
        }
    }

    /// Starts the installer, which waits for this process to exit; the caller quits right after. Every install goes
    /// through here. `reopen` lists the `orbit://` URLs to hand the new Orbit once it is in place: the requests
    /// this one was started with, or the windows that were open. In Automatically mode, or for an `update` asked
    /// for, the installer brings in the newest commit however old the prepared one is, with Siri support once Xcode
    /// can add it, so one install brings both. Otherwise it installs this version with Siri support, never a newer one.
    func install(reopen: [String], update: Bool = false) {
        guard let script else { return }
        let installed = !update && Self.mode != .automatic
        try? run(script, ["install", "--after", String(getpid())] + (installed ? ["--installed"] : []) + reopen).run()
    }

    /// A process for the script with its output appended to Orbit.log. `watch` also sees the output as it arrives.
    private func run(_ script: URL, _ arguments: [String],
                     watch: (@Sendable (String) -> Void)? = nil) -> Process {
        let process = Process()
        process.executableURL = script
        process.arguments = arguments
        Runtime.trimLog("Orbit")
        let log = Runtime.logFile("Orbit")
        if !FileManager.default.fileExists(atPath: log) { FileManager.default.createFile(atPath: log, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: log) else { return process }
        handle.seekToEndOfFile()
        process.standardError = handle
        guard let watch else { process.standardOutput = handle; return process }
        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { reader in
            let data = reader.availableData
            guard !data.isEmpty else { reader.readabilityHandler = nil; return }
            handle.write(data)
            watch(String(decoding: data, as: UTF8.self))
        }
        process.standardOutput = pipe
        return process
    }
}
