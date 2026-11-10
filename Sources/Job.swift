import AppKit
import Darwin

/// A running orbit: a process group led by `zsh -c <command>` with the terminal's environment (ShellEnvironment),
/// supervised until it exits.
@MainActor
final class Job {
    /// `starting` until an address of its url answers, then `running`. An orbit without a url starts out running.
    enum State { case starting, running }

    /// How a run ended. A run killed by a signal fails with 128 plus the signal number.
    enum Outcome: Equatable {
        case done
        case failed(Int32)
        case stopped
    }

    let spec: OrbitSpec
    let started = Date()
    private(set) var state = State.starting
    private(set) var exited = false
    private(set) var outcome: Outcome?
    /// Where it answers: its url's addresses, or for a service without one, those found among the ports it
    /// listens on, by port.
    private(set) var addresses: [Address] = []
    /// Set when it is stopped on purpose (toggle, Stop, sleep, logout, quit), so the exit status is not a failure.
    private var stopping = false

    var onChange: (() -> Void)?
    var onExit: (() -> Void)?
    var onProgress: (() -> Void)?

    /// How far a task has got, when its command reports progress and its ring would otherwise turn.
    var progress: Progress? { watch?.progress }

    /// The process group's leader (and so the group's id).
    nonisolated let pid: pid_t
    private let stdinWriter: Int32          // held open so stdin never reaches EOF (keeps `ssh -tt` sessions alive)
    /// The log as opened for this run, so it is capped even when renamed or deleted meanwhile. -1 without a log.
    private let logFD: Int32
    private var exitSource: DispatchSourceProcess?
    private var probe: Task<Void, Never>?
    private var watch: ProgressWatch?

