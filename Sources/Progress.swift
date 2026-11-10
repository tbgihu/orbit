import Foundation
import Darwin

/// How far a task has got: the number of steps in its chain, the one running, and that step's percentage.
struct Progress: Equatable, Sendable {
    let steps: Int
    var step = 0
    /// The running step's percentage, 0...100, or nil until it reports one.
    var percent: Int?
}

/// A command's progress format, read from its output one line at a time (`\r` also ends a line). Each reader knows
/// one tool's format and ignores lines that don't match, since no answer is better than a wrong one.
enum Meter: Sendable {
    /// rsync's progress over the whole run (`--info=progress2`), or one file at a time (`--progress`). `listed`:
    /// without incremental recursion, rsync lists every file before it copies one, so its totals are final from the
    /// first line it prints.
    case rsync(overall: Bool, listed: Bool)
    case curl, wget, git, docker, ffmpeg
    /// A line ending in a percentage, like Homebrew's download bar.
    case bar
    /// tqdm's `45%|████…`, common in Python scripts.
    case tqdm

    /// The meter for a command, from its program and arguments, or nil when it reports nothing readable.
    static func of(_ command: Shell.Command) -> Meter? {
        guard let index = Launch.program(command), let name = command[index].name else { return nil }
        let args = command[(index + 1)...].map { $0.value ?? "" }
        let flags = Set(args.filter { $0.hasPrefix("-") && !$0.hasPrefix("--") }.flatMap { $0.dropFirst() })
        let first = args.first { !$0.hasPrefix("-") }
        switch name {
        case "rsync":
            let rest = command[(index + 1)...]
            guard let report = Launch.rsyncProgress(rest) else { return nil }
            let overall = report != .perFile, incremental = Launch.rsyncIncremental(rest)
            // Launch turns incremental recursion off for a whole-run report the command leaves it to
            return .rsync(overall: overall, listed: incremental == false || overall && incremental == nil)
        case "curl":
            let silent = flags.contains("s") || args.contains("--silent")
            return !silent || flags.contains("#") || args.contains("--progress-bar") ? .curl : nil
        case "wget":
            return flags.contains("q") || args.contains("--quiet") || args.contains("-nv") || args.contains("--no-verbose") ? nil : .wget
        case "git":
            guard let (_, rest) = Launch.gitTransfer(command[(index + 1)...]) else { return nil }
            return rest.contains { ["--no-progress", "-q", "--quiet"].contains($0.value) } ? nil : .git
        case "docker":
            let pull = first == "pull" || (first == "image" && args.contains("pull"))
            return pull && !flags.contains("q") && !args.contains("--quiet") ? .docker : nil
        case "ffmpeg":                                                      // one input, read to its end
            let cuts: Set = ["-t", "-to", "-ss", "-sseof", "-frames", "-vframes", "-stream_loop", "-nostats", "-loglevel", "-v"]
            return args.filter { $0 == "-i" }.count == 1 && !args.contains(where: { cuts.contains($0) || $0.hasPrefix("-frames:") })
                ? .ffmpeg : nil
        case "brew": return ["install", "upgrade", "reinstall", "fetch"].contains(first ?? "") ? .bar : nil
        case _ where name == "python" || name.hasPrefix("python3"): return .tqdm
        default: return nil
        }
    }

    /// Reads a run's output with a meter. Some meters remember earlier lines (ffmpeg's duration, docker's layers,
    /// rsync's files checked).
    struct Reader {
        let meter: Meter
        private var duration: Double?
        private var layers = Set<Substring>(), complete = Set<Substring>()
        /// rsync: whether the file list may still grow, the share of its files checked, and the furthest share read.
        private var listing = false, checked = 0.0, reached = 0.0

        init(_ meter: Meter) {
            self.meter = meter
            if case .rsync(_, let listed) = meter { listing = !listed }
        }

