import AppKit
import Darwin

/// Where an orbit answers: an address of its `url`, else a port its processes listen on, found while it starts.
struct Address: Equatable, Sendable {
    enum Kind: String, Sendable { case http, https, vnc, ssh, tcp }

    let kind: Kind
    /// The URL that opens it: an http(s) url as configured, path included, else `<kind>://host:port`.
    let url: URL

    /// From orbits.json. http(s), vnc and ssh need a host; tcp needs a host and a port.
    init?(_ url: URL) {
        guard let kind = url.scheme.flatMap({ Kind(rawValue: $0.lowercased()) }), url.host() != nil,
              kind != .tcp || url.port != nil else { return nil }
        (self.kind, self.url) = (kind, url)
    }

    /// The addresses of a `url` value: one, or several separated by commas (spaces around them don't matter).
    /// A comma not followed by `scheme://` belongs to the address before it, as in `?ids=1,2`. Nil when any of
    /// them isn't an address.
    static func list(_ text: String) -> [Address]? {
        var pieces: [Substring] = []
        for piece in text.split(separator: ",", omittingEmptySubsequences: false) {
            if let last = pieces.last, !startsAddress(piece.drop { $0 == " " || $0 == "\t" }) {
                pieces[pieces.count - 1] = text[last.startIndex..<piece.endIndex]
            } else {
                pieces.append(piece)
            }
        }
        let addresses = pieces.compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)).flatMap(Address.init) }
        return addresses.count == pieces.count ? addresses : nil
    }

    /// Whether the text starts with `scheme://`.
    private static func startsAddress(_ text: Substring) -> Bool {
        guard let mark = text.range(of: "://"), let first = text.first, first.isASCII, first.isLetter else { return false }
        return text[..<mark.lowerBound].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
    }

    init(_ kind: Kind, host: String, port: Int) {
        self.kind = kind
        url = URL(string: "\(kind.rawValue)://\(host):\(port)")!
    }

    /// `localhost:8080`, ready to paste into a browser, a connect dialog or an ssh command.
    var hostname: String {
        let host = url.host().map { $0.contains(":") ? "[\($0)]" : $0 } ?? ""      // IPv6 in brackets
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// Its port, else the default of its kind.
    var port: Int { url.port ?? [.http: 80, .https: 443, .vnc: 5900, .ssh: 22][kind] ?? 0 }

    /// Host and port, with every name for this Mac as `localhost`. Orbit and its stand-in `open` use it to tell
    /// links apart, so Runtime.standIn builds it the same way.
    var key: String {
        let host = url.host()?.lowercased() ?? ""
        return "\(["127.0.0.1", "::1", "0.0.0.0", "::"].contains(host) ? "localhost" : host):\(port)"
    }

    /// The menu item that opens it, if any (none for plain tcp).
    var opener: (title: String, symbol: String)? {
        switch kind {
        case .http, .https: ("Open in Browser", "safari")
        case .vnc: ("Open Screen Sharing", "display")
        case .ssh: ("Open in Terminal", "apple.terminal")
        case .tcp: nil
        }
    }

    /// Opens it the way macOS opens its kind: a web page in the browser, vnc in Screen Sharing, ssh in a
    /// terminal. The menu, the command line and an orbit that opens its page when ready all open it here.
    @discardableResult func open() -> Bool { NSWorkspace.shared.open(url) }

    /// Whether `word` names it: its URL, or its host and port as the menu shows them.
    func named(_ word: String) -> Bool { word == url.absoluteString || word == hostname }

    var copyTitle: String { isWeb ? "Copy Hostname" : "Copy Address" }

    /// Served over HTTP: configured as http(s), or found answering HTTP.
    var isWeb: Bool { kind == .http || kind == .https }
}

/// TCP ports a process group listens on, read with libproc rather than by starting lsof.
enum Listeners {
    struct Listener: Sendable {
        let port: Int
        /// Where to connect: a loopback address for a wildcard or loopback socket, else the one it is bound to.
        let connect: String
        /// The host to display, `localhost` for this Mac.
        let host: String
    }

    /// Every listening TCP socket of the group's processes, by port.
    static func of(group: pid_t) -> [Listener] {
        var found: [Int: Listener] = [:]
        for pid in Runtime.members(group) {
            for listener in listeners(of: pid) where found[listener.port] == nil { found[listener.port] = listener }
        }
        return found.values.sorted { $0.port < $1.port }
    }

