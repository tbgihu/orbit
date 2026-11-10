import AppKit

/// The running orbits and the failed runs not yet dismissed, plus a watchdog process (so a force quit leaves
/// nothing running) and a periodic cap on their logs.
@MainActor
final class Jobs {
    private(set) var running: [String: Job] = [:]
    /// Orbits whose last run failed, shown in the menu bar until dismissed or run again. `LastRun` has the rest.
    private(set) var failures = Set<String>()
    /// Process groups of ended runs whose leader has exited but whose other processes outlived the SIGTERM sent
    /// then. They get SIGKILL after the grace period Stop gives, or when Orbit quits.
    private(set) var lingering = Set<pid_t>()
    /// Orbits being restarted: stopped, to be started again once everything of the old run is gone.
    private(set) var restarting = Set<String>()
    /// Orbits asked to start while the terminal's environment is read again (ShellEnvironment).
    private(set) var waiting = Set<String>()

    /// A run started or came up.
    private let changed: () -> Void
    /// A run ended and its outcome was recorded.
    private let ended: () -> Void
    private let progressed: () -> Void
    /// Waits for this process to exit, even by force quit, and stops whatever it left running.
    private var watchdog: Process?
    /// Set once quitting stops every run, so a watchdog ending then is not replaced.
    private var quitting = false
    /// Keeps the logs of long runs bounded by checking their size every minute while anything runs.
    private var logCap: Timer?

    init(changed: @escaping () -> Void, ended: @escaping () -> Void, progressed: @escaping () -> Void) {
        self.changed = changed
        self.ended = ended
        self.progressed = progressed
    }

    subscript(id: String) -> Job? { running[id] }

    /// In config order, then the runs of orbits no longer in it.
    var inOrder: [Job] { Config.orbits.compactMap { running[$0.id] } + unlisted }

    /// Runs of orbits no longer in the config (removed while running), by id.
    var unlisted: [Job] { running.keys.filter { Config.orbit($0) == nil }.sorted().compactMap { running[$0] } }

    /// A start that fails at once, before anything could run, is a failed run like any other.
    func start(_ id: String) {
        guard running[id] == nil, !waiting.contains(id), let orbit = Config.orbit(id) else { return }
        failures.remove(id)
        guard let environment = ShellEnvironment.current() else {
            waiting.insert(id)
            return ShellEnvironment.whenCurrent { [weak self] in
                guard let self, self.waiting.remove(id) != nil else { return }
                self.start(id)
            }
        }
        let started = try? Job(orbit, environment: environment)
        guard let job = started, !job.exited else {
            NSSound.beep()
            record(orbit, started?.outcome ?? .failed(127))
            ended()
            return
        }

        running[id] = job
        startWatchdog()
        startLogCap()
        job.onChange = { [weak self] in self?.changed() }
        job.onProgress = { [weak self] in self?.progressed() }
        job.onExit = { [weak self] in self?.finished(id) }
        changed()
    }

    /// Also takes back a restart under way.
    func stop(_ id: String) {
        restarting.remove(id)
        running[id]?.stop()
        if waiting.remove(id) != nil { ended() }
    }

    /// Stops a running orbit and starts it again; one that isn't running is just started.
    func restart(_ id: String) {
        guard let job = running[id] else { return start(id) }
        restarting.insert(id)
        job.stop()
    }

    func toggle(_ id: String) { if running[id] == nil && !waiting.contains(id) { start(id) } else { stop(id) } }

    func stopAll() {
        restarting.removeAll()
        running.values.forEach { $0.stop() }
        if !waiting.isEmpty { waiting.removeAll(); ended() }
    }

    func dismiss(_ id: String) { failures.remove(id) }

    /// Drops failures of orbits removed from the config.
    func forgetRemoved() {
        failures = failures.filter { Config.orbit($0) != nil }
    }

    /// Stops every run off the main thread when quitting (SIGTERM, then SIGKILL for what is left after `grace`)
    /// and calls `done` once all are gone.
    func terminateAll(grace: TimeInterval, then done: @escaping @Sendable () -> Void) {
        quitting = true
        waiting.removeAll()
        let groups = running.values.map(\.pid) + lingering, ids = Array(running.keys)
        DispatchQueue.global(qos: .userInitiated).async {
            groups.forEach { killpg($0, SIGTERM) }
            Runtime.waitForExit(of: groups.flatMap(Runtime.members), until: Date().addingTimeInterval(grace))
            groups.forEach { killpg($0, SIGKILL) }      // whatever is left, including processes whose leader already exited
            ids.forEach(Runtime.forget)                 // only now, so the watchdog still has them if Orbit dies meanwhile
            done()
        }
    }

    private func finished(_ id: String) {
        guard let job = running[id] else { return }
        if let outcome = job.outcome { record(job.spec, outcome) }
        let group = job.pid, left = Runtime.members(group)
        running[id] = nil
        if running.isEmpty { logCap?.invalidate(); logCap = nil }
        guard restarting.contains(id) else {
            if !left.isEmpty { linger(group) }
            return ended()
        }
        // A restart waits for whatever the old run left, as Stop's grace period does, so its port is free again.
        changed()
        DispatchQueue.global(qos: .userInitiated).async {
            Runtime.waitForExit(of: left, until: Date().addingTimeInterval(2))
            killpg(group, SIGKILL)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if self.restarting.remove(id) != nil { self.start(id) } else { self.ended() } }
            }
        }
    }

    private func record(_ orbit: OrbitSpec, _ outcome: Job.Outcome) {
        LastRun.record(orbit, outcome)
        if case .failed = outcome { failures.insert(orbit.id) }
    }

    private func linger(_ group: pid_t) {
        lingering.insert(group)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.lingering.remove(group) != nil else { return }
                if !Runtime.members(group).isEmpty { killpg(group, SIGKILL) }
            }
        }
    }

    private func startLogCap() {
        guard logCap == nil else { return }
        logCap = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.running.values.forEach { $0.capLog() }
            }
        }
        logCap?.tolerance = 30
    }

    /// A small helper process that blocks in the kernel until Orbit exits, using no CPU. If Orbit is force quit,
    /// it stops the orbits left behind, as the next launch would. Started with the first orbit, and again if it
    /// dies while orbits run (unless it died at once, which would only repeat).
    private func startWatchdog() {
        guard watchdog?.isRunning != true, let executable = Bundle.main.executableURL else { return }
        let process = Process(), started = Date()
        process.executableURL = executable
        process.arguments = Internal.watchdog.arguments(String(getpid()))
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.quitting, !self.running.isEmpty, -started.timeIntervalSinceNow > 1 else { return }
                self.startWatchdog()
            }
        }
        if (try? process.run()) != nil { watchdog = process }
    }
}