        /// The percentage this line reports, if it is in this meter's format.
        mutating func read(_ line: Substring) -> Double? {
            switch meter {
            case .rsync(let overall, _):
                // The share of the files checked, or over the whole run the share of the bytes when that is ahead,
                // never less than before. The bytes are of all the files' size, but a file already up to date is
                // never copied, so a sync with little to copy stays near 0% by them; one file at a time they are
                // that file's, and only the files count. While the list may still grow (`ir-chk`), neither has a
                // total, and the ring turns.
                guard let (bytes, files) = Self.rsync(line), overall || files != nil else { return nil }
                if let files { listing = files.listing }
                guard !listing else { return nil }
                if let files { checked = files.total > 0 ? Double(files.total - files.left) / Double(files.total) : 1 }
                reached = max(reached, checked, overall ? bytes : 0)
                return reached * 100
            case .curl:
                let fields = line.split(separator: " ")    // % Total % Received …, Total 0 while unknown
                if fields.count == 12, let percent = Double(fields[0]), fields[1] != "0" { return percent }
                return Self.ending(line)                  // -#
            case .wget:                                     // never a `NN%` in the file name
                if let bar = line.range(of: "%[", options: .backwards) {   // `name  45%[===>   ]`
                    return Self.number(before: bar.lowerBound, in: line)
                }
                // `  1500K .......... ..........  45% 1.2M 3s`, written when output isn't a terminal
                let fields = line.split(separator: " ")
                guard fields.count > 2, let size = fields.first, size.dropLast().allSatisfy(\.isNumber),
                      size.last.map("KMG".contains) == true, fields[1].allSatisfy({ $0 == "." }),
                      let mark = fields.first(where: { $0.hasSuffix("%") }) else { return nil }
                return Double(mark.dropLast()).flatMap { $0 <= 100 ? $0 : nil }
            case .git:
                for (phase, from, to) in [("Receiving objects:", 0.0, 90.0), ("Resolving deltas:", 90, 100), ("Writing objects:", 0, 100)]
                where line.hasPrefix(phase) {
                    return Self.percent(in: line).map { from + $0 * (to - from) / 100 }
                }
                return nil
            case .docker:
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let layer = line[..<colon], status = line[line.index(after: colon)...].drop { $0 == " " }
                if layer == "Status" { return 100 }
                guard layer.count >= 12, layer.allSatisfy(\.isHexDigit) else { return nil }
                layers.insert(layer)
                if status.hasPrefix("Pull complete") || status.hasPrefix("Already exists") { complete.insert(layer) }
                // all layers are listed first, so the count may still grow until one starts moving
                if ["Pulling fs layer", "Waiting", "Already exists"].contains(where: status.hasPrefix) { return nil }
                return Double(complete.count * 100 / layers.count)
            case .ffmpeg:
                if let range = line.range(of: "Duration: ") {
                    duration = Self.seconds(line[range.upperBound...])
                    return nil
                }
                guard let duration, duration > 0, let range = line.range(of: "time="),
                      let time = Self.seconds(line[range.upperBound...]) else { return nil }
                return min(100, time / duration * 100)
            case .bar: return Self.ending(line)
            case .tqdm:
                guard let mark = line.range(of: "%|") else { return nil }
                return Self.number(before: mark.lowerBound, in: line)
            }
        }

