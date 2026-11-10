import Foundation

/// What Orbit adds when it starts a run, without touching orbits.json: environment variables and options that
/// keep an unattended run from waiting for input, and the switches that make progress visible. Each addition only
/// fills in what the line and the environment leave unset, and a line Shell can't parse with certainty gets none.
enum Launch {
    /// Set unless the environment already sets them.
    static let environment: KeyValuePairs<String, String> = [
        "PYTHONUNBUFFERED": "1",                 // Python writes at once, so Show Output is live
        "GIT_TERMINAL_PROMPT": "0",              // git fails instead of asking for a username or password
        "SSH_ASKPASS_REQUIRE": "never",          // ssh never asks through a password dialog
        "PIP_NO_INPUT": "1",                     // pip fails instead of waiting for input that cannot come
    ]

    /// Defined ahead of a line that runs ssh. Prints `-o` options for an unattended run, each only where the
    /// arguments don't set it and ssh's effective setting (`ssh -G`, which connects to nothing) is still its
    /// default, so ssh config and options already given win. Prints nothing when `ssh -G` fails, and ssh then runs
    /// as written.
    static let sshSetup = """
        _orbit_ssh_options() {
          setopt localoptions extendedglob
          local -a ssh=($1) set; shift; local config line want arg next
          [[ $ssh == */* ]] || ssh=(command $ssh)
          config=$($ssh -G "$@" </dev/null 2>/dev/null) || return 0
          for arg; do                       # -o Key=value, -oKey=value, -vo Key=value
            if [[ -n $next ]]; then set+=(${(L)arg%%[= ]*}); next=
            elif [[ $arg == -[[:alpha:]]#o ]]; then next=1
            elif [[ $arg == -o?* ]]; then set+=(${(L)${arg#-o}%%[= ]*}); fi
          done
          for line in ${(f)config}; do
            case $line in
              ("batchmode no") want=BatchMode=yes;;
              ("exitonforwardfailure no") want=ExitOnForwardFailure=yes;;
              ("serveraliveinterval 0") want=ServerAliveInterval=15;;
              (*) continue;;
            esac
            (( ${set[(Ie)${(L)want%%=*}]} )) || print -- -o $want
          done
        }

        """

    /// The line as it will run. With `progress`, git and rsync are also asked to report progress, and an rsync
    /// reporting over the whole run to list every file before it copies one. `setup` is shell code to run before
    /// it, empty unless the line needs it.
    static func line(_ line: String, progress: Bool) -> (setup: String, line: String) {
        guard let steps = Shell.steps(line) else { return ("", line) }
        var insertions: [(at: Int, text: String)] = [], setup = ""
        for command in steps.joined() {
            guard let index = program(command) else { continue }
            let word = command[index], args = command[(index + 1)...]
            switch word.name {
            case "ssh":
                // the same words again, so ssh -G sees what ssh will; redirections between them stay out
                setup = sshSetup
                insertions.append((word.range.upperBound,
                                   " $(_orbit_ssh_options \(command[index...].map(\.text).joined(separator: " ")))"))
            case "git" where progress: insertions += gitProgress(args).map { [($0, " --progress")] } ?? []
            case "rsync" where progress:
                guard let report = rsyncProgress(args), report != .perFile else { continue }
                // the whole file list first, so progress2's percentage and to-chk count are of the whole run
                let options = (report == .added ? ["--info=progress2"] : []) + (rsyncIncremental(args) == nil ? ["--no-inc-recursive"] : [])
                guard !options.isEmpty else { continue }
                // only rsync 3.1 and later has progress2 (macOS's openrsync doesn't), so ask the binary at run time;
                // --no-inc-recursive is older (3.0)
                insertions.append((word.range.upperBound,
                                   " $(\(word.text) --info=progress2 --version >/dev/null 2>&1 && print -- \(options.joined(separator: " ")))"))
            default: continue
            }
        }
        return (setup, Shell.inserting(insertions, into: line))
    }

    /// The index of the program word, skipping wrappers that run the command after them (`exec`, `command`,
    /// `nohup`, `noglob`, `nice`, `sudo`, and `env` with its assignments) when they have no options.
    static func program(_ command: Shell.Command) -> Int? {
        var index = 0
        while index < command.count - 1, let value = command[index].value, wrappers.contains(value) {
            guard command[index + 1].value?.hasPrefix("-") == false else { return nil }
            index += 1
            if value == "env" { while index < command.count - 1, command[index].value?.contains("=") == true { index += 1 } }
        }
        return command[index].value == nil ? nil : index
    }

