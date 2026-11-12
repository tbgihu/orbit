import AppKit
import os

/// An orbit as it stands, for the command line: what the window and the menu show, from the same `RunStatus`.
/// This is the object `--json` prints.
struct Report: Codable {
    enum State: String, Codable, CaseIterable, Sendable { case starting, running, done, failed, stopped, new }

    let id, name: String
    let kind: OrbitSpec.Kind
    let state: State
    /// The state in the menu's words, for people.
    let status: String
    /// Where it answers while it runs, else where its `url` says it will.
    let addresses: [String]
    /// When the current run started.
    var since: Date?
    /// When the last run ended, and with what exit status if it failed.
    var ended: Date?
    var exitCode: Int32?
    /// How far a running task has got, when its command says: the running step's percentage, and with several
    /// steps, which one it is, counted from 1, and how many there are.
    var percent, step, steps: Int?
    let log: String

    var isActive: Bool { state == .starting || state == .running }

    /// The progress in words, as in "45%, step 2 of 3", or nil when there is none to tell.
    var progress: String? {
        let parts = [percent.map { "\($0)%" }, step.flatMap { step in steps.map { "step \(step) of \($0)" } }].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The orbit and its state in one line, as the command line and Siri say it.
    var sentence: String { "\(name): \(status)" }

    @MainActor init(_ orbit: OrbitSpec, _ job: Job?) {
        let status = RunStatus(orbit, job)
        (id, name, kind) = (orbit.id, orbit.name, orbit.isTask ? .task : .service)
        self.status = status.text(.menu)
        addresses = (job?.addresses ?? orbit.addresses).map(\.url.absoluteString)
        since = job?.started
        if let progress = job?.progress {
            percent = progress.percent
            if progress.steps > 1 { (step, steps) = (progress.step + 1, progress.steps) }
        }
        log = Runtime.logFile(orbit.name)
        switch status {
        case .starting: state = .starting
        case .running: state = .running
        case .done(let at): (state, ended) = (.done, at)
        case .failed(let code, let at): (state, ended, exitCode) = (.failed, at, code)
        case .stopped(let at): (state, ended) = (.stopped, at)
        case .notRun: state = .new
        }
    }
}

/// Every orbit as it stands, and what is wrong with the config if anything. The agent sends this over its socket
/// and `orbit list --json` prints it, so the two can't differ.
struct Snapshot: Codable {
    var orbits: [Report]
    var problem: String?

    /// As the agent sees it. Without `jobs` nothing runs, which is the case whenever no agent does, so the command
    /// line then makes the same snapshot itself.
    @MainActor init(_ jobs: Jobs? = nil) {
        orbits = Config.orbits.map { Report($0, jobs?[$0.id]) } + (jobs?.unlisted ?? []).map { Report($0.spec, $0) }
        problem = Config.error
    }

    private static let date = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// JSON with sorted keys and dates like 2026-01-31T09:30:00.000Z, on one line unless `pretty`.
    static func encode(_ value: some Encodable, pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.date))
        }
        return (try? encoder.encode(value)) ?? Data()
    }

    /// What `encode` wrote, or nil when it isn't that.
    static func decode<Value: Decodable>(_ data: Data) -> Value? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try Date($0.singleValueContainer().decode(String.self), strategy: Self.date) }
        return try? decoder.decode(Value.self, from: data)
    }
}

/// How launchers and the command line reach the agent: a Unix socket in the runtime folder, which only this user
/// can open, and the agent hangs up on anyone else. A client writes requests, one per line: the URL of an
/// `Action` or a `Request`, or nothing, to have the config read again. The agent answers each with a `Snapshot` on one line and sends
/// another whenever the state changes, until the client hangs up, and it stays for as long as a client is
/// connected, so every request gets its answer. The socket exists while the agent does. When
/// nobody listens, the URL goes through Launch Services instead, which starts the agent. Waiting on the socket
/// costs the agent nothing.
enum Link {
    /// The socket's address for `connect` or `bind`.
    private static func withAddress(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Bool {
        var address = sockaddr_un()
        let path = Array(Runtime.socket.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    private static func stream() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)                                // never passed on to an orbit
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Runs something that answers on another thread, and waits up to ten seconds for a yes. Launchers and
    /// the command line have nothing else to do meanwhile.
    static func awaited(_ start: (@escaping @Sendable (Bool) -> Void) -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0), answer = OSAllocatedUnfairLock(initialState: false)
        start { yes in
            answer.withLock { $0 = yes }
            done.signal()
        }
        return done.wait(timeout: .now() + 10) == .success && answer.withLock { $0 }
    }

    /// Starts the agent next to this launcher, or the one this command belongs to, with a request, activating
    /// nothing. False when Launch Services couldn't.
    static func launch(_ request: URL) -> Bool {
        let agent = Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "Orbit.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return awaited { done in
            NSWorkspace.shared.open([request], withApplicationAt: agent, configuration: configuration) { app, _ in done(app != nil) }
        }
    }

