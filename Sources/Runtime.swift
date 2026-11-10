import AppKit
import Darwin

/// Files on disk: the logs, and in a folder of the user's temporary folder, which a reboot clears, the agent's
/// socket and the pid records. The records let a new agent clean up process groups left behind when
/// the previous one crashed.
enum Runtime {
    private static var fm: FileManager { .default }
    private static let runDir = fm.temporaryDirectory.appending(path: Build.identifier, directoryHint: .isDirectory)
    private static let logDir = Build.path(.logs)

    /// Where the agent listens for the command line and the launchers (Link).
    static let socket = runDir.appending(path: "agent.sock").path

    /// The terminal's environment as last read (ShellEnvironment).
    static let environmentFile = runDir.appending(path: "environment").path

    /// `<name>.log` holds an orbit's latest run. Orbit's own log is `Orbit.log`, a name no orbit can have.
    static func logFile(_ name: String) -> String {
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)   // in case it was removed while Orbit runs
        return logDir.appending(path: "\(name).log").path
    }

    /// One line in Orbit.log.
    static func log(_ message: String) {
        let fd = open(logFile("Orbit"), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
        close(fd)
    }

    /// The extended attribute that holds a log's orbit, by id. The log is named for people; this is how Orbit
    /// finds it again after the orbit was renamed.
    private static let owner = Build.identifier + ".id"

    /// Opens an orbit's log for a new run, emptied and marked with its id. O_APPEND lets `capLog` trim the log
    /// while the orbit is still writing. -1 when it can't be opened.
    static func openLog(_ orbit: OrbitSpec) -> Int32 {
        let fd = open(logFile(orbit.name), O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o644)
        if fd >= 0 { fsetxattr(fd, owner, orbit.id, orbit.id.utf8.count, 0, 0) }
        return fd
    }

    /// Brings the logs in line with the config, going by the id each log carries: the log of an orbit that has
    /// another name now is renamed, and the log of an orbit that is gone is removed, unless it still runs. A log
    /// without an id belongs to the orbit of that name, if there is one. Renames go through `.<id>.log`, so two
    /// orbits can swap names; one left there by an interruption is picked up the next time.
    static func reconcileLogs(_ orbits: [OrbitSpec]) {
        guard let files = try? fm.contentsOfDirectory(atPath: logDir.path) else { return }
        let key = { (name: String) in name.precomposedStringWithCanonicalMapping.lowercased() }   // as the file system compares
        let path = { (name: String) in logDir.appending(path: name + ".log").path }
        var renamed: [OrbitSpec] = []
        for file in files where file.hasSuffix(".log") && file != "Orbit.log" {
            let name = String(file.dropLast(4))
            var id = [UInt8](repeating: 0, count: 8)
            let length = getxattr(path(name), owner, &id, id.count, 0, 0)
            if length <= 0 {
                guard let orbit = orbits.first(where: { key($0.name) == key(name) }) else { unlink(path(name)); continue }
                setxattr(path(name), owner, orbit.id, orbit.id.utf8.count, 0, 0)
            } else if let orbit = orbits.first(where: { $0.id.utf8.elementsEqual(id[..<length]) }) {
                if orbit.name != name, rename(path(name), path("." + orbit.id)) == 0 { renamed.append(orbit) }
            } else if !recorded(String(decoding: id[..<length], as: UTF8.self)) {
                unlink(path(name))
            }
        }
        for orbit in renamed { _ = rename(path("." + orbit.id), path(orbit.name)) }
    }

    /// Empties a run's log once it passes 10 MB, leaving a line that says so. It goes by the run's own descriptor,
    /// so a log renamed or deleted while the orbit runs stays bounded too. This is safe while the orbit writes
    /// because it appends, so its next line lands at the new end.
    static func capLog(_ fd: Int32) {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 10 << 20 else { return }
        ftruncate(fd, 0)
        let note = "[earlier output trimmed, over 10 MB]\n"
        _ = note.withCString { write(fd, $0, strlen($0)) }
    }

    /// Show Output: a terminal window following the log (its last 1000 lines, then live). It opens a .command file
    /// in the terminal chosen in Settings, which needs no extra permission. The file removes itself once it runs.
    /// `done` hears whether the terminal opened it, on any thread; the command line waits for that.
    @MainActor static func showOutput(_ name: String, then done: @escaping @Sendable (Bool) -> Void = { _ in }) {
        let log = logFile(name)
        if !fm.fileExists(atPath: log) { fm.createFile(atPath: log, contents: nil) }
        try? fm.createDirectory(at: runDir, withIntermediateDirectories: true)
        let command = runDir.appending(path: "\(name) output.command")
        let script = """
            #!/bin/zsh
            [[ $0 == *' output.command' ]] && rm -f -- $0
            printf '\\e]0;%s\\a' \(shellQuoted("\(name) output"))
            exec tail -n 1000 -F \(shellQuoted(log))

            """
        guard (try? script.write(to: command, atomically: true, encoding: .utf8)) != nil else { return done(false) }
        chmod(command.path, 0o755)
        Terminal.open(command, then: done)
    }

    /// One agent at a time, through an exclusive lock held for the life of the process. The kernel drops it on exit,
    /// crash included, and close-on-exec keeps it out of the orbits. False when another Orbit holds it.
    static func claimInstance() -> Bool {
        try? fm.createDirectory(at: runDir, withIntermediateDirectories: true)
        let fd = open(runDir.appending(path: "agent.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }                            // without a lock, Orbit still starts
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        return true                                                   // fd stays open, so the lock lasts as long as Orbit
    }

    static func record(_ id: String, pid: pid_t) {
        guard let start = startTime(pid) else { return }
        try? fm.createDirectory(at: runDir, withIntermediateDirectories: true)
        try? "\(pid) \(start)".write(to: runDir.appending(path: "\(id).pid"), atomically: true, encoding: .utf8)
    }

    /// Whether a run of this orbit is on record, which it is from its start until its end is seen.
    static func recorded(_ id: String) -> Bool { fm.fileExists(atPath: runDir.appending(path: "\(id).pid").path) }

    static func forget(_ id: String) {
        try? fm.removeItem(at: runDir.appending(path: "\(id).pid"))
        clearOpened(id)
    }

    // MARK: Opening in the browser

    /// While an orbit runs, a folder with an empty file for each address (`Address.key`) opened in the browser,
    /// by its command or by Orbit. Whoever creates an address's file opens it; the other leaves that address alone.
    static func openedFolder(_ id: String) -> String { runDir.appending(path: "\(id).opened").path }

    /// Claims opening `key` for an orbit, unless it was opened already. Only one creator of a file succeeds
    /// (O_EXCL), so Orbit and the stand-in `open` never both win.
    static func claimOpening(_ id: String, _ key: String) -> Bool {
        let folder = openedFolder(id)
        mkdir(folder, 0o700)                                         // made by the first claim
        let fd = open(folder + "/" + key, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Forgets what was opened, for a new start or when the orbit ends.
    static func clearOpened(_ id: String) { try? fm.removeItem(atPath: openedFolder(id)) }

    /// The folder put first in each orbit's PATH, holding Orbit's stand-in `open`, which is also its BROWSER.
    /// Rewritten when missing or changed; nil when it can't be written.
    static func standIns() -> String? {
        let folder = runDir.appending(path: "bin", directoryHint: .isDirectory), open = folder.appending(path: "open")
        if (try? String(contentsOf: open, encoding: .utf8)) != standIn {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? standIn.write(to: open, atomically: true, encoding: .utf8)) != nil else { return nil }
        }
        chmod(open.path, 0o755)
        return folder.path
    }

    /// Opens web links (http, https) once per start, and only when the orbit opens in the browser (`ORBIT_OPEN=1`):
    /// in $BROWSER if one is set (`%s` in it stands for the link), or with the options given (`open -a App`, `-g`…).
    /// Each address is claimed in the `ORBIT_OPENED` folder, so a link to an address Orbit already opened is
    /// skipped, and Orbit leaves alone one its command opened. With opening off, web links are dropped quietly.
    /// Anything else (vnc:// and ssh:// links, files, apps, other options) goes to /usr/bin/open unchanged.
    /// It is a zsh script because that starts faster than Orbit's binary and doesn't depend on where Orbit is.
    private static let standIn = #"""
        #!/bin/zsh -f
        # Orbit's stand-in for open and $BROWSER within an orbit (Runtime.swift).
        setopt extendedglob noclobber
        args=("$@") flags=() links=()
        while (( $# )); do
          case $1 in
            (-[ab]) (( $# > 1 )) || exec /usr/bin/open "${args[@]}"; flags+=($1 $2); shift 2;;
            (-[gjnuFW]) flags+=($1); shift;;
            ((#i)http(s|)://?*) links+=($1); shift;;
            (*) exec /usr/bin/open "${args[@]}";;
          esac
        done
        (( $#links )) || exec /usr/bin/open "${args[@]}"
        [[ $ORBIT_OPEN == 1 && -n $ORBIT_OPENED ]] || exit 0
        path=(${path:#${0:h}})                  # so a BROWSER of `open` is the real one, not this script again
        browser=(${=ORBIT_BROWSER})
        [[ -d $ORBIT_OPENED ]] || mkdir -p -- $ORBIT_OPENED 2>/dev/null
        for link in $links; do
          address=${${link#*://}%%[/?#]*}; address=${(L)address##*@}
          if [[ $address == \[* ]]; then host=${${address%%\]*}#\[}; port=${${address#*\]}#:}
          else host=${address%%:*}; port=${${address#$host}#:}; fi
          [[ $host == (localhost|127.0.0.1|::1|0.0.0.0|::) ]] && host=localhost
          [[ -n $port ]] || { [[ $link == (#i)https* ]] && port=443 || port=80 }
          { : > $ORBIT_OPENED/${host}:${port} } 2>/dev/null || continue       # claimed already
          if (( $#flags || ! $#browser )); then /usr/bin/open $flags $link
          elif [[ $ORBIT_BROWSER == *%s* ]]; then ${browser//\%s/$link}
          else $browser $link; fi
        done

        """#


    /// Terminates process groups recorded by a previous agent that didn't get to stop them, and drops its claims
    /// of opened addresses. The start time guards against a recycled pid. Waits up to a second before SIGKILL, so a
    /// restart gets its port back.
    static func reapOrphans() {
        guard let files = try? fm.contentsOfDirectory(at: runDir, includingPropertiesForKeys: nil) else { return }
        var orphans: [pid_t] = []
        for file in files where file.pathExtension == "opened" { try? fm.removeItem(at: file) }
        for file in files where file.pathExtension == "pid" {
            defer { try? fm.removeItem(at: file) }
            guard let fields = try? String(contentsOf: file, encoding: .utf8).split(separator: " "), fields.count == 2,
                  let pid = pid_t(fields[0]), let start = UInt64(fields[1]), startTime(pid) == start else { continue }
            killpg(pid, SIGTERM)
            orphans.append(pid)
        }
        waitForExit(of: orphans.flatMap(members), until: Date().addingTimeInterval(1))
        orphans.forEach { killpg($0, SIGKILL) }
    }

    /// Returns once every process in `pids` has exited (an unreaped child counts) or at `deadline`. A kqueue wakes
    /// it on each exit, so nothing polls.
    nonisolated static func waitForExit(of pids: [pid_t], until deadline: Date) {
        let queue = kqueue()
        guard queue >= 0 else { return }
        defer { close(queue) }
        var live = 0
        for pid in Set(pids) {
            var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                                fflags: NOTE_EXIT, data: 0, udata: nil)
            if kevent(queue, &change, 1, nil, 0, nil) == 0 { live += 1 }      // fails when it is already gone
        }
        var event = kevent()
        while live > 0 {
            let left = min(deadline.timeIntervalSinceNow, 1e9)
            guard left > 0 else { return }
            var timeout = timespec(tv_sec: Int(left), tv_nsec: Int(left.truncatingRemainder(dividingBy: 1) * 1e9))
            let count = kevent(queue, nil, 0, &event, 1, &timeout)
            if count > 0 { live -= 1 } else if count == 0 || errno != EINTR { return }
        }
    }

    /// The processes in process group `group`, read with libproc.
    nonisolated static func members(_ group: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 512)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return pids.prefix(max(0, Int(bytes)) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    /// A process as libproc describes it, or nil when it is gone.
    static func info(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func startTime(_ pid: pid_t) -> UInt64? {
        info(pid).map { $0.pbi_start_tvsec &* 1_000_000 &+ $0.pbi_start_tvusec }
    }
}
