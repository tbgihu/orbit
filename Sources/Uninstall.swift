import Foundation

/// Uninstall Orbit in Settings. What gets removed is listed once, in `scripts/uninstall.sh`, which `make uninstall`
/// runs too. build.sh puts the script in the bundle, so Settings can run it even after the clone moved or was deleted.
enum Uninstall {
    static let script = Bundle.main.url(forResource: "uninstall", withExtension: "sh")

    /// Starts the script, which waits for this process to exit (`ORBIT_UNINSTALL_AFTER`), then deletes Orbit's code,
    /// its clone included, and all its data without asking again (`--yes`): Settings has asked. The caller quits
    /// right after. zsh keeps the script open, so the script runs to its end while its own bundle is deleted.
    /// False when it could not start.
    static func start() -> Bool {
        guard let script else { return false }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = [script.path, "--yes"]
        process.environment = ProcessInfo.processInfo.environment
            .merging(["ORBIT_UNINSTALL_AFTER": String(getpid())]) { _, after in after }
        process.currentDirectoryURL = URL(filePath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }
}
