import Foundation

/// What each session did, kept after the session itself is gone.
///
/// `state.d/` cannot answer this. It is a *live* set: a row is deleted when its
/// process dies or its `ts` passes 24 h, so an agent that ran yesterday and exited
/// cleanly leaves nothing at all behind. That is fine for a status bar and useless
/// for two things that need a past — "when did this agent last report anything",
/// which is how a broken integration is told apart from an idle one, and any
/// account of a day's work.
///
/// So one append-only line per session in `~/.agentbar/history.jsonl`. Append-only
/// because a crash mid-write must cost at most the last line, and because the CLI
/// can append to the same file on Linux without a lock. A session is written more
/// than once — once per turn that ends, once more when it disappears — and the
/// reader keeps the **last** line for a given `sessionId`, so the newest wins and
/// duplicates are harmless rather than something to coordinate away.
///
/// Only a frontend writes here, never a hook: rule 3 says hooks exit fast, and a
/// session-ended line is exactly what several agents have no event for anyway.
final class HistoryStore {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentbar/history.jsonl", isDirectory: false)

    /// Dropped on launch. A month is long enough for "what did I do this sprint"
    /// and short enough that the file stays a file rather than an archive.
    static let maxAge: TimeInterval = 30 * 86_400
    /// A hard stop independent of age, in case a single day goes very wrong.
    static let maxRecords = 5_000

    private let url: URL
    /// The previous tick, by session id — the edge detector's left-hand side.
    private var previous: [String: Session] = [:]
    /// nil until the first tick: the launch snapshot is the baseline, not a set of
    /// sessions that just started. Same reasoning as `SessionStore.lastSnapshot`.
    private var primed = false

    init(url: URL = HistoryStore.fileURL) {
        self.url = url
    }

    /// One record. Field names match the state protocol's spelling where they overlap.
    struct Record: Equatable {
        var agent: String
        var sessionId: String
        var project: String
        var cwd: String
        var label: String
        var prompt: String
        var model: String
        var startedAt: TimeInterval
        var endedAt: TimeInterval
        var state: String
        /// True when a watchdog synthesized the end rather than the agent reporting
        /// it — a digest that counts those as clean finishes would be lying.
        var decayed: Bool

        var json: [String: Any] {
            ["v": 1, "agent": agent, "sessionId": sessionId, "project": project,
             "cwd": cwd, "label": label, "prompt": prompt, "model": model,
             "startedAt": Int(startedAt), "endedAt": Int(endedAt),
             "state": state, "decayed": decayed]
        }

        init(_ s: Session, endedAt: TimeInterval) {
            agent = s.agentID
            sessionId = s.id
            project = s.project
            cwd = s.cwd
            label = s.label
            prompt = s.prompt
            model = s.model
            startedAt = s.startedAt
            self.endedAt = endedAt
            state = s.state.rawValue
            decayed = s.decayed
        }
    }

    // MARK: - The edge detector, kept pure so it can be tested on its own

    /// Sessions that reached an end between two ticks.
    ///
    /// Two ways that happens and both count: a turn finishing (the row is still
    /// there, its state just became terminal) and the row disappearing (the process
    /// died, or the hook removed it). The first catches the data while the session
    /// is still readable; the second is the only signal several agents give at all.
    static func records(from previous: [String: Session], to current: [Session],
                        now: TimeInterval) -> [Record] {
        var out: [Record] = []
        let live = Set(current.map(\.id))

        for s in current where s.started {
            // `done` and `error` only — deliberately not `Session.State.isFinished`,
            // which also counts `idle`. Idle is "open and waiting", the state a
            // Claude session sits in between turns; treating it as an ending would
            // write a record every time someone paused to read the output.
            guard s.state == .done || s.state == .error else { continue }
            // Edge only: a row sitting in `done` for an hour must not be written on
            // every one of the 1800 ticks it survives. A session we have never seen
            // before that is already finished still counts — it ended, we just
            // missed the middle.
            let was = previous[s.id]?.state
            guard was != .done, was != .error else { continue }
            out.append(Record(s, endedAt: s.ts > 0 ? s.ts : now))
        }
        for (id, s) in previous where !live.contains(id) {
            guard s.started else { continue }
            out.append(Record(s, endedAt: s.ts > 0 ? s.ts : now))
        }
        // Stable order so a tick that ends several sessions writes them predictably.
        return out.sorted { ($0.endedAt, $0.sessionId) < ($1.endedAt, $1.sessionId) }
    }

    // MARK: - Wiring

    func observe(_ sessions: [Session]) {
        defer { previous = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
        guard primed else { primed = true; return }
        let due = Self.records(from: previous, to: sessions, now: Date().timeIntervalSince1970)
        guard !due.isEmpty else { return }
        append(due)
    }

    private func append(_ records: [Record]) {
        let lines = records.compactMap { r -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: r.json, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8)
            else { return nil }
            return line + "\n"
        }
        guard !lines.isEmpty, let data = lines.joined().data(using: .utf8) else { return }

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // O_APPEND, not read-modify-write: two frontends (the app and `agentbar
        // watch` on a shared home) must not be able to truncate each other, and a
        // line-sized append is atomic.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    // MARK: - Reading and pruning

    /// Every line that still parses, oldest first, one entry per `sessionId` — the
    /// last line for an id wins, which is how a re-written session collapses.
    static func read(url: URL = HistoryStore.fileURL) -> [Record] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var byID: [String: Record] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let r = Record(jsonLine: String(line)) else { continue }  // a torn line is skipped, not fatal
            if byID[r.sessionId] == nil { order.append(r.sessionId) }
            byID[r.sessionId] = r
        }
        return order.compactMap { byID[$0] }
    }

    /// Called once on launch. Rewrites the file only when something actually goes,
    /// so the common case costs a read and nothing else.
    static func prune(url: URL = HistoryStore.fileURL, now: TimeInterval = Date().timeIntervalSince1970) {
        let all = read(url: url)
        var kept = all.filter { now - $0.endedAt <= maxAge }
        if kept.count > maxRecords { kept = Array(kept.suffix(maxRecords)) }
        guard kept.count != all.count else { return }

        let body = kept.compactMap { r -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: r.json, options: [.sortedKeys])
            else { return nil }
            return String(data: d, encoding: .utf8)
        }.joined(separator: "\n")
        try? (body.isEmpty ? "" : body + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

extension HistoryStore.Record {
    init?(jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agent = o["agent"] as? String,
              let sessionId = o["sessionId"] as? String
        else { return nil }
        self.agent = agent
        self.sessionId = sessionId
        project = o["project"] as? String ?? ""
        cwd = o["cwd"] as? String ?? ""
        label = o["label"] as? String ?? ""
        prompt = o["prompt"] as? String ?? ""
        model = o["model"] as? String ?? ""
        startedAt = (o["startedAt"] as? NSNumber)?.doubleValue ?? 0
        endedAt = (o["endedAt"] as? NSNumber)?.doubleValue ?? 0
        state = o["state"] as? String ?? ""
        decayed = o["decayed"] as? Bool ?? false
    }
}
