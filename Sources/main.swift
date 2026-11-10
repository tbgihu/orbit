import AppKit

// One binary, three roles:
//   Orbit.app             the agent: runs orbits, menu bar item, window, updates
//   <orbit name>.app      a Spotlight launcher (Info.plist key `OrbitTask`): asks the agent to toggle its orbit, exits
//   orbit <command>       the command line (see CLI), through the `orbit` link that `make install` creates

// Run through a link, the bundle would be the link's folder, so start again from where the link points.
if let path = Bundle.main.executablePath, (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil,
   let target = realpath(path, nil) {
    execv(target, CommandLine.unsafeArgv)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let invoked = (CommandLine.arguments.first.map { $0 as NSString })?.lastPathComponent

// Single-dash words are AppKit's own (`-AppleLanguages`), so they don't make it a command.
if invoked == "orbit" || arguments.first.map({ !$0.hasPrefix("-") || $0.hasPrefix("--") || $0.count == 2 }) == true {
    exit(MainActor.assumeIsolated { CLI.run(arguments) })
}

if let id = Build[.task] {
    let request = Action.toggle.url(id)
    if let agent = Link.Connection() {
        agent.send(request)
        if agent.next(until: Date().addingTimeInterval(10)) != nil { exit(0) }
        if !agent.closed { exit(1) }                         // it has the request but is busy; asking twice would undo it
    }
    exit(Link.launch(request) ? 0 : 1)                       // no agent runs, or it hung up on its way out
}

MainActor.assumeIsolated {
    let agent = Agent()
    NSApplication.shared.delegate = agent
    withExtendedLifetime(agent) { NSApplication.shared.run() }
}
