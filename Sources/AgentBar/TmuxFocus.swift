import Foundation

/// Jump-back through tmux: make the session's pane the one its window shows, and
/// that window the one a client shows, then report which client that was so the
/// caller can bring the terminal hosting it forward.
///
/// A session inside tmux defeats every other targeting path. Its tty is a pty the
/// tmux *server* owns, and the server daemonised away from the terminal it was
/// started in, so no terminal's tab list carries that tty and the agent's process
/// ancestry ends at launchd without passing an app. What does connect the two is
/// the tmux client: a process running in an ordinary terminal tab, with that tab's
/// tty, attached to a session. So the path is pane tty ▸ pane ▸ session ▸ client ▸
/// client pid ▸ the app hosting it ▸ the tab with the client's tty.
///
/// Parsing and choosing are pure static functions over tmux's own output, so the
/// tests can feed them text; only `focus(tty:)` talks to a server.
enum TmuxFocus {
    struct Pane: Equatable {
        let tty: String
        let sessionID: String   // "$3" — ids, not names: a name can hold anything
        let windowID: String    // "@7"
        let paneID: String      // "%12"
    }

    struct Client: Equatable {
        let tty: String
        let pid: Int32
        let sessionID: String
        let activity: Int       // epoch seconds of the client's last input
        let controlMode: Bool   // iTerm2's `tmux -CC` gateway, not a screen
    }

    /// What happened. `paneSelected` alone is worth something (the pane is in
    /// front the next time anybody looks); only with a `client` is there a
    /// terminal tab to bring forward.
    struct Outcome: Equatable {
        let paneSelected: Bool
        let client: Client?
    }

    /// Tab-separated, because a tab is the one character none of these fields can
    /// contain; ids rather than names for the same reason.
    static let paneFormat = "#{pane_tty}\t#{session_id}\t#{window_id}\t#{pane_id}"
    static let clientFormat =
        "#{client_tty}\t#{client_pid}\t#{session_id}\t#{client_activity}\t#{client_control_mode}"

    // MARK: - Pure

    /// Every well-formed line of `list-panes -a -F paneFormat`. A line with the
    /// wrong number of fields is skipped rather than guessed at — an older tmux
    /// that does not know a format variable prints it empty, not absent.
    static func parsePanes(_ output: String) -> [Pane] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, f.allSatisfy({ !$0.isEmpty }) else { return nil }
            return Pane(tty: f[0], sessionID: f[1], windowID: f[2], paneID: f[3])
        }
    }

    static func pane(forTTY tty: String, in panes: [Pane]) -> Pane? {
        panes.first { $0.tty == tty }
    }

    /// Every well-formed line of `list-clients -F clientFormat`. A client with no
    /// readable pid is dropped: without it there is no app to find.
    static func parseClients(_ output: String) -> [Client] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5, !f[0].isEmpty, !f[2].isEmpty,
                  let pid = Int32(f[1]), pid > 0 else { return nil }
            return Client(tty: f[0], pid: pid, sessionID: f[2],
                          activity: Int(f[3]) ?? 0, controlMode: f[4] == "1")
        }
    }

    /// The client to show the pane in. One already attached to the pane's session
    /// needs no switch, so it wins; among several, the one used last is the one
    /// the user is most likely looking at. With none attached, the most recently
    /// used client is switched over — it is the screen the user was just on.
    /// A control-mode client is never chosen: its tty is iTerm2's gateway tab,
    /// and keys typed there go to tmux's command parser, not to the pane.
    static func client(for pane: Pane, among clients: [Client]) -> Client? {
        let screens = clients.filter { !$0.controlMode }
        let attached = screens.filter { $0.sessionID == pane.sessionID }
        return (attached.isEmpty ? screens : attached).max { $0.activity < $1.activity }
    }

    /// The tmux commands that put `pane` in front of `client`, in order: switch
    /// the client's session first (only when it is on another one), then the
    /// window, then the pane. Without a client the pane is still selected, so
    /// whoever attaches next lands on it.
    static func commands(for pane: Pane, client: Client?) -> [[String]] {
        var out: [[String]] = []
        if let client, client.sessionID != pane.sessionID {
            out.append(["switch-client", "-c", client.tty, "-t", pane.sessionID])
        }
        out.append(["select-window", "-t", pane.windowID])
        out.append(["select-pane", "-t", pane.paneID])
        return out
    }

    // MARK: - Live

    /// A GUI app has no PATH worth the name, so the usual installs are tried in
    /// turn: Homebrew on Apple silicon, Homebrew on Intel, MacPorts, the system.
    private static let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux",
                                     "/opt/local/bin/tmux", "/usr/bin/tmux"]

    /// Select the pane whose tty is `tty`. Nil means `tty` is not a tmux pane on
    /// any server this user runs (or tmux is not installed) — the caller then
    /// carries on with the ordinary terminal paths. Non-nil means it is one, and
    /// no terminal's own tab list will ever match it, whatever came of the select.
    static func focus(tty: String) -> Outcome? {
        guard let tmux = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        for socket in sockets() {
            guard let out = TerminalFocus.run(tmux, ["-S", socket, "list-panes", "-a", "-F", paneFormat]),
                  let pane = pane(forTTY: tty, in: parsePanes(out))
            else { continue }
            let clients = TerminalFocus.run(tmux, ["-S", socket, "list-clients", "-F", clientFormat])
                .map(parseClients) ?? []
            let chosen = client(for: pane, among: clients)
            let selected = commands(for: pane, client: chosen).allSatisfy {
                TerminalFocus.run(tmux, ["-S", socket] + $0) != nil
            }
            return Outcome(paneSelected: selected, client: selected ? chosen : nil)
        }
        return nil
    }

    /// The server sockets in this user's tmux directory — `default`, plus one per
    /// `tmux -L name`. Asked of each by `-S` because AgentBar never has the `TMUX`
    /// variable that would say which one. A server started with `-S` somewhere
    /// else entirely is not found; nothing on disk points at it. When the
    /// directory does not exist no tmux runs, and not a single process is spawned.
    private static func sockets() -> [String] {
        let base = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/tmp"
        let dir = URL(fileURLWithPath: base).appendingPathComponent("tmux-\(getuid())")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let rank = { (name: String) in (name == "default" ? 0 : 1, name) }  // usual server first
        return names.sorted { rank($0) < rank($1) }
            .map { dir.appendingPathComponent($0).path }
            .filter { (try? fm.attributesOfItem(atPath: $0)[.type] as? FileAttributeType) == .typeSocket }
    }
}
