import Foundation
import Security

/// Orbit's own Info.plist keys, written by build.sh for the agent and by Launchers for each launcher.
enum Build {
    /// The scheme of the URLs that ask Orbit for an `Action`, as in `orbit://toggle/<id>` (Info.plist registers it).
    static let scheme = "orbit"

    enum Key: String {
        /// The commit it was built from, with "+" for local changes. A launcher carries its agent's commit.
        case commit = "OrbitCommit"
        /// The git clone updates come from.
        case source = "OrbitSource"
        /// A launcher's orbit, by id.
        case task = "OrbitTask"
        /// A launcher's badge (`Glyph.Content.key`), so a changed badge gets a new icon.
        case mark = "OrbitMark"
        /// True in a build that has the App Intents metadata, so Siri and Shortcuts find its intents (`Intents`).
        case intents = "OrbitIntents"

        // What the scripts need to know too. scripts/lib.sh names each once and build.sh copies them here, so
        // Orbit and the scripts can't differ. A launcher carries its agent's.
        /// Orbit's bundle identifier. Launchers derive theirs from it, and the runtime folder is named after it.
        case identifier = "OrbitIdentifier"
        /// orbits.json.
        case config = "OrbitConfig"
        /// The folder Orbit and its launchers are installed in.
        case launchers = "OrbitLaunchers"
        /// Where an update is built before it is installed.
        case stage = "OrbitStage"
        /// The folder of the logs.
        case logs = "OrbitLogs"
        /// Launch Services' own tool, which can forget an app.
        case lsregister = "OrbitLSRegister"
        /// Xcode's page in the App Store.
        case xcode = "OrbitXcode"
        /// What Xcode was last found to be, and the files that can change that (`xcode` in scripts/lib.sh).
        case xcodeVerdict = "OrbitXcodeVerdict"
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

    /// Whether this build has the intents' metadata.
    static let intents = Bundle.main.object(forInfoDictionaryKey: Key.intents.rawValue) as? Bool ?? false

    /// The Team ID in this build's signature, which an Apple Development certificate gives it (`development_identity`
    /// in scripts/lib.sh). nil when signed with Orbit Local Signing or ad hoc.
    static let team: String? = {
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// Whether this build has Siri support: the intents' metadata, and a Team ID, without which macOS refuses to
    /// run the intents.
    static let siri = intents && team != nil

    /// The commit it was built from, without the "+".
    static let commit = (Build[.commit] ?? "").trimmingCharacters(in: ["+"])

    /// What tells this build from another: its commit, and whether it has Siri support. The update stage names
    /// its build the same way (`identity` in scripts/lib.sh).
    static let identity = commit + (siri ? " intents" : "")
}
