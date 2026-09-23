import Cocoa

/// Known terminal apps: display name, bundle identifier, and the TERM_PROGRAM value
/// their sessions report (used to auto-pick a default from real usage).
struct TerminalApp {
    let name: String
    let bundleID: String
    let termProgram: String

    static let known: [TerminalApp] = [
        TerminalApp(name: "Terminal",  bundleID: "com.apple.Terminal",        termProgram: "Apple_Terminal"),
        TerminalApp(name: "iTerm",     bundleID: "com.googlecode.iterm2",     termProgram: "iTerm.app"),
        TerminalApp(name: "Warp",      bundleID: "dev.warp.Warp-Stable",      termProgram: "WarpTerminal"),
        TerminalApp(name: "Ghostty",   bundleID: "com.mitchellh.ghostty",     termProgram: "ghostty"),
        TerminalApp(name: "WezTerm",   bundleID: "com.github.wez.wezterm",    termProgram: "WezTerm"),
        TerminalApp(name: "kitty",     bundleID: "net.kovidgoyal.kitty",      termProgram: "kitty"),
        TerminalApp(name: "Alacritty", bundleID: "org.alacritty",             termProgram: "alacritty"),
    ]

    /// TERM_PROGRAM values of hosts that run a terminal without being one, so they
    /// have no place in `known` (which is also the Open ▸ Terminal picker): VS Code's
    /// integrated terminal says "vscode", and so does Cursor's, which is why a row
    /// click resolves the real host by process ancestry before it ever uses this
    /// name (`ProcessAncestry.hostApplication`).
    private static let hostedTermPrograms: [String: String] = [
        "vscode": "Visual Studio Code",
    ]

    /// The app a TERM_PROGRAM value names — **the one place that mapping lives**.
    /// `AgentActions.focusTerminal` opens it, `KeystrokeApprover` checks that it is
    /// the frontmost app before it types, and those two must never disagree, or a
    /// keystroke waits for an app that was never asked to come forward. An empty
    /// value (a hook that could not read the variable) means Terminal, which is what
    /// macOS opens a bare shell in; an unknown one is used verbatim, since most
    /// terminals report their own name (Hyper, Tabby, …).
    static func appName(forTermProgram termProgram: String) -> String {
        if termProgram.isEmpty { return "Terminal" }
        if let hit = known.first(where: { $0.termProgram == termProgram }) { return hit.name }
        return hostedTermPrograms[termProgram] ?? termProgram
    }

    /// The known terminal a running app is, by bundle identifier — how a tmux
    /// client's outer window is recognised once process ancestry has found it.
    static func known(bundleID: String?) -> TerminalApp? {
        guard let bundleID else { return nil }
        return known.first { $0.bundleID == bundleID }
    }

    /// Terminals actually present on this Mac, in `known` order.
    static var installed: [TerminalApp] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// The terminal Open actions use. Explicit user choice wins; otherwise the terminal
    /// hosting the most recent CLI session; otherwise the first installed one.
    static func preferred(sessions: [Session]) -> TerminalApp {
        let d = UserDefaults.standard
        if let chosen = d.string(forKey: "preferredTerminal"),
           let hit = installed.first(where: { $0.bundleID == chosen }) {
            return hit
        }
        if let recent = sessions.max(by: { $0.ts < $1.ts })?.termProgram,
           let hit = installed.first(where: { $0.termProgram == recent }) {
            return hit
        }
        return installed.first ?? known[0]
    }

    static func setPreferred(_ terminal: TerminalApp) {
        UserDefaults.standard.set(terminal.bundleID, forKey: "preferredTerminal")
    }

    func open() {
        let ws = NSWorkspace.shared
        guard let url = ws.urlForApplication(withBundleIdentifier: bundleID) else { return }
        ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