    private static let wrappers: Set = ["exec", "command", "nohup", "noglob", "nice", "sudo", "env"]

    /// Where to insert `--progress` in `git [global options] clone|fetch|pull|push …`, right after the subcommand.
    /// Nil when the command already sets how much to report, or may: an argument that expands something is fine
    /// only as an operand (`"$HOME/code"`).
    static func gitProgress(_ args: ArraySlice<Shell.Word>) -> Int? {
        guard let (subcommand, rest) = gitTransfer(args), rest.allSatisfy({ arg in
            arg.value.map { !["--progress", "--no-progress", "-q", "--quiet"].contains($0) } ?? arg.isOperand
        }) else { return nil }
        return subcommand.range.upperBound
    }

    /// For `git [global options] clone|fetch|pull|push`, the subcommand's word and the arguments after it.
    static func gitTransfer(_ args: ArraySlice<Shell.Word>) -> (Shell.Word, ArraySlice<Shell.Word>)? {
        var rest = args[...]
        while let first = rest.first, let value = first.value, value.hasPrefix("-") {
            rest = rest.dropFirst(["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"].contains(value) ? 2 : 1)
        }
        guard let subcommand = rest.first, ["clone", "fetch", "pull", "push"].contains(subcommand.value ?? "") else { return nil }
        return (subcommand, rest.dropFirst())
    }

    /// How an rsync command reports progress (`Meter.rsync`).
    enum RsyncProgress {
        /// Orbit adds `--info=progress2`, since the command doesn't set the progress level and isn't quiet. A
        /// `--progress` or `-P` then reports the whole run too, as `--info` outranks them.
        case added
        /// The command asks for `--info=progress2` itself.
        case overall
        /// One file at a time: `--info=progress1`, or `--progress` or `-P` where the command sets the level.
        case perFile
    }

    /// Whether the command turns rsync's incremental recursion on (`--inc-recursive`, `--i-r`) or off
    /// (`--no-inc-recursive`, `--no-i-r`), the last one given, or nil when it sets neither.
    static func rsyncIncremental(_ args: ArraySlice<Shell.Word>) -> Bool? {
        var incremental: Bool?
        for arg in args {
            guard let value = arg.value else { continue }
            if value == "--" { break }
            if ["--inc-recursive", "--i-r"].contains(value) { incremental = true }
            if ["--no-inc-recursive", "--no-i-r"].contains(value) { incremental = false }
        }
        return incremental
    }

    /// How rsync will report progress, or nil when it won't, or may not: an argument that expands something is
    /// fine only as an operand (`"$HOME/Documents"`). The level is the last one `--info` sets (`progress2`,
    /// `progress`, `all`, `none`); without one, `--no-progress` and `-q` mean none.
    static func rsyncProgress(_ args: ArraySlice<Shell.Word>) -> RsyncProgress? {
        var level: Int?, quiet = false, progress = true
        var words = args.makeIterator()
        while let arg = words.next() {
            guard let value = arg.value else {
                if arg.isOperand { continue } else { return nil }
            }
            if value == "--" { break }
            if value == "--info" || value.hasPrefix("--info=") {
                guard let list = value == "--info" ? words.next()?.value : String(value.dropFirst(7)) else { return nil }
                for word in list.lowercased().split(separator: ",") {
                    let name = word.prefix { $0.isLetter }, digits = word.dropFirst(name.count)
                    guard ["progress", "all", "none"].contains(name) else { continue }
                    level = name == "none" ? 0 : digits.isEmpty ? 1 : Int(digits) ?? 1
                }
            } else if value == "--quiet" {
                quiet = true
            } else if value == "--progress" || value == "--no-progress" {
                progress = value == "--progress"
            } else if value.hasPrefix("-"), !value.hasPrefix("--"), value.dropFirst().allSatisfy({ $0.isASCII && $0.isLetter }) {
                if value.contains("q") { quiet = true }                  // -q, -avq
                if value.contains("P") { progress = true }               // -P, -avP
            }
        }
        switch level {
        case let level?: return level >= 2 ? .overall : level == 1 ? .perFile : nil
        case nil: return quiet || !progress ? nil : .added
        }
    }
}
