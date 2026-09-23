import Foundation
import Testing
@testable import AgentBar

/// Jump-back beyond the three terminals that expose a tab by tty. None of this can
/// be driven against a real tmux, kitty or editor in CI, so what is tested is the
/// part that decides: reading tmux's output, choosing the client, walking a process
/// table, and — the one that is safety-critical — which hosts a keystroke may be
/// aimed at at all.
@Suite struct TerminalFocusTests {
    // MARK: - Which hosts may be typed into

    /// `canTargetTab` gates the keystroke paths. A host that cannot report which
    /// tab it brought forward must stay off it, or a keystroke meant for one
    /// session approves whatever the other tab was asking.
    @Test func onlyHostsWithAVerifiedLandingAreAimable() {
        for aimable in ["iTerm.app", "Apple_Terminal", "WezTerm", "tmux"] {
            #expect(TerminalFocus.canTargetTab(termProgram: aimable), "\(aimable)")
        }
        for blind in ["ghostty", "kitty", "vscode", "WarpTerminal", "alacritty", "zed", ""] {
            #expect(!TerminalFocus.canTargetTab(termProgram: blind), "\(blind)")
        }
    }

    // MARK: - TERM_PROGRAM to app, in one place

    /// The name `focusTerminal` opens and the name `KeystrokeApprover` waits for
    /// come from the same function, so they cannot drift apart.
    @Test func termProgramNamesTheApp() {
        #expect(TerminalApp.appName(forTermProgram: "") == "Terminal")
        #expect(TerminalApp.appName(forTermProgram: "Apple_Terminal") == "Terminal")
        #expect(TerminalApp.appName(forTermProgram: "iTerm.app") == "iTerm")
        #expect(TerminalApp.appName(forTermProgram: "WarpTerminal") == "Warp")
        #expect(TerminalApp.appName(forTermProgram: "ghostty") == "Ghostty")
        #expect(TerminalApp.appName(forTermProgram: "vscode") == "Visual Studio Code")
        #expect(TerminalApp.appName(forTermProgram: "Hyper") == "Hyper")   // verbatim
    }

    @Test func aKnownTerminalIsFoundByBundleID() {
        #expect(TerminalApp.known(bundleID: "com.googlecode.iterm2")?.termProgram == "iTerm.app")
        #expect(TerminalApp.known(bundleID: "com.apple.Terminal")?.termProgram == "Apple_Terminal")
        #expect(TerminalApp.known(bundleID: "com.microsoft.VSCode") == nil)
        #expect(TerminalApp.known(bundleID: nil) == nil)
    }

    // MARK: - tmux

    @Test func panesAreReadByTTY() throws {
        let out = "/dev/ttys004\t$0\t@1\t%1\n/dev/ttys007\t$2\t@5\t%9\n"
        let panes = TmuxFocus.parsePanes(out)
        #expect(panes.count == 2)
        let hit = try #require(TmuxFocus.pane(forTTY: "/dev/ttys007", in: panes))
        #expect(hit == TmuxFocus.Pane(tty: "/dev/ttys007", sessionID: "$2", windowID: "@5", paneID: "%9"))
        #expect(TmuxFocus.pane(forTTY: "/dev/ttys099", in: panes) == nil)
    }