    init(_ spec: OrbitSpec, environment: ShellEnvironment.Resolved) throws {
        self.spec = spec
        let plan = spec.isTask && spec.circlesWhileRunning ? spec.command.flatMap(Plan.init) : nil
        (pid, stdinWriter, logFD) = try Spawn.start(spec, environment: environment, progress: plan != nil)
        Runtime.record(spec.id, pid: pid)
        if let plan {
            watch = ProgressWatch(plan, log: Runtime.logFile(spec.name), group: pid) { [weak self] in self?.onProgress?() }
        }

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        // blocking: the exit event can arrive just before the process can be reaped, and it arrives only once
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reap(blocking: true) } }
        source.resume()
        exitSource = source
        reap()                                // the process may have died before the source was armed
        guard !exited else { return }         // then there are no addresses to look for

        addresses = spec.addresses
        if !addresses.isEmpty {
            probe = Task { [weak self] in await self?.waitForAddresses() }
        } else {
            state = .running
            if !spec.isTask { probe = Task { [weak self] in await self?.findAddresses() } }
        }
    }

    /// SIGTERM to the group, SIGKILL if it is still there after a grace period.
    func stop(grace: TimeInterval = 2) {
        guard !exited else { return }
        stopping = true
        killpg(pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.exited else { return }
                killpg(self.pid, SIGKILL)
            }
        }
    }

    /// Keeps the log within bounds (Runtime.capLog).
    func capLog() {
        if !exited, logFD >= 0 { Runtime.capLog(logFD) }
    }

    private func reap(blocking: Bool = false) {
        guard !exited else { return }
        var status: Int32 = 0
        guard waitpid(pid, &status, blocking ? 0 : WNOHANG) == pid else { return }
        exited = true
        let signal = status & 0x7f, code = (status >> 8) & 0xff
        outcome = stopping ? .stopped : signal != 0 ? .failed(128 + signal) : code == 0 ? .done : .failed(code)
        killpg(pid, SIGTERM)                  // anything the shell left behind in the group
        close(stdinWriter)
        if logFD >= 0 { close(logFD) }
        exitSource?.cancel()
        probe?.cancel()
        watch?.stop()
        Runtime.forget(spec.id)
        onExit?()
    }

    /// How long addresses are looked for after a start. Only the first address of a url is waited for longer.
    nonisolated static let window: TimeInterval = 120

    /// Asked every 250 ms for the first 10 s, then every second.
    private nonisolated static func backoff(since started: Date) -> Duration {
        .milliseconds(started.timeIntervalSinceNow > -10 ? 250 : 1000)
    }

    /// Waits for the url's addresses, each the way its kind answers. The orbit is up when the first one does;
    /// the others are waited for until the search window ends, so that each web page opens when it is up.
    private func waitForAddresses() async {
        enum Event { case answered(Address), windowEnded }
        let started = started
        await withTaskGroup(of: Event?.self) { group in
            for address in addresses {
                group.addTask { await Self.answers(address, since: started) ? .answered(address) : nil }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(max(0, Self.window + started.timeIntervalSinceNow)))
                return .windowEnded
            }
            var windowEnded = false
            while let event = await group.next() {
                guard !Task.isCancelled, !exited else { break }
                switch event {
                case .answered(let address)?:
                    state = .running
                    answered(address, opens: address.isWeb)
                    if windowEnded { group.cancelAll() }
                case .windowEnded?:
                    windowEnded = true
                    if state == .running { group.cancelAll() }
                case nil: break
                }
            }
            group.cancelAll()
        }
    }

    /// Whether an address answers before the task is cancelled. For http(s) any HTTP response counts, so an ssh
    /// tunnel is ready once the remote server is up. vnc and ssh need their greeting, tcp only an open connection.
    private nonisolated static func answers(_ address: Address, since started: Date) async -> Bool {
        if address.isWeb {
            var request = URLRequest(url: address.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
            request.httpMethod = "HEAD"
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            while !Task.isCancelled {
                if let (_, response) = try? await session.data(for: request), response is HTTPURLResponse { return true }
                try? await Task.sleep(for: backoff(since: started))
            }
        } else {
            let (host, port) = (address.url.host() ?? "", address.port)
            while !Task.isCancelled {
                let kind = await Probe.answer(host: host, port: port)?.kind
                if !Task.isCancelled, kind == address.kind || (address.kind == .tcp && kind != nil) { return true }
                try? await Task.sleep(for: backoff(since: started))
            }
        }
        return false
    }

    /// Shows an address as up and, when it `opens`, opens it once in the browser (`openInBrowser`). The one-second
    /// delay lets a command that opens its own link go first. Every address can still be opened from the menu.
    private func answered(_ address: Address, opens: Bool) {
        onChange?()
        guard opens, spec.opensInBrowser else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.exited, Runtime.claimOpening(self.spec.id, address.key) else { return }
                address.open()
            }
        }
    }

    /// For a service without a url, finds what answers on each port its processes listen on, each port classified
    /// once. Looks with the same backoff until the search window ends, then stops. Of these only a web page opens
    /// by itself.
    private func findAddresses() async {
        enum Event { case listening([Listeners.Listener]), probed(Listeners.Listener, Probe.Answer?) }
        let (started, group) = (started, pid)
        var seen = Set<Int>()                                // ports classified, or being
        await withTaskGroup(of: Event?.self) { tasks in
            tasks.addTask { .listening(Listeners.of(group: group)) }
            while let event = await tasks.next() {
                guard !Task.isCancelled, !exited else { break }
                switch event {
                case .listening(let listeners)?:
                    for listener in listeners where seen.insert(listener.port).inserted {
                        tasks.addTask { .probed(listener, await Probe.answer(host: listener.connect, port: listener.port)) }
                    }
                    guard started.timeIntervalSinceNow > -Self.window else { continue }
                    tasks.addTask {
                        try? await Task.sleep(for: Self.backoff(since: started))
                        return Task.isCancelled ? nil : .listening(Listeners.of(group: group))
                    }
                case .probed(let listener, let answer?)?:
                    let address = Address(answer.kind, host: listener.host, port: listener.port)
                    addresses.insert(address, at: addresses.firstIndex { $0.port > listener.port } ?? addresses.endIndex)
                    answered(address, opens: answer.page)
                case .probed(let listener, nil)?:
                    seen.remove(listener.port)               // closed without a word: ask again
                case nil: break
                }
            }
            tasks.cancelAll()
        }
    }
}

/// `posix_spawn` with a fresh process group, so one `killpg` stops the whole tree.
private enum Spawn {
    struct Failure: Error { let errno: Int32 }

