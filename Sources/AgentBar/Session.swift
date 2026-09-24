import Foundation

/// One live agent session, decoded from a `~/.agentbar/state.d/*.json` file
/// written by the hook scripts in `Scripts/hooks/`.
struct Session {
    enum State: String {
        case idle, thinking, tool, permission, question, done, error

        var isWorking: Bool { self == .thinking || self == .tool }
        /// The turn is over either way; only `done` earned the celebration.
        var isFinished: Bool { self == .done || self == .error || self == .idle }
    }

    let id: String
    let agentID: String
    var state: State
    /// True when `state` was synthesized by a frontend watchdog (Antigravity's
    /// 90s quiet decay), not reported by the agent — celebrations should skip it.
    var decayed = false
    let label: String
    let project: String
    let cwd: String
    let entrypoint: String   // "cli", "claude-desktop", …
    let termProgram: String  // TERM_PROGRAM of the hosting terminal, for row clicks
    let pid: Int32           // the agent process; used for liveness pruning
    let started: Bool        // false until the session has real activity
    let ts: TimeInterval
    let startedAt: TimeInterval // 0 = the writer doesn't carry the field
    let prompt: String       // latest user prompt — names the task ("" ok)
    let model: String        // model name when the agent reports one ("" ok)
    let recap: String        // what the agent last said at turn end ("" ok)
    let activity: [String]   // the turn's recent tool steps, oldest → newest ([] ok)
    let url: String          // where the session lives when it isn't local ("" ok)
    /// Which cloud-poller adapter wrote the row ("devin", "cursor", "codex", "ssh"),
    /// "" for rows the hooks wrote on this Mac.
    let source: String
    /// The configured name of the machine a mirrored row runs on ("" ok).
    let host: String
    /// The poller could not reach the machine on its last poll: this is what it
    /// said last, not what is true now.
    let stale: Bool

    /// Runs somewhere no terminal, tab, keystroke, hook or path on this Mac can
    /// reach — a vendor's cloud, or one of the user's own machines mirrored over
    /// ssh. Every action a row offers checks this first.
    var isOffMachine: Bool { entrypoint == "cloud" }

    /// Mirrored from one of the user's own machines, not a vendor's cloud. Known
    /// by the adapter that wrote the row, never by reading its words.
    var isMirror: Bool { isOffMachine && source == "ssh" }

    /// Where an off-machine row runs, as a row may say it: the machine's name for
    /// a mirror ("Remote" when it has none), "Cloud" only for a vendor's cloud —
    /// the word implies the data left the user's machines, and for a mirror it
    /// did not. Nil for a local session.
    var placeName: String? {
        guard isOffMachine else { return nil }
        guard isMirror else { return "Cloud" }
        return host.isEmpty ? "Remote" : host
    }

    /// The sessions that happened on this Mac, for everything that records, sounds
    /// or announces: a mirrored machine's session is status, and its turns, ends
    /// and lost connections are not this Mac's events.
    static func local(_ sessions: [Session]) -> [Session] { sessions.filter { !$0.isMirror } }

    /// The label Claude Code's PreCompact hook writes while the session summarises
    /// its context (`Scripts/hooks/claude/update.js`). Not a state of its own: the
    /// row stays `thinking`, and the label carries the detail.
    static let compactingLabel = "Compacting…"
    var isCompacting: Bool { state.isWorking && label == Self.compactingLabel }

    /// Sort/priority weight: what the menu bar should surface first.
    var priority: Int {
        switch state {
        case .permission:      return 4
        case .question:        return 3
        case .thinking, .tool: return 2
        // Above the clean finishes so a failure can't be buried under them, but
        // below live work: an errored session must never take the hero slot (or
        // the mascot) from an agent that is still going.
        case .error:           return 1
        case .idle, .done:     return 0
        }
    }

