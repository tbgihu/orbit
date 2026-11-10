import Foundation
import Synchronization

/// The environment of the user's terminal: what their shell exports once its startup files have run, the
/// interactive ones (.zshrc) included. Orbits run with it, so a command finds the same programs (PATH, version
/// managers, Homebrew) and variables as in a terminal. Like an editor, Orbit asks the shell itself, in the
/// background: once at each agent launch, and before a start when a startup file has changed since. The answer is
/// kept in the runtime folder with those files' modification times, so a start rarely waits. When the shell
/// fails or takes over `timeout`, orbits run with Orbit's own environment and a login shell, and Orbit.log says so.
enum ShellEnvironment {
    /// How an orbit's zsh gets its environment.
    enum Resolved: Sendable, Equatable {
        /// The terminal's variables. zsh runs without -l, since a login shell's path_helper would move the
        /// user's PATH entries behind the system's.
        case terminal([String])
        /// The shell didn't answer: Orbit's own environment, completed by a login shell as before.
        case login
    }

    /// The account's shell (Directory Services), else $SHELL, else zsh.
    static let shell: String = {
        let account = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }
        return [account, ProcessInfo.processInfo.environment["SHELL"]]
            .compactMap(\.self).first { $0.hasPrefix("/") && access($0, X_OK) == 0 } ?? "/bin/zsh"
    }()

    static let timeout: TimeInterval = 5

    /// Set by the shell only because it thinks a person is at a terminal, or about the shell itself.
    private static let dropped: Set = ["SHLVL", "PWD", "OLDPWD", "_", "TERM", "TERM_SESSION_ID", "COLUMNS", "LINES",
                                       "GPG_TTY", "P9K_TTY", "_P9K_TTY"]

    private static let latest = Mutex<Answer?>(nil)
    /// One shell at a time; a start waiting behind another's answer then finds it current.
    private static let queue = DispatchQueue(label: "ShellEnvironment", qos: .userInitiated)
    /// The session of the shell being asked, ended with Orbit so a slow shell never outlives it.
    private static let asking = Mutex<pid_t>(0)
    private static let endAskingAtExit: Void = { atexit { asking.withLock { if $0 > 0 { killpg($0, SIGKILL) } } } }()

    /// At agent launch: asks the shell again, so a change in a file the startup files source is seen too.
    /// Starts meanwhile use the kept answer while its startup files are unchanged.
    static func refresh() { queue.async { _ = ask(keepingCurrent: true) } }

    /// The current answer without waiting, from memory or the runtime folder. Nil when the shell has to be asked.
    static func current() -> Resolved? {
        if let answer = latest.withLock({ $0 }), answer.isCurrent { return answer.resolved }
        guard let answer = Answer(file: Runtime.environmentFile), answer.isCurrent else { return nil }
        latest.withLock { $0 = answer }
        return answer.resolved
    }

    /// Calls `then` on the main queue once there is a current answer, asking the shell if needed.
    static func whenCurrent(_ then: @escaping @MainActor @Sendable () -> Void) {
        queue.async {
            if current() == nil { _ = ask(keepingCurrent: false) }
            DispatchQueue.main.async { MainActor.assumeIsolated(then) }
        }
    }

    // MARK: Asking the shell

    /// What a shell said, and the startup files it said it for, each with its stamp then.
    private struct Answer: Sendable {
        var shell: String
        var files: [String]
        var stamps: [String]
        var resolved: Resolved

        var isCurrent: Bool { shell == ShellEnvironment.shell && files.map(ShellEnvironment.stamp) == stamps }

        init(files: [String], stamps: [String], resolved: Resolved) {
            (shell, self.files, self.stamps, self.resolved) = (ShellEnvironment.shell, files, stamps, resolved)
        }

        /// NUL-separated: shell, whether it answered, the number of files, the files, their stamps, the variables.
        var data: Data {
            let variables: [String] = if case .terminal(let variables) = resolved { variables } else { [] }
            let fields = [shell, resolved == .login ? "0" : "1", String(files.count)] + files + stamps + variables
            return Data(fields.joined(separator: "\0").utf8)
        }

        init?(file: String) {
            guard let data = FileManager.default.contents(atPath: file) else { return nil }
            let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count >= 3, let count = Int(fields[2]), fields.count >= 3 + 2 * count else { return nil }
            shell = fields[0]
            files = Array(fields[3..<(3 + count)])
            stamps = Array(fields[(3 + count)..<(3 + 2 * count)])
            resolved = fields[1] == "1" ? .terminal(Array(fields[(3 + 2 * count)...])) : .login
        }
    }

    /// When a file last changed, or "-" when there is none.
    private static func stamp(_ path: String) -> String {
        var info = stat()
        guard stat(path, &info) == 0 else { return "-" }
        return "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(info.st_size) \(info.st_ino)"
    }

    private static var home: String {
        ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// The startup files of the shell, and of `folder`, where the shell said it looked for them ($ZDOTDIR, fish's
    /// config folder). Nil for a shell Orbit doesn't know how to ask.
    private static func startupFiles(_ folder: String?) -> [String]? {
        let variable = { (name: String) in ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 } }
        switch (shell as NSString).lastPathComponent {
        case "zsh":
            let names = [".zshenv", ".zprofile", ".zshrc", ".zlogin"]
            let folders = [variable("ZDOTDIR") ?? home] + [folder].compactMap { $0?.isEmpty == false ? $0 : nil }
            return names.map { "/etc/" + $0.dropFirst() } + Array(Set(folders)).sorted().flatMap { dir in names.map { dir + "/" + $0 } }
        case "bash":
            return ["/etc/profile", "/etc/bashrc"] + [".bash_profile", ".bash_login", ".profile", ".bashrc"].map { home + "/" + $0 }
        case "fish":
            let dir = folder.flatMap { $0.isEmpty ? nil : $0 } ?? (variable("XDG_CONFIG_HOME") ?? home + "/.config") + "/fish"
            let snippets = (try? FileManager.default.contentsOfDirectory(atPath: dir + "/conf.d")) ?? []
            return [dir + "/config.fish", dir + "/fish_variables", dir + "/conf.d"]
                + snippets.filter { $0.hasSuffix(".fish") }.sorted().map { dir + "/conf.d/" + $0 }
        default:
            return nil
        }
    }

    /// Asks the shell, keeps the answer and returns it. When the shell fails and `keepingCurrent`, a current
    /// answer from before stays.
    private static func ask(keepingCurrent: Bool) -> Resolved {
        let before = Dictionary((startupFiles(nil) ?? []).map { ($0, stamp($0)) }, uniquingKeysWith: { a, _ in a })
        let answer: Answer
        switch capture() {
        case .success(let (folder, variables)):
            let files = startupFiles(folder) ?? []
            answer = Answer(files: files, stamps: files.map { before[$0] ?? stamp($0) }, resolved: .terminal(variables))
        case .failure(let failure):
            let kept = keepingCurrent ? current() : nil
            Runtime.log("could not read the environment of \(shell) (\(failure.reason)); orbits run with "
                + (kept == nil ? "a login shell's" : "the one read before"))
            if let kept { return kept }
            let files = startupFiles(nil) ?? []
            answer = Answer(files: files, stamps: files.map { before[$0] ?? stamp($0) }, resolved: .login)
        }
        latest.withLock { $0 = answer }
        write(answer.data, to: Runtime.environmentFile)
        return answer.resolved
    }

    private struct Failure: Error { let reason: String }

    /// Runs the shell as a terminal would (interactive, login), but without a terminal and with no input, and
    /// reads what it prints between three markers: where it looks for its startup files, then `env -0`. Whatever
    /// the startup files print around them (banners, prompts, motd) is ignored.
    private static func capture() -> Result<(folder: String, variables: [String]), Failure> {
        let lookup = switch (shell as NSString).lastPathComponent {
        case "zsh": "\"$ZDOTDIR\""
        case "fish": "$__fish_config_dir"
        case "bash": "''"
        default: ""
        }
        guard !lookup.isEmpty else { return .failure(Failure(reason: "not zsh, bash or fish")) }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let (start, middle, end) = ("\(token)<", "\(token)|", "\(token)>")
        let script = "printf %s '\(start)'; printf %s \(lookup); printf %s '\(middle)'; /usr/bin/env -0; printf %s '\(end)'"

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return .failure(Failure(reason: String(cString: strerror(errno)))) }
        defer { close(fds[0]) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, home)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        // a session of its own: no controlling terminal, and one killpg ends whatever it started on a timeout
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                                              | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = [shell, "-i", "-l", "-c", script].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        _ = endAskingAtExit
        let rc = posix_spawn(&pid, shell, &actions, &attr, argv, environ)
        close(fds[1])
        asking.withLock { $0 = pid }
        defer { asking.withLock { $0 = 0 } }
        guard rc == 0 else { return .failure(Failure(reason: String(cString: strerror(rc)))) }

        // Read until the end marker, not end of file: something the startup files leave running may hold it open.
        let deadline = Date().addingTimeInterval(timeout), marker = Array(end.utf8)
        var output: [UInt8] = [], buffer = [UInt8](repeating: 0, count: 65536), finished = false
        while !finished {
            var poller = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
            let left = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            let ready = left > 0 ? poll(&poller, 1, left) : 0
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break }
            let count = read(fds[0], &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue } else { break } }
            if count == 0 { break }
            output += buffer[..<count]
            finished = output.suffix(count + marker.count).firstRange(of: marker) != nil
        }
        // The shell has printed everything; give it the rest of the time to exit (zlogout), then end it.
        Runtime.waitForExit(of: [pid], until: finished ? deadline : Date())
        if !finished { killpg(pid, SIGKILL) }
        kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}

        guard finished else {
            return .failure(Failure(reason: deadline.timeIntervalSinceNow > 0 ? "it exited" : "no answer in \(Int(timeout)) s"))
        }
        guard let opened = output.firstRange(of: Array(start.utf8)),
              let split = output[opened.upperBound...].firstRange(of: Array(middle.utf8)),
              let closed = output[split.upperBound...].firstRange(of: marker) else {
            return .failure(Failure(reason: "its answer was garbled"))
        }
        let folder = String(decoding: output[opened.upperBound..<split.lowerBound], as: UTF8.self)
        let variables = output[split.upperBound..<closed.lowerBound].split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
            .filter { entry in entry.firstIndex(of: "=").map { $0 > entry.startIndex && !dropped.contains(String(entry[..<$0])) } ?? false }
        guard variables.contains(where: { $0.hasPrefix("PATH=") }) else { return .failure(Failure(reason: "it had no PATH")) }
        return .success((folder, variables))
    }

    /// Readable by the user only, since exported variables can hold tokens; replaced in one step.
    private static func write(_ data: Data, to path: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let temporary = path + ".\(getpid())"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        if written != data.count || rename(temporary, path) != 0 { unlink(temporary) }
    }
}
