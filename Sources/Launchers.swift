import AppKit
import CoreServices

/// The Spotlight launchers in `~/Applications/Orbit`, one app per orbit, kept in step with the config by the
/// installed agent. Each is a copy of the agent's binary whose Info.plist names its orbit (`OrbitTask`). When
/// launched it asks the agent to toggle that orbit and exits. They are apps because Spotlight ranks applications
/// first. A launcher is told apart by its id, so a renamed orbit gets a new one and the old one goes.
@MainActor
enum Launchers {
    static let folder = Build.path(.launchers)

    /// Creates missing and outdated launchers and removes those of orbits that are gone. Touches only bundles
    /// it made (marked `OrbitTask`), and only when running as the installed `~/Applications/Orbit/Orbit.app`.
    static func sync(_ orbits: [OrbitSpec]) {
        guard installed else { return }
        // one sync at a time across processes (the agent and `orbit internal sync`); the next one finds nothing to do
        let lock = open(folder.appending(path: ".sync.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX) == 0 else { return }
        defer { close(lock) }                                             // closing releases the lock
        let (stale, missing) = differences(orbits)
        unregister(stale)
        stale.forEach { try? FileManager.default.removeItem(at: $0) }
        for orbit in missing {
            do { try create(orbit) } catch { NSLog("Orbit: launcher for \(orbit.id): \(error)") }
        }
    }

    /// Runs the sync in an `orbit internal sync` child when anything needs to change, so drawing icons and signing
    /// never weigh on the agent's memory or main thread.
    static func syncInBackground(_ orbits: [OrbitSpec]) {
        guard installed, let executable = Bundle.main.executableURL else { return }
        guard syncing == nil else { resync = true; return }          // one child at a time; it rechecks once done
        let (stale, missing) = differences(orbits)
        guard !stale.isEmpty || !missing.isEmpty else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = Internal.sync.arguments()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            Task { @MainActor in
                syncing = nil
                if resync { resync = false; syncInBackground(Config.orbits) }
            }
        }
        guard (try? process.run()) != nil else { return }
        syncing = process
    }

    /// The sync child while it runs, and whether the config changed meanwhile.
    private static var syncing: Process?
    private static var resync = false

    private static var installed: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
    }

    /// Launchers to remove (outdated, of orbits that are gone, or left half-built by an interrupted sync) and
    /// orbits without a current launcher.
    private static func differences(_ orbits: [OrbitSpec]) -> (stale: [URL], missing: [OrbitSpec]) {
        guard let apps = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return ([], []) }
        var current = Set<String>(), stale: [URL] = []
        for app in apps where app.pathExtension == "app" {
            if app.lastPathComponent.hasPrefix(".") { stale.append(app); continue }      // `create`'s staging
            guard let plist = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
                  let id = plist[Build.Key.task.rawValue] as? String else { continue }
            if let orbit = orbits.first(where: { $0.id == id }), !current.contains(id),
               app.deletingPathExtension().lastPathComponent == orbit.name,
               plist[Build.Key.mark.rawValue] as? String == orbit.mark.key,
               plist[Build.Key.commit.rawValue] as? String == Build[.commit] {
                current.insert(id)
            } else {
                stale.append(app)
            }
        }
        return (stale, orbits.filter { !current.contains($0.id) })
    }

    /// Builds the launcher in a hidden folder next to its final place, signs it, then moves it in, so Spotlight and
    /// Launch Services never see a half-built app and an interrupted sync leaves nothing behind.
    private static func create(_ orbit: OrbitSpec) throws {
        let fm = FileManager.default
        let app = folder.appending(path: "\(orbit.name).app")
        let staging = folder.appending(path: ".\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: staging) }
        let contents = staging.appending(path: "Contents")
        try fm.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: Bundle.main.executableURL!, to: contents.appending(path: "MacOS/orbit-launch"))
        let agent = (Bundle.main.infoDictionary ?? [:]).filter { $0.key.hasPrefix("Orbit") }      // every `Build.Key`
        let plist = agent.merging([
            "CFBundleIdentifier": "\(Build.identifier).task.\(orbit.id)",
            "CFBundleName": orbit.name,
            "CFBundleExecutable": "orbit-launch",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": info("CFBundleShortVersionString") ?? "1.0",
            "CFBundleVersion": info("CFBundleVersion") ?? "1",
            "LSMinimumSystemVersion": info("LSMinimumSystemVersion") ?? "15.0",
            "LSUIElement": true,
            Build.Key.task.rawValue: orbit.id,
            Build.Key.mark.rawValue: orbit.mark.key,
        ]) { _, own in own }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        try Glyph.writeICNS(orbit.mark, to: contents.appending(path: "Resources/AppIcon.icns"))
        sign(staging)
        try? fm.removeItem(at: app)
        try fm.moveItem(at: staging, to: app)
        LSRegisterURL(app as CFURL, true)
    }

    /// Removes launchers from the Launch Services database, which keeps deleted apps otherwise.
    private static func unregister(_ apps: [URL]) {
        let apps = apps.filter { !$0.lastPathComponent.hasPrefix(".") }               // staging is never registered
        guard !apps.isEmpty else { return }
        let lsregister = Process()
        lsregister.executableURL = URL(filePath: Build.value(.lsregister))
        lsregister.arguments = ["-u"] + apps.map(\.path)
        lsregister.standardError = FileHandle.nullDevice
        guard (try? lsregister.run()) != nil else { return }
        lsregister.waitUntilExit()
    }

    /// Ad-hoc signing is enough. A launcher only hands a URL to Orbit.app, which is what macOS attributes
    /// permissions to and what carries Orbit's identity, so no keychain is touched here.
    private static func sign(_ app: URL) {
        let codesign = Process()
        codesign.executableURL = URL(filePath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", "--timestamp=none", app.path]
        codesign.standardError = FileHandle.nullDevice
        try? codesign.run()
        codesign.waitUntilExit()
    }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
