import Foundation

/// Siri & Shortcuts: how far this build is from having it (`Build.siri`). It takes the intents' metadata, which only
/// Xcode can add, and a signature with a Team ID, which only an Apple Development certificate gives, since macOS
/// refuses to run the intents of an app without one. Once both are ready every build gets it, and it arrives the
/// way an automatic update does (`Updater`), whatever the Updates mode, together with a new version in
/// Automatically mode. Once it is there it stays. There is nothing to turn on or off here: macOS turns an app's
/// Siri access off, in System Settings.
@MainActor
final class SiriSupport {
    enum State: Equatable {
        /// This build has it.
        case active
        /// Xcode is still being looked for.
        case looking
        case needsXcode, unlicensed
        /// Xcode is ready, but there is no Apple Development certificate to sign Orbit with, whether or not this
        /// build has the intents' metadata: without a Team ID it has no Siri support either way.
        case needsCertificate
        /// This version of Xcode failed to add it, so Orbit waits for another.
        case failed
        /// Xcode and the certificate are ready: the next build adds it.
        case adding
    }

    /// What Xcode was last found to be, and where; nil until the first look.
    private(set) var xcode: (state: Xcode, app: URL?)?
    /// Who waits for the look under way, so a look asked for meanwhile joins it; nil when none is.
    private var waiting: [@MainActor () -> Void]?

    var state: State {
        if Build.siri { return .active }
        return switch xcode?.state {
        case nil: .looking
        case .missing: .needsXcode
        case .unlicensed: .unlicensed
        case .uncertified: .needsCertificate
        case .unsupported: .failed
        case .ready: .adding
        }
    }

    /// Looks for Xcode and the certificate when it matters, that is when this build has no Siri support yet, since
    /// Xcode may have been installed, licensed or updated meanwhile, or the certificate created.
    func look(then: @escaping @MainActor () -> Void) {
        guard !Build.siri else { return then() }
        guard waiting == nil else { waiting?.append(then); return }
        waiting = [then]
        Xcode.find { [weak self] state, app in
            guard let self else { return }
            xcode = (state, app)
            let waiters = waiting ?? []
            waiting = nil
            waiters.forEach { $0() }
        }
    }
}

/// Whether this Mac can add Siri support to a build, which takes Xcode and an Apple Development certificate.
/// `xcode` in scripts/lib.sh is the one place that decides; its exit status is the answer, and it writes the answer
/// down (`Build.Key.xcodeVerdict`).
enum Xcode: Int32 {
    case ready = 0, missing
    /// Installed, but its licence is not accepted yet, so its tools refuse to run.
    case unlicensed
    /// Its tools ran and could not extract the metadata.
    case unsupported
    /// Ready, but there is no Apple Development certificate in the keychains.
    case uncertified

    /// The answer written down while it still holds, which takes a few file checks. Otherwise asks `xcode`, in
    /// the background. `app` is Xcode itself, when there is one.
    @MainActor static func find(then: @escaping @MainActor (_ state: Xcode, _ app: URL?) -> Void) {
        if let known = recorded() { return then(known.state, known.app) }
        guard let library = Bundle.main.url(forResource: "lib", withExtension: "sh") else { return then(.missing, nil) }
        let process = Process(), pipe = Pipe(), output = pipe.fileHandleForReading
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-c", "source \"$1\" && xcode", "zsh", library.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            let developer = String(decoding: output.readDataToEndOfFile(), as: UTF8.self).trimmed
            let state = Xcode(rawValue: process.terminationStatus) ?? .missing
            Task { @MainActor in then(state, developer.isEmpty ? nil : app(developer)) }
        }
        if (try? process.run()) == nil { then(.missing, nil) }
    }

    /// What `xcode` last found: its first line is the status and the developer folder, the others the files that
    /// can change the answer. It holds while none of them has changed since it was written, and its Xcode is still
    /// there.
    private static func recorded() -> (state: Xcode, app: URL?)? {
        let record = Build.path(.xcodeVerdict).path
        guard let written = changed(record),
              let lines = (try? String(contentsOfFile: record, encoding: .utf8))?.split(separator: "\n"),
              let answer = lines.first?.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false),
              let state = Int32(answer[0]).flatMap(Xcode.init),
              lines.dropFirst().allSatisfy({ (changed(String($0)) ?? 0) < written }) else { return nil }
        guard answer.count > 1, !answer[1].isEmpty else { return (state, nil) }
        let developer = String(answer[1])
        guard FileManager.default.isExecutableFile(atPath: developer + "/usr/bin/xcodebuild") else { return nil }
        return (state, app(developer))
    }

    /// When a file last changed, in seconds: its ctime, which is set whenever it is written or replaced and, unlike
    /// its modification date, can't be carried over from an archive. nil when there is no such file.
    private static func changed(_ path: String) -> Double? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1e9
    }

    /// Xcode.app, from its developer folder.
    private static func app(_ developer: String) -> URL {
        URL(filePath: developer).deletingLastPathComponent().deletingLastPathComponent()
    }
}