    /// An older tmux prints a format variable it does not know as nothing. A line
    /// with an empty or missing field is skipped, never read with its columns
    /// shifted — a shifted line would select some other pane.
    @Test func aMalformedPaneLineIsSkipped() {
        let out = "/dev/ttys004\t$0\t@1\n/dev/ttys005\t\t@2\t%3\n\n/dev/ttys006\t$1\t@2\t%4"
        #expect(TmuxFocus.parsePanes(out) == [
            TmuxFocus.Pane(tty: "/dev/ttys006", sessionID: "$1", windowID: "@2", paneID: "%4"),
        ])
    }

    @Test func clientsAreRead() {
        let out = "/dev/ttys001\t4242\t$0\t1700000000\t0\n/dev/ttys002\tx\t$1\t1\t0\n/dev/ttys003\t77\t$1\t\t1\n"
        #expect(TmuxFocus.parseClients(out) == [
            TmuxFocus.Client(tty: "/dev/ttys001", pid: 4242, sessionID: "$0",
                             activity: 1_700_000_000, controlMode: false),
            // A pid that will not parse drops the client; a blank activity is 0.
            TmuxFocus.Client(tty: "/dev/ttys003", pid: 77, sessionID: "$1",
                             activity: 0, controlMode: true),
        ])
    }

    private let pane = TmuxFocus.Pane(tty: "/dev/ttys009", sessionID: "$2", windowID: "@5", paneID: "%9")

    private func client(_ tty: String, session: String, activity: Int, control: Bool = false) -> TmuxFocus.Client {
        TmuxFocus.Client(tty: tty, pid: 100, sessionID: session, activity: activity, controlMode: control)
    }

    /// A client already on the pane's session needs no switch, so it wins even
    /// over a client used more recently on another session.
    @Test func aClientOnThePanesSessionWins() {
        let chosen = TmuxFocus.client(for: pane, among: [
            client("/dev/ttys001", session: "$0", activity: 900),
            client("/dev/ttys002", session: "$2", activity: 100),
            client("/dev/ttys003", session: "$2", activity: 200),
        ])
        #expect(chosen?.tty == "/dev/ttys003")
    }

    @Test func withNoneAttachedTheLastUsedClientIsSwitched() throws {
        let chosen = try #require(TmuxFocus.client(for: pane, among: [
            client("/dev/ttys001", session: "$0", activity: 900),
            client("/dev/ttys002", session: "$1", activity: 100),
        ]))
        #expect(chosen.tty == "/dev/ttys001")
        #expect(TmuxFocus.commands(for: pane, client: chosen) == [
            ["switch-client", "-c", "/dev/ttys001", "-t", "$2"],
            ["select-window", "-t", "@5"],
            ["select-pane", "-t", "%9"],
        ])
    }

    /// iTerm2's `tmux -CC` gateway is a client, but its tty is a tab where keys
    /// go to tmux's command parser. It must never be the one aimed at — not even
    /// when it is the only client, and not even when it is on the right session.
    @Test func aControlModeClientIsNeverChosen() {
        #expect(TmuxFocus.client(for: pane, among: [
            client("/dev/ttys001", session: "$2", activity: 999, control: true),
        ]) == nil)
        #expect(TmuxFocus.client(for: pane, among: [
            client("/dev/ttys001", session: "$2", activity: 999, control: true),
            client("/dev/ttys002", session: "$0", activity: 1),
        ])?.tty == "/dev/ttys002")
    }

    /// A detached session still gets its pane selected — whoever attaches next
    /// lands on it — and switches no client, because there is none.
    @Test func noClientStillSelectsThePane() {
        #expect(TmuxFocus.client(for: pane, among: []) == nil)
        #expect(TmuxFocus.commands(for: pane, client: nil) == [
            ["select-window", "-t", "@5"],
            ["select-pane", "-t", "%9"],
        ])
        #expect(TmuxFocus.commands(for: pane, client: client("/dev/ttys003", session: "$2", activity: 1)) == [
            ["select-window", "-t", "@5"],
            ["select-pane", "-t", "%9"],
        ])
    }

    // MARK: - Process ancestry

    /// agent 500 ▸ shell 400 ▸ login 300 ▸ Terminal 200 ▸ launchd 1
    private let table: [Int32: Int32] = [500: 400, 400: 300, 300: 200, 200: 1]

    @Test func theNearestAppAboveTheAgentIsItsHost() {
        #expect(ProcessAncestry.hostPid(of: 500, parent: { table[$0] }, isApp: { $0 == 200 }) == 200)
        #expect(ProcessAncestry.chain(from: 500, parent: { table[$0] }) == [500, 400, 300, 200])
    }

    /// An Electron editor's pty host is a helper `.app` inside the editor — the
    /// walk passes it (the caller's test says "regular app", which it is not) and
    /// stops at the editor.
    @Test func aHelperInsideTheEditorIsWalkedPast() {
        let editor: [Int32: Int32] = [500: 450, 450: 440, 440: 300, 300: 1] // agent, shell, helper, editor
        #expect(ProcessAncestry.hostPid(of: 500, parent: { editor[$0] }, isApp: { $0 == 300 }) == 300)
    }

    /// A tmux server daemonises to launchd, so a pane's agent has no app above it.
    /// That nil is the signal to find the app through the tmux client instead.
    @Test func aDaemonisedParentHasNoHost() {
        let tmux: [Int32: Int32] = [500: 400, 400: 350, 350: 1] // agent, shell, tmux server
        #expect(ProcessAncestry.hostPid(of: 500, parent: { tmux[$0] }, isApp: { _ in false }) == nil)
        #expect(ProcessAncestry.hostPid(of: 1, parent: { _ in 0 }, isApp: { _ in true }) == nil)
        #expect(ProcessAncestry.hostPid(of: 0, parent: { _ in 0 }, isApp: { _ in true }) == nil)
    }

    /// A parent relation read from a live table can race with pid reuse. A loop
    /// in it ends the walk instead of hanging it; so does an absurd depth.
    @Test func aLoopOrAnEndlessChainEndsTheWalk() {
        let loop: [Int32: Int32] = [500: 400, 400: 500]
        #expect(ProcessAncestry.chain(from: 500, parent: { loop[$0] }) == [500, 400])
        #expect(ProcessAncestry.hostPid(of: 500, parent: { loop[$0] }, isApp: { _ in false }) == nil)
        let endless = ProcessAncestry.chain(from: 10_000, parent: { $0 + 1 })
        #expect(endless.count == ProcessAncestry.maxDepth)
    }

    // MARK: - kitty

    /// kitty knows the shell it forked, not the agent — so every ancestor is named.
    @Test func kittyIsAskedForTheWholeChain() {
        #expect(TerminalFocus.kittyMatch(pids: [500, 400, 200]) == "pid:500 or pid:400 or pid:200")
        #expect(TerminalFocus.kittyMatch(pids: []) == nil)
    }

    @Test func theHostingKittysSocketIsTriedFirst() {
        let paths = ["/tmp/mykitty-111", "/tmp/mykitty-222", "/tmp/mykitty-111"]
        #expect(TerminalFocus.orderKittySockets(paths, kittyPid: 222) == ["/tmp/mykitty-222", "/tmp/mykitty-111"])
        #expect(TerminalFocus.orderKittySockets(paths, kittyPid: nil) == ["/tmp/mykitty-111", "/tmp/mykitty-222"])
        // A pid that is the tail of another pid's digits is not that pid.
        #expect(TerminalFocus.orderKittySockets(["/tmp/k-222", "/tmp/k-22"], kittyPid: 22) == ["/tmp/k-22", "/tmp/k-222"])
    }

    // MARK: - Editors

    /// Only editors that focus an already-open folder are handed one. JetBrains
    /// would import it as a project, so it gets the app and nothing more.
    @Test func onlyFolderFocusingEditorsAreHandedTheFolder() {
        #expect(TerminalFocus.folderOpeningEditors.contains("com.microsoft.VSCode"))
        #expect(TerminalFocus.folderOpeningEditors.contains("com.todesktop.230313mzl4w4u92"))
        #expect(TerminalFocus.folderOpeningEditors.contains("dev.zed.Zed"))
        #expect(!TerminalFocus.folderOpeningEditors.contains("com.jetbrains.intellij"))
        #expect(!TerminalFocus.folderOpeningEditors.contains("com.apple.Terminal"))
    }
}