    init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        id          = fileURL.deletingPathExtension().lastPathComponent
        agentID     = o["agent"] as? String ?? "claude"
        state       = State(rawValue: o["state"] as? String ?? "") ?? .idle
        label       = o["label"] as? String ?? ""
        project     = o["project"] as? String ?? ""
        cwd         = o["cwd"] as? String ?? ""
        entrypoint  = o["entrypoint"] as? String ?? ""
        termProgram = o["term_program"] as? String ?? ""
        // Third-party writers reach state.d too (the protocol invites them): an
        // out-of-range or negative pid must degrade to "no liveness handle",
        // never trap — the poisoned file survives on disk, so a trap here is a
        // crash loop that outlives every relaunch.
        pid         = max(0, Int32(exactly: o["pid"] as? Int ?? 0) ?? 0)
        started     = o["started"] as? Bool ?? true
        ts          = Self.plausibleTime(o["ts"])
        startedAt   = Self.plausibleTime(o["started_at"])
        prompt      = o["prompt"] as? String ?? ""
        model       = o["model"] as? String ?? ""
        recap       = o["recap"] as? String ?? ""
        activity    = (o["activity"] as? [String] ?? []).prefix(5).map { String($0.prefix(40)) }
        url         = o["url"] as? String ?? ""
        source      = o["source"] as? String ?? ""
        // A name a person configured, carried by a file anybody may write: one
        // short line with no control characters, or nothing.
        let rawHost = o["host"] as? String ?? ""
        host        = rawHost.count <= 24 && !rawHost.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) } ? rawHost : ""
        stale       = o["stale"] as? Bool ?? false
    }

    /// A Unix time a row may carry, or 0. `state.d` is a folder anybody may write
    /// to — the cloud poller mirrors rows from other machines into it — and every
    /// later `Int(_:)` of a time traps on a Double outside Int's range. `1e300` in
    /// one file would crash the app on every poll, and the writer rewrites it
    /// every fifteen seconds, so the crash outlives a relaunch. Checked once here,
    /// where it enters, rather than at each of the places it is converted.
    static func plausibleTime(_ raw: Any?) -> TimeInterval {
        guard let v = (raw as? NSNumber)?.doubleValue, v.isFinite, v > 0, v < 32_503_680_000
        else { return 0 }                                   // year 3000
        return v
    }

    /// "‹1m" / "28m" / "3h" / "2d" — how long the session has been going.
    /// Nil until a writer carries `started_at`, so old files render unchanged.
    var elapsed: String? {
        guard startedAt > 0 else { return nil }
        let s = Int(Date().timeIntervalSince1970 - startedAt)
        guard s >= 0 else { return nil }
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// The model, stripped of brand noise a chip has no room for:
    /// "claude-opus-5" → "opus-5". Nil when unknown.
    var modelChip: String? {
        guard !model.isEmpty else { return nil }
        var m = model.lowercased()
        for prefix in ["claude-", "anthropic/", "openai/", "google/"] where m.hasPrefix(prefix) {
            m.removeFirst(prefix.count)
        }
        return String(m.prefix(16))
    }

    /// Synthetic row for the welcome window's live preview. Never written by a
    /// hook and never reaches the stores — it exists so the preview animates the
    /// real mascot through the real driver instead of faking a picture.
    init(preview state: State, agentID: String = "claude", project: String, label: String) {
        id = "preview"
        self.agentID = agentID
        self.state = state
        self.label = label
        self.project = project
        cwd = ""
        entrypoint = ""
        termProgram = ""
        pid = 0
        started = true
        ts = Date().timeIntervalSince1970
        startedAt = 0
        prompt = ""
        model = ""
        recap = ""
        activity = []
        url = ""
        source = ""
        host = ""
        stale = false
        decayed = false
    }

    /// Current git branch of the session's project, read straight from `.git/HEAD`
    /// (no `git` invocation; handles worktrees via the `gitdir:` indirection).
    var gitBranch: String? {
        guard !cwd.isEmpty else { return nil }
        var gitPath = cwd + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { // worktree: .git is a file containing "gitdir: <path>"
            guard let s = try? String(contentsOfFile: gitPath, encoding: .utf8),
                  let dir = s.split(separator: ":").dropFirst().joined(separator: ":")
                    .trimmingCharacters(in: .whitespacesAndNewlines) as String?
            else { return nil }
            gitPath = dir
        }
        guard let head = try? String(contentsOfFile: gitPath + "/HEAD", encoding: .utf8) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: refs/heads/") {
            return String(line.dropFirst("ref: refs/heads/".count))
        }
        return String(line.prefix(7)) // detached HEAD: short SHA
    }
}
