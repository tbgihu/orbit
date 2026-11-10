import Foundation

/// Orbit's own Info.plist keys, written by build.sh for the agent and by Launchers for each launcher.
enum Build {
    /// The scheme of the URLs that ask Orbit for an `Action`, as in `orbit://toggle/<id>` (Info.plist registers it).
    static let scheme = "orbit"

    enum Key: String {
        /// The commit it was built from, with "+" for local changes. A launcher carries its agent's commit.
        case commit = "OrbitCommit"
        /// A launcher's orbit, by id.
        case task = "OrbitTask"
        /// A launcher's badge (`Glyph.Content.key`), so a changed badge gets a new icon.
        case mark = "OrbitMark"

        // What the scripts need to know too. scripts/lib.sh names each once and build.sh copies them here, so
        // Orbit and the scripts can't differ. A launcher carries its agent's.
        /// Orbit's bundle identifier. Launchers derive theirs from it, and the runtime folder is named after it.
        case identifier = "OrbitIdentifier"
        /// orbits.json.
        case config = "OrbitConfig"
        /// The folder Orbit and its launchers are installed in.
        case launchers = "OrbitLaunchers"
        /// The folder of the logs.
        case logs = "OrbitLogs"
        /// Launch Services' own tool, which can forget an app.
        case lsregister = "OrbitLSRegister"
    }

    /// This bundle's value.
    static subscript(key: Key) -> String? { Bundle.main.object(forInfoDictionaryKey: key.rawValue) as? String }

    /// A value every build has. Orbit only runs from a bundle that build.sh made.
    static func value(_ key: Key) -> String {
        guard let value = self[key] else { fatalError("Info.plist has no \(key.rawValue). Build Orbit with scripts/build.sh.") }
        return value
    }

    /// A file or folder among those values. One that isn't a full path is in the home folder.
    static func path(_ key: Key) -> URL {
        let path = value(key)
        return path.hasPrefix("/") ? URL(filePath: path) : FileManager.default.homeDirectoryForCurrentUser.appending(path: path)
    }

    static let identifier = value(.identifier)
}