        /// `  1.23MB  45%  1.2MB/s  0:00:05 (xfr#3, to-chk=10/100)` as a file is done, with the time taken, or
        /// `  1.23MB  45%  1.2MB/s  0:00:05` while one is copied, with the time left: the share of the bytes
        /// copied, and as a file is done, of the files listed so far how many are left to check and how many there
        /// are, still `listing` (`ir-chk`) with incremental recursion. rsync 3.1 and later, which also has
        /// `--info=progress2`; earlier ones write `to-check`.
        private static func rsync(_ line: Substring) -> (bytes: Double, files: (left: Int, total: Int, listing: Bool)?)? {
            let fields = line.split(separator: " ")
            guard fields.count == 4 || fields.count == 6, fields[1].last == "%", let percent = Double(fields[1].dropLast()),
                  0...100 ~= percent, fields[2].hasSuffix("/s"), fields[3].contains(":") else { return nil }
            guard fields.count == 6 else {
                // The percentage is a whole number, and a large copy stays at one for long, so the share is taken
                // from the bytes copied and the time left at the current rate, within that whole percent, since
                // the rate's units may be 1024s where the size's are 1000s.
                guard let done = size(fields[0]), let rate = size(fields[2].dropLast(2)), rate > 0,
                      let left = seconds(fields[3]), done + rate * left > 0 else { return (percent / 100, nil) }
                return (min(max(done / (done + rate * left), percent / 100), min(percent + 1, 100) / 100), nil)
            }
            guard fields[4].hasPrefix("(xfr#"), fields[4].last == ",", fields[5].last == ")" else { return nil }
            let check = fields[5].dropLast(), listing = check.hasPrefix("ir-chk="), counts = check.dropFirst(7).split(separator: "/")
            guard listing || check.hasPrefix("to-chk="), counts.count == 2, let left = Int(counts[0]), let total = Int(counts[1]),
                  0...total ~= left else { return nil }
            return (percent / 100, (left, total, listing))
        }

        /// rsync's `1,234,567`, `565MB`, `1.23G` or `12.5KiB` as a number of bytes: K, M, G, T and P are 1000s, or
        /// 1024s with an `i`.
        private static func size(_ text: Substring) -> Double? {
            let text = text.filter { $0 != "," }
            let digits = text.prefix { $0.isNumber || $0 == "." }
            var unit = text.dropFirst(digits.count).uppercased()
            if unit.hasSuffix("B") { unit.removeLast() }
            let binary = unit.hasSuffix("I")
            if binary { unit.removeLast() }
            guard let value = Double(digits), let power = ["", "K", "M", "G", "T", "P"].firstIndex(of: unit) else { return nil }
            return value * pow(binary ? 1024 : 1000, Double(power))
        }

        /// The first `NN%` in the line.
        private static func percent(in line: Substring) -> Double? {
            var from = line.startIndex
            while let mark = line[from...].firstIndex(of: "%") {
                if let value = number(before: mark, in: line) { return value }
                from = line.index(after: mark)
            }
            return nil
        }

        /// `NN%` or `NN.N%` ending the line.
        private static func ending(_ line: Substring) -> Double? {
            let line = line.reversed().drop { $0 == " " }
            guard line.first == "%" else { return nil }
            let text = String(line.dropFirst().prefix { $0.isNumber || $0 == "." }.reversed())
            return Double(text).flatMap { $0 <= 100 ? $0 : nil }
        }

        /// The number just before `index`, if it stands alone as a word and is 0...100.
        private static func number(before index: Substring.Index, in line: Substring) -> Double? {
            var start = index
            while start > line.startIndex, line[line.index(before: start)].isNumber || line[line.index(before: start)] == "." {
                start = line.index(before: start)
            }
            if start > line.startIndex, line[line.index(before: start)].isLetter { return nil }
            return Double(line[start..<index]).flatMap { $0 <= 100 ? $0 : nil }
        }

        /// `01:02:03.45` as seconds.
        private static func seconds(_ text: Substring) -> Double? {
            let parts = text.prefix { $0.isNumber || $0 == ":" || $0 == "." }.split(separator: ":")
            guard parts.count == 3 else { return nil }
            return parts.reduce(0.0) { total, part in Double(part).map { total * 60 + $0 } ?? .nan }.nonNaN
        }
    }
}

private extension Double {
    var nonNaN: Double? { isNaN ? nil : self }
}

/// The steps of a task's command: what runs between `&&`, `||` and `;`, not counting shell builtins and
/// assignments. Each step has the programs it runs and the meter that reads it.
struct Plan: Sendable {
    struct Step: Sendable {
        /// Each command's program and its literal arguments, to recognise it among the running processes.
        let commands: [(name: String, args: [String])]
        let meter: Meter?
    }

    let steps: [Step]

