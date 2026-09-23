import Cocoa

/// Which app a process is running inside, found by walking its parents.
///
/// A session row carries TERM_PROGRAM, and TERM_PROGRAM is a guess about the host:
/// VS Code and Cursor both report "vscode", a terminal nobody listed reports
/// whatever it likes, and a hook that could not read the variable reports nothing.
/// The agent's process tree is not a guess. Its shell was forked by the terminal
/// (or by the editor's pty host, which was forked by the editor), so the first
/// ancestor macOS knows as a regular app is the window the session is in —
/// activating *that* app by pid is strictly better than opening one by a name.
///
/// The walk is split in two on purpose. `hostPid` is pure: it takes the parent
/// relation and the "is an app" test as functions, so the tests can hand it a
/// process table that exists only in the test. `hostApplication` feeds it the
/// live answers — `sysctl` for the parent (no `ps` to spawn, cheap enough for the
/// main thread) and `NSRunningApplication` for the app test.
enum ProcessAncestry {
    /// Deep enough for any real tree (terminal ▸ login ▸ shell ▸ agent is four;
    /// an editor's pty host adds two), shallow enough that a corrupt parent
    /// relation cannot keep the walk going.
    static let maxDepth = 64

    /// The nearest process at or above `pid` that `isApp` accepts, or nil when the
    /// walk reaches launchd first. That nil is a real answer, not a failure: a tmux
    /// server daemonises to pid 1, so a session in a tmux pane has no host app in
    /// its ancestry at all — the app showing it is found through the tmux client
    /// instead (`TmuxFocus`). The agent's own pid is tested too, so an agent that
    /// is itself an app is its own host.
    static func hostPid(of pid: Int32,
                        parent: (Int32) -> Int32?,
                        isApp: (Int32) -> Bool) -> Int32? {
        for candidate in chain(from: pid, parent: parent) where isApp(candidate) {
            return candidate
        }
        return nil
    }

    /// `pid` and its ancestors, nearest first, stopping before launchd (pid 1)
    /// and the kernel (pid 0). A pid seen twice ends the walk: a parent relation
    /// read from a live table can race with pid reuse, and a loop there must not
    /// become a hang. kitty's match wants this whole list, because what it knows
    /// is the pid of the shell it forked, not of the agent the shell forked.
    static func chain(from pid: Int32, parent: (Int32) -> Int32?) -> [Int32] {
        var out: [Int32] = []
        var seen = Set<Int32>()
        var cur = pid
        while cur > 1, out.count < maxDepth, seen.insert(cur).inserted {
            out.append(cur)
            guard let next = parent(cur) else { break }
            cur = next
        }
        return out
    }

    // MARK: - Live

    /// The app hosting `pid`, or nil (no pid, a dead one, a daemonised parent).
    static func hostApplication(of pid: Int32) -> NSRunningApplication? {
        guard pid > 0,
              let host = hostPid(of: pid, parent: parentPID(of:), isApp: isRegularApp)
        else { return nil }
        return NSRunningApplication(processIdentifier: host)
    }

    /// `pid` and its live ancestors — see `chain(from:parent:)`.
    static func liveChain(from pid: Int32) -> [Int32] {
        pid > 0 ? chain(from: pid, parent: parentPID(of:)) : []
    }

    /// A regular app: one with a bundle and a Dock presence. The test is the
    /// activation policy rather than "has a bundle", because Electron editors run
    /// their pty host in a helper that is itself an `.app` inside the editor's
    /// bundle — accessory or prohibited, never regular — and bringing *that*
    /// forward would bring nothing forward.
    private static func isRegularApp(_ pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activationPolicy == .regular && app.bundleURL != nil
    }

    /// The parent pid from the kernel's process table. A size of zero after a
    /// successful call is how `sysctl` says there is no such process.
    private static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0
        else { return nil }
        return info.kp_eproc.e_ppid
    }
}
