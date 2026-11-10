import Foundation

/// Everything Orbit keeps in UserDefaults, each key named once.
enum Defaults {
    private static var store: UserDefaults { .standard }

    /// The order dragged in the window, by id.
    static var order: [String] {
        get { store.stringArray(forKey: "order") ?? [] }
        set { store.set(newValue, forKey: "order") }
    }

    /// Each orbit's last run by id: `code` is the exit status (-1 when stopped) and `at` is seconds since 1970.
    static var lastRun: [String: Any] {
        get { store.dictionary(forKey: "lastRun") ?? [:] }
        set { store.set(newValue, forKey: "lastRun") }
    }

    /// Orbits that have ended by themselves with exit 0, by id: what ran then (`OrbitSpec.runs`), so an edit
    /// that changes it, or a new orbit given the id, starts over.
    static var endedByItself: [String: String] {
        get { store.dictionary(forKey: "endedByItself") as? [String: String] ?? [:] }
        set { store.set(newValue, forKey: "endedByItself") }
    }

    /// Orbits whose badge is hidden from the menu bar while they run.
    static var hiddenInMenuBar: Set<String> {
        get { Set(store.stringArray(forKey: "hiddenInMenuBar") ?? []) }
        set { store.set(newValue.sorted(), forKey: "hiddenInMenuBar") }
    }

    /// The bundle id of the terminal Show Output opens in, or nil for the default.
    static var terminal: String? {
        get { store.string(forKey: "terminal") }
        set { store.set(newValue, forKey: "terminal") }
    }

    /// Whether quitting while orbits run asks for confirmation.
    static var askBeforeQuit: Bool {
        get { store.object(forKey: "askBeforeQuit") as? Bool ?? true }
        set { store.set(newValue, forKey: "askBeforeQuit") }
    }

    /// Forgets what is kept of orbits that are no longer in the config.
    static func prune(keeping ids: Set<String>) {
        let runs = lastRun, ended = endedByItself, hidden = hiddenInMenuBar, order = order
        if !Set(order).isSubset(of: ids) { self.order = order.filter(ids.contains) }
        if runs.keys.contains(where: { !ids.contains($0) }) { lastRun = runs.filter { ids.contains($0.key) } }
        if !Set(ended.keys).isSubset(of: ids) { endedByItself = ended.filter { ids.contains($0.key) } }
        if !hidden.isSubset(of: ids) { hiddenInMenuBar = hidden.intersection(ids) }
    }
}