    /// The agent's end. Everything happens on the main queue and nothing blocks: a client that stops reading is
    /// dropped.
    @MainActor
    final class Server {
        private struct Client {
            let source: DispatchSourceRead
            var unread: [UInt8] = []
            /// What it was last sent, and whether it has asked since.
            var sent: Data?
            var owed = false
        }

        private let listener: DispatchSourceRead
        private var clients: [Int32: Client] = [:]
        private let state: () -> Snapshot
        private let request: (String) -> Void
        private let left: () -> Void
        /// A request is being carried out.
        private var answering = false

        /// Someone is connected, so an answer may still be owed.
        var busy: Bool { !clients.isEmpty }

        /// Listens in place of whatever a previous agent left. `left` is called when the last client has gone.
        /// Nil when the socket can't be made, and Orbit then works without it: launchers fall back to URLs.
        init?(state: @escaping () -> Snapshot, request: @escaping (String) -> Void, left: @escaping () -> Void) {
            let fd = Link.stream()
            unlink(Runtime.socket)
            guard Link.withAddress({ bind(fd, $0, $1) }), chmod(Runtime.socket, 0o600) == 0, listen(fd, 16) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                close(fd)
                return nil
            }
            (self.state, self.request, self.left) = (state, request, left)
            listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            listener.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept(fd) } }
            listener.resume()
        }

        private func accept(_ listening: Int32) {
            while case let fd = Darwin.accept(listening, nil, nil), fd >= 0 {
                var user: uid_t = 0, group: gid_t = 0
                guard getpeereid(fd, &user, &group) == 0, user == getuid() else { close(fd); continue }
                _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                var on: Int32 = 1, room: Int32 = 1 << 20                  // room for a snapshot of any size
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &room, socklen_t(MemoryLayout<Int32>.size))
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
                source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read(fd) } }
                source.setCancelHandler { close(fd) }
                source.resume()
                clients[fd] = Client(source: source)
            }
        }

        private func read(_ fd: Int32) {
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else {
                if count == 0 || errno != EAGAIN { drop(fd) }
                return
            }
            clients[fd]?.unread += bytes[..<count]
            while let unread = clients[fd]?.unread, let end = unread.firstIndex(of: 10) {
                clients[fd]?.unread.removeSubrange(...end)
                answering = true
                request(String(decoding: unread[..<end], as: UTF8.self))
                answering = false
                clients[fd]?.owed = true
                publish()
            }
            if clients[fd]?.unread.count ?? 0 > 1024 { drop(fd) }         // no request is that long
        }

        /// Sends the state to every client that asked or hasn't seen it as it is now. Not in the middle of a
        /// request, whose answer is the state once it is carried out.
        func publish() {
            guard !clients.isEmpty, !answering else { return }
            let line = Snapshot.encode(state()) + [10]
            for (fd, client) in clients where client.owed || client.sent != line {
                guard line.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == line.count else { drop(fd); continue }
                clients[fd]?.sent = line
                clients[fd]?.owed = false
            }
        }

        private func drop(_ fd: Int32) {
            clients.removeValue(forKey: fd)?.source.cancel()
            if clients.isEmpty { left() }
        }
    }

    /// A client's end, which blocks: launchers and the command line have nothing else to do.
    final class Connection {
        private let fd: Int32
        private var unread: [UInt8] = []
        /// The agent hung up, so nothing more will come.
        private(set) var closed = false

        /// Nil when no agent listens.
        init?() {
            fd = Link.stream()
            guard Link.withAddress({ connect(fd, $0, $1) }) else { close(fd); return nil }
        }

        /// After `launch`: waits up to ten seconds for the agent to listen. One that installs an update first
        /// takes longer, and the new Orbit then has the request, so the wait goes on while that is under way.
        static func awaited() -> Connection? {
            var deadline = Date().addingTimeInterval(10), tries = 0
            while Date() < deadline {
                if let connection = Connection() { return connection }
                if tries % 50 == 0, Updater.busy { deadline = Date().addingTimeInterval(10) }
                tries += 1
                usleep(10_000)
            }
            return nil
        }

        deinit { close(fd) }

        /// Sends a request: an `Action`'s URL, or nothing to only ask for the state.
        func send(_ request: URL? = nil) {
            let line = Array((request?.absoluteString ?? "").utf8) + [10]
            _ = write(fd, line, line.count)
        }

        /// The next snapshot. Nil at `deadline`, or when the agent hung up (`closed`).
        func next(until deadline: Date) -> Snapshot? {
            while true {
                if let end = unread.firstIndex(of: 10) {
                    defer { unread.removeSubrange(...end) }
                    return Snapshot.decode(Data(unread[..<end]))
                }
                var poll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { return nil }
                let ready = Darwin.poll(&poll, 1, Int32(min(left, 3600) * 1000) + 1)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else { return nil }
                var bytes = [UInt8](repeating: 0, count: 1 << 16)
                let count = read(fd, &bytes, bytes.count)
                guard count > 0 else { closed = true; return nil }
                unread += bytes[..<count]
            }
        }
    }
}