    static func start(_ spec: OrbitSpec, environment resolved: ShellEnvironment.Resolved,
                      progress: Bool) throws -> (pid: pid_t, stdinWriter: Int32, log: Int32) {
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw Failure(errno: errno) }
        _ = fcntl(pipeFDs[1], F_SETFD, FD_CLOEXEC)
        let logFD = Runtime.openLog(spec)
        defer { close(pipeFDs[0]) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pipeFDs[0], 0)
        if logFD >= 0 {
            posix_spawn_file_actions_adddup2(&actions, logFD, 1)
            posix_spawn_file_actions_adddup2(&actions, logFD, 2)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
                                              | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        // Put the stand-in `open` first in PATH and use it as BROWSER, after the startup files have run.
        let standIns = Runtime.standIns().map {
            "path=(\(shellQuoted($0)) $path); export ORBIT_BROWSER=${BROWSER-} BROWSER=\(shellQuoted($0 + "/open")); "
        } ?? ""
        // cd in the shell instead of posix_spawn's chdir, so a folder denied by privacy protection gets logged
        let (setup, line) = Launch.line(spec.shellLine, progress: progress)
        let script = standIns + setup + "cd -- \(shellQuoted(spec.directory)) && \(line)"
        var environment: [String] = [], flags = "-c"
        switch resolved {
        case .terminal(let variables): environment = variables
        case .login:
            flags = "-lc"
            var entry = environ
            while let value = entry.pointee { environment.append(String(cString: value)); entry += 1 }
        }
        let argv = ["/bin/zsh", flags, script].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        for (name, value) in Launch.environment where !environment.contains(where: { $0.hasPrefix(name + "=") }) {
            environment.append("\(name)=\(value)")
        }
        environment.removeAll { $0.hasPrefix("ORBIT_OPEN=") || $0.hasPrefix("ORBIT_OPENED=") }
        environment += ["ORBIT_OPEN=\(spec.opensInBrowser ? 1 : 0)", "ORBIT_OPENED=\(Runtime.openedFolder(spec.id))"]
        Runtime.clearOpened(spec.id)                                      // fresh for each start
        let envp = environment.map { strdup($0) } + [nil]
        defer { envp.forEach { free($0) } }

        let rc = posix_spawn(&pid, argv[0], &actions, &attr, argv, envp)
        guard rc == 0 else {
            if logFD >= 0 { _ = "orbit: could not start: \(String(cString: strerror(rc)))\n".withCString { write(logFD, $0, strlen($0)) } }
            close(pipeFDs[1])
            if logFD >= 0 { close(logFD) }
            throw Failure(errno: rc)
        }
        return (pid, pipeFDs[1], logFD)
    }
}

func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The last run of each orbit, kept across launches since Orbit quits when idle. The window shows it for stopped orbits.
@MainActor
enum LastRun {
    /// `orbit` is the run's spec. Nothing is kept for an orbit removed while it ran.
    static func record(_ orbit: OrbitSpec, _ outcome: Job.Outcome) {
        let id = orbit.id
        guard Config.orbit(id) != nil else { return }
        if outcome == .done { Defaults.endedByItself[id] = orbit.runs }
        let code: Int32 = switch outcome { case .done: 0; case .failed(let code): code; case .stopped: -1 }
        Defaults.lastRun[id] = ["code": Int(code), "at": Date().timeIntervalSince1970]
    }

    static func of(_ id: String) -> (outcome: Job.Outcome, at: Date)? {
        guard let entry = Defaults.lastRun[id] as? [String: Any],
              let code = entry["code"] as? Int, let at = entry["at"] as? Double else { return nil }
        let outcome: Job.Outcome = code == 0 ? .done : code < 0 ? .stopped : .failed(Int32(code))
        return (outcome, Date(timeIntervalSince1970: at))
    }
}

/// An orbit's state in words, shared by the window and the menu.
enum RunStatus {
    case starting
    /// `hosts` are where it answers, in order.
    case running(since: Date, hosts: [String])
    case done(Date)
    case failed(Int32, Date)
    case stopped(Date)
    case notRun

    /// The current run, else how the last one ended.
    @MainActor init(_ orbit: OrbitSpec, _ job: Job?) {
        if let job {
            self = job.state == .starting ? .starting : .running(since: job.started, hosts: job.addresses.map(\.hostname))
            return
        }
        self = switch LastRun.of(orbit.id) {
        case (.done, let at)?: .done(at)
        case (.failed(let code), let at)?: .failed(code, at)
        case (.stopped, let at)?: .stopped(at)
        case nil: .notRun
        }
    }

    /// The window leaves out the start time while running and dates runs from before today.
    enum Style { case window, menu }

    func text(_ style: Style) -> String {
        let when = { (date: Date) in
            style == .window && !Calendar.current.isDateInToday(date) ? Self.time(date, dated: true) : "at " + Self.time(date)
        }
        return switch (self, style) {
        case (.starting, _): "Starting…"
        case (.running(let since, let hosts), .window):
            hosts.first.map { "Running on \($0)" + (hosts.count > 1 ? " and \(hosts.count - 1) more" : "") }
                ?? "Running since " + Self.time(since)
        case (.running(let since, let hosts), .menu): "Running" + (hosts.first.map { " on " + $0 } ?? "") + " since " + Self.time(since)
        case (.done(let at), _): "Done " + when(at)
        case (.failed(let code, let at), _): "Failed \(when(at)) (exit \(code))"
        case (.stopped, _), (.notRun, .window): "Stopped"
        case (.notRun, .menu): "Not run yet"
        }
    }

    var isFailure: Bool { if case .failed = self { true } else { false } }

    /// The time of day, with the day and month too when `dated` and before today.
    static func time(_ date: Date, dated: Bool = false) -> String {
        dated && !Calendar.current.isDateInToday(date) ? date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
                                                       : date.formatted(date: .omitted, time: .shortened)
    }
}