    private static func listeners(of pid: pid_t) -> [Listener] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        var result: [Listener] = []
        for fd in fds.prefix(max(0, Int(filled)) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == SOCKINFO_TCP, info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
                var address = ini.insi_laddr.ina_46.i46a_addr4
                let raw = UInt32(bigEndian: address.s_addr)
                if raw == 0 || raw >> 24 == 127 {
                    result.append(Listener(port: port, connect: "127.0.0.1", host: "localhost"))
                } else {
                    let text = numeric(AF_INET, &address)
                    result.append(Listener(port: port, connect: text, host: text))
                }
            } else if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
                var address = ini.insi_laddr.ina_6
                let text = numeric(AF_INET6, &address)
                if text == "::" || text == "::1" {
                    result.append(Listener(port: port, connect: "::1", host: "localhost"))
                } else {
                    result.append(Listener(port: port, connect: text, host: "[\(text)]"))
                }
            }
        }
        return result
    }

    private static func numeric(_ family: Int32, _ address: UnsafeRawPointer) -> String {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return inet_ntop(family, address, &text, socklen_t(text.count)).map { String(cString: $0) } ?? ""
    }
}

/// Identifies what answers on a port with one short connection. A server that speaks first is recognised by its
/// greeting (`RFB` for VNC, `SSH-` for ssh). Otherwise a minimal HTTP request is sent: an HTTP reply means http.
/// Anything else that keeps the connection open is plain tcp, TLS included: a TLS server need not serve web pages
/// (a database, a broker), so it never opens in the browser. A connection closed without a word, like an ssh tunnel
/// whose far end isn't up yet, gives nil, so ask again later. Blocks for up to about 3 s, so call it off the main
/// thread.
enum Probe {
    struct Answer: Sendable {
        let kind: Address.Kind
        /// An HTTP reply with a `Content-Type` of text/html. A dev server's other ports (live reload, an API,
        /// metrics) answer HTTP too, and only a page is worth opening by itself.
        var page = false
    }

    /// `classify` on a utility queue, keeping its blocking calls off the main thread and Swift's own threads.
    static func answer(host: String, port: Int) async -> Answer? {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async { done.resume(returning: classify(host: host, port: port)) }
        }
    }

    static func classify(host: String, port: Int) -> Answer? {
        var hints = addrinfo(ai_flags: AI_NUMERICSERV, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0 else { return nil }
        defer { freeaddrinfo(list) }
        var next = list, fd: Int32 = -1
        while let info = next?.pointee, fd < 0 {                    // try each address until one connects
            fd = connected(info)
            next = info.ai_next
        }
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        switch read(fd, ms: 300) {
        case .bytes(let head):
            return Answer(kind: head.starts(with: Array("RFB ".utf8)) ? .vnc : head.starts(with: Array("SSH-".utf8)) ? .ssh : .tcp)
        case .closed: return nil
        case .silent: break
        }
        let request = "HEAD / HTTP/1.0\r\nHost: \(host.contains(":") ? "[\(host)]" : host):\(port)\r\n\r\n"
        guard request.withCString({ send(fd, $0, strlen($0), 0) }) > 0 else { return nil }
        switch read(fd, ms: 1500) {
        case .bytes(var reply):
            guard reply.starts(with: Array("HTTP/".utf8)) else { return Answer(kind: .tcp) }
            while headerEnd(reply) == nil, reply.count < 16 << 10, case .bytes(let more) = read(fd, ms: 500) { reply += more }
            return Answer(kind: .http, page: isPage(reply))
        case .closed: return nil
        case .silent: return Answer(kind: .tcp)
        }
    }

    /// Whether a reply's headers say text/html. A server that leaves Content-Type out of its HEAD reply serves no
    /// page as far as Orbit can tell.
    static func isPage(_ reply: [UInt8]) -> Bool {
        let headers = String(decoding: reply[..<(headerEnd(reply) ?? reply.endIndex)], as: UTF8.self)
        return headers.split(whereSeparator: \.isNewline).dropFirst().contains { line in
            let (name, value) = (line.prefix { $0 != ":" }, line.drop { $0 != ":" }.dropFirst())
            let type = value.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
            return name.lowercased() == "content-type" && type == "text/html"
        }
    }

    /// Where the headers end: the index of the blank line's `\r\n\r\n`.
    private static func headerEnd(_ reply: [UInt8]) -> Int? {
        reply.indices.dropLast(3).first { reply[$0...].starts(with: [13, 10, 13, 10]) }
    }

    /// A socket connected to `info` within a second, else -1.
    private static func connected(_ info: addrinfo) -> Int32 {
        let fd = socket(info.ai_family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return -1 }
        var on: Int32 = 1, error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, length)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        if connect(fd, info.ai_addr, info.ai_addrlen) == 0
            || errno == EINPROGRESS && wait(fd, POLLOUT, ms: 1000)
               && getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0 { return fd }
        close(fd)
        return -1
    }

    private enum Reply { case bytes([UInt8]), closed, silent }

    private static func read(_ fd: Int32, ms: Int32) -> Reply {
        guard wait(fd, POLLIN, ms: ms) else { return .silent }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? .bytes(Array(buffer.prefix(count))) : .closed
    }

    private static func wait(_ fd: Int32, _ events: Int32, ms: Int32) -> Bool {
        var entry = pollfd(fd: fd, events: Int16(events), revents: 0)
        return poll(&entry, 1, ms) == 1
    }
}