    private static let builtins: Set<String> = [
        "cd", "pushd", "popd", "export", "source", ".", "set", "setopt", "unsetopt", "unset", "true", "false", ":",
        "umask", "alias", "unalias", "typeset", "local", "declare", "readonly", "shift", "ulimit", "trap",
    ]

    /// Nil unless at least one step's progress can be read.
    init?(_ line: String) {
        guard let steps = Shell.steps(line) else { return nil }
        self.steps = steps.compactMap { step in
            let commands: [(name: String, args: [String])] = step.compactMap { command in
                guard let index = Launch.program(command), let name = command[index].name, !Self.builtins.contains(name) else { return nil }
                // only words the shell won't expand can be compared with a process's arguments
                let args = command[(index + 1)...].compactMap(\.value).filter { !$0.contains(where: "~*?[{".contains) }
                return (name, args)
            }
            return commands.isEmpty ? nil : Step(commands: commands, meter: step.lazy.compactMap(Meter.of).first)
        }
        guard self.steps.contains(where: { $0.meter != nil }) else { return nil }
    }

    /// The step running now: the first from `current` on whose program runs with its arguments in the process
    /// group, or `current` when none does (between steps).
    func step(from current: Int, group: pid_t) -> Int {
        guard steps.count > 1 else { return 0 }
        let running = Processes.arguments(group: group)
        for index in current..<steps.count
        where steps[index].commands.contains(where: { command in running.contains { Self.runs(command, $0) } }) {
            return index
        }
        return current
    }

    /// Whether a process with arguments `argv` runs `command`: its program is argv[0], or argv[1] for a script
    /// started by its interpreter, and each of the command's literal arguments is among argv.
    static func runs(_ command: (name: String, args: [String]), _ argv: [String]) -> Bool {
        argv.prefix(2).contains { same(($0 as NSString).lastPathComponent, command.name) }
            && Set(command.args).isSubset(of: argv)
    }

    /// Interpreters often run under a versioned name.
    private static let interpreters: Set = ["python", "pypy", "ruby", "perl", "php", "lua", "node"]

    /// Whether two program names are the same program: equal, or one interpreter in any version and case. Apple's
    /// `/usr/bin/python3` runs as `…/Python.app/Contents/MacOS/Python`, and `python3.12` is python too.
    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let family = { (name: String) in String(name.lowercased().reversed().drop { $0.isNumber || $0 == "." }.reversed()) }
        let program = family(a)
        return interpreters.contains(program) && program == family(b)
    }
}

/// The arguments of each process in a group, read with sysctl rather than by starting `ps`.
enum Processes {
    static func arguments(group: pid_t) -> [[String]] {
        Runtime.members(group).compactMap(arguments)
    }

    /// KERN_PROCARGS2: argc, the executable's path, then argv, each NUL-terminated.
    private static func arguments(_ pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var fields = buffer[4..<size].split(separator: 0, omittingEmptySubsequences: true).makeIterator()
        _ = fields.next()                                                   // the executable's path
        return (0..<argc).compactMap { _ in fields.next().map { String(decoding: $0, as: UTF8.self) } }
    }

    /// A process's parent.
    static func parent(_ pid: pid_t) -> pid_t? { Runtime.info(pid).map { pid_t($0.pbi_ppid) } }
}

/// Follows a running task's log for progress. The kernel reports each write, so nothing polls. The new tail (at
/// most 16 KB) is read and parsed, then the source rests for a quarter second so writes coalesce, which caps it at
/// four reads and wakeups a second. In a chain, the running step is looked up at the same moments, and also when the
/// shell starts a command or one of its commands execs or exits, so a step that prints nothing shows too. Ends with
/// the run, whose last lines are read then.
@MainActor
final class ProgressWatch {
    private(set) var progress: Progress?
    private let onChange: () -> Void
    private let plan: Plan, group: pid_t, fd: Int32
    private let source: DispatchSourceFileSystemObject
    private var reader: Meter.Reader?
    private var current = Progress(steps: 0)
    private var offset: off_t = 0
    private var resting = false
    /// A chain's kqueue for the shell's forks and its children's execs and exits, read on the main queue, and the
    /// processes it has. Only the shell and its own children are watched, not what a step starts.
    private var processes: DispatchSourceRead?
    private var kq: Int32 = -1
    private var watched = Set<pid_t>()

