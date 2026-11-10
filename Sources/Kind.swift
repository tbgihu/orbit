import Foundation

/// Whether an orbit is a service (runs until stopped) or a task (ends by itself) when orbits.json doesn't say.
/// There's no way to know in advance whether a program ends, so this goes by the strongest evidence first:
///
/// 1. its command: `rsync`, `curl`, `make`… end; `caffeinate`, an `ssh` tunnel, `http.server`… don't, even when
///    one has ended with exit 0 because its connection closed;
/// 2. it has ended by itself with exit 0 before, running what it runs now: a task;
/// 3. otherwise a service when it has a `url`, else a task.
@MainActor
enum KindGuess {
    static func resolve(_ orbit: OrbitSpec) -> OrbitSpec.Kind {
        if let command = orbit.command, let kind = guess(command) { kind }
        else if Defaults.endedByItself[orbit.id] == orbit.runs { .task }
        else { orbit.url == nil ? .task : .service }
    }

    // MARK: From the command

    /// Programs that run to completion.
    private static let tasks: Set<String> = [
        "rsync", "cp", "scp", "sftp", "ditto", "mv", "rm", "mkdir", "ln", "touch", "tar", "zip", "unzip", "gzip",
        "gunzip", "xz", "zstd", "curl", "wget", "git", "brew", "port", "make", "cmake", "ninja", "xcodebuild",
        "pip", "pip3", "pipx", "uv", "poetry", "cargo", "go", "swift", "osascript", "shortcuts", "automator",
        "sleep", "say", "find", "du", "df", "ffmpeg", "magick", "convert", "sips", "pandoc", "latexmk", "restic",
        "borg", "duplicity", "tmutil", "softwareupdate", "diskutil", "hdiutil", "mdutil", "open", "afplay",
        "true", "false", "echo", "printf", "date", "launchctl", "defaults", "killall", "pkill",
    ]

    /// Programs that run until stopped.
    private static let services: Set<String> = [
        "caffeinate", "autossh", "ngrok", "cloudflared", "tailscale", "jupyter", "jupyter-lab", "jupyter-notebook",
        "http-server", "serve", "live-server", "vite", "nodemon", "watchman", "fswatch", "entr", "watch", "top",
        "htop", "btop", "ollama", "redis-server", "postgres", "mongod", "nginx", "httpd", "caddy", "mkdocs",
        "hugo", "jekyll", "uvicorn", "gunicorn", "flask", "streamlit", "gradio", "tensorboard", "syncthing",
    ]

    private static func guess(_ command: String) -> OrbitSpec.Kind? {
        // the last step of a chain decides: `sleep 1500 && osascript …` ends, `cd x && python3 -m http.server` doesn't
        guard let words = Shell.steps(command)?.last?.last, let index = Launch.program(words),
              let program = words[index].name else { return nil }
        let rest = words[(index + 1)...].map { $0.value ?? "" }
        let args = Set(rest), line = rest.joined(separator: " ")

        switch program {
        case "ssh":                                                       // a tunnel runs until stopped
            return args.contains { $0.hasPrefix("-L") || $0.hasPrefix("-R") || $0.hasPrefix("-D") || $0 == "-N" }
                ? .service : .task
        case "python", "python3":
            if line.contains("http.server") || line.contains("-m jupyter") || line.contains("-m streamlit") { return .service }
            return nil
        case "npm", "pnpm", "yarn", "bun":
            if args.contains("dev") || args.contains("start") || args.contains("serve") || args.contains("preview") { return .service }
            if args.contains("install") || args.contains("ci") || args.contains("build") || args.contains("test") { return .task }
            return nil
        case "docker":
            if args.contains("up") || args.contains("run") { return args.contains("-d") ? .task : .service }
            return .task
        case "rclone":
            return args.contains("serve") || args.contains("mount") ? .service : .task
        case "tail", "less":
            return args.contains("-f") || args.contains("-F") ? .service : .task
        case "log":
            return args.contains("stream") ? .service : .task
        case "ping":
            return args.contains("-c") ? .task : .service
        default:
            if services.contains(program) { return .service }
            if tasks.contains(program) { return .task }
            return nil
        }
    }
}