    init?(_ plan: Plan, log: String, group: pid_t, onChange: @escaping () -> Void) {
        let fd = open(log, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        (self.plan, self.group, self.fd, self.onChange) = (plan, group, fd, onChange)
        current = Progress(steps: plan.steps.count)
        if plan.steps.count > 1 { progress = current }                      // a chain shows its steps from the start
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: .main)
        reader = plan.steps[0].meter.map(Meter.Reader.init)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.written() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        guard plan.steps.count > 1 else { return }
        let kq = kqueue()
        guard kq >= 0 else { return }
        self.kq = kq
        processes = DispatchSource.makeReadSource(fileDescriptor: kq, queue: .main)
        processes?.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.processesChanged() } }
        processes?.setCancelHandler { close(kq) }
        processes?.resume()
        watchProcesses()
    }

    func stop() {
        read(notifying: false)
        if resting { resting = false; source.resume() }                    // a suspended source never cancels
        source.cancel()
        processes?.cancel()
    }

    /// Adds the shell's new children to the kqueue. It is done with kevent itself, so the watch is in place before
    /// the step is looked up and nothing happening between the two is missed.
    private func watchProcesses() {
        let members = Set(Runtime.members(group).filter { $0 == group || Processes.parent($0) == group })
        watched.formIntersection(members)
        for pid in members.subtracting(watched) {
            var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_CLEAR),
                                fflags: pid == group ? UInt32(NOTE_FORK | NOTE_EXEC) : UInt32(NOTE_EXEC) | NOTE_EXIT, data: 0, udata: nil)
            if kevent(kq, &change, 1, nil, 0, nil) == 0 { watched.insert(pid) }      // fails when already gone
        }
    }

    private func processesChanged() {
        var events: [kevent] = Array(repeating: kevent(), count: 16), now = timespec()
        while true {
            let count = Int(kevent(kq, nil, 0, &events, Int32(events.count), &now))
            for event in events.prefix(max(count, 0)) where event.fflags & NOTE_EXIT != 0 { watched.remove(pid_t(event.ident)) }
            if count < events.count { break }
        }
        watchProcesses()
        read()
    }

    private func written() {
        read()
        resting = true
        source.suspend()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.resting else { return }
                self.resting = false
                self.source.resume()
            }
        }
    }

    private func read(notifying: Bool = true) {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return }
        if info.st_size < offset { offset = 0 }                              // trimmed (Runtime.capLog)
        let start = max(offset, info.st_size - 16 << 10)
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size - start))
        let count = max(bytes.isEmpty ? 0 : pread(fd, &bytes, bytes.count, start), 0)
        let end = bytes[..<count].lastIndex { $0 == 10 || $0 == 13 }
        if let end { offset = start + off_t(end + 1) }                      // a line still being written is read again

        // the output read so far belongs to the step that was running, so it is read before moving on
        let text = String(decoding: bytes[..<(end ?? 0)], as: UTF8.self)
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            if let percent = reader?.read(line) { current.percent = Int(percent) }
        }
        // a bar redrawn with `\r` (tqdm) has no line end until the next one, so the newest is read now too, by a
        // copy of the reader since it is read again once complete
        let rest = bytes[((end ?? -1) + 1)..<count]
        if var copy = reader, !rest.isEmpty, let percent = copy.read(Substring(String(decoding: rest, as: UTF8.self))) {
            current.percent = Int(percent)
        }
        let step = plan.step(from: current.step, group: group)
        if step != current.step {
            current.step = step
            current.percent = nil
            reader = plan.steps[step].meter.map(Meter.Reader.init)
        }
        let shown = plan.steps.count > 1 || current.percent != nil ? current : nil
        guard shown != progress else { return }
        progress = shown
        if notifying { onChange() }
    }
}
