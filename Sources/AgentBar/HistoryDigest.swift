import Foundation

/// What your agents did today, read back out of `history.jsonl`.
///
/// The menu bar answers "what is happening"; this answers "what happened", which
/// is the question you have at the end of a day and which nothing in AgentBar
/// could answer before — `state.d` deletes a session the moment its process dies.
///
/// Pure functions over already-loaded records: no file watching, no store, no
/// state. The menu reads it when it opens and the CLI when it is asked, which is
/// as often as a digest needs recomputing.
enum HistoryDigest {
    struct Entry: Equatable {
        let agent: String
        let project: String
        let cwd: String
        let state: String
        let startedAt: TimeInterval
        let endedAt: TimeInterval
        /// Nil when the writer never carried `started_at` — older rows, and agents
        /// that report no session start at all. A duration guessed from one
        /// timestamp would be a fabrication.
        var duration: TimeInterval? {
            guard startedAt > 0, endedAt >= startedAt else { return nil }
            return endedAt - startedAt
        }
        var failed: Bool { state == "error" }
    }

    struct Summary: Equatable {
        var sessions = 0
        var failed = 0
        /// Summed over the entries that *have* a duration, and `measured` says how
        /// many those were — "3h 40m" over 12 sessions when only 4 were timed would
        /// read as a total it is not.
        var seconds: TimeInterval = 0
        var measured = 0

        var isEmpty: Bool { sessions == 0 }
    }

    /// Everything that ended since local midnight, newest first.
    ///
    /// Local midnight, not "the last 24 hours": a digest called Today that starts
    /// counting from whenever you happen to look at it is not a day.
    static func today(_ records: [HistoryStore.Record],
                      now: TimeInterval = Date().timeIntervalSince1970,
                      calendar: Calendar = .current) -> (Summary, [Entry]) {
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        return digest(records, since: midnight, until: now)
    }

    static func digest(_ records: [HistoryStore.Record],
                       since: TimeInterval, until: TimeInterval) -> (Summary, [Entry]) {
        let entries = records
            .filter { $0.endedAt >= since && $0.endedAt <= until }
            .sorted { $0.endedAt > $1.endedAt }
            .map { Entry(agent: $0.agent, project: $0.project, cwd: $0.cwd, state: $0.state,
                         startedAt: $0.startedAt, endedAt: $0.endedAt) }

        var summary = Summary()
        summary.sessions = entries.count
        summary.failed = entries.filter(\.failed).count
        for d in entries.compactMap(\.duration) {
            summary.seconds += d
            summary.measured += 1
        }
        return (summary, entries)
    }

    /// "12 sessions · 3h 40m · 1 failed" — the one line the menu row carries.
    /// Each clause is dropped when it would say nothing rather than shown as zero.
    static func headline(_ s: Summary) -> String {
        guard !s.isEmpty else { return "Nothing finished yet today" }
        var parts = ["\(s.sessions) session\(s.sessions == 1 ? "" : "s")"]
        // Only when every session was timed. A partial total presented as the day's
        // work is a number someone would quote.
        if s.measured == s.sessions, s.seconds > 0 { parts.append(duration(s.seconds)) }
        else if s.measured > 0 { parts.append("\(duration(s.seconds)) across \(s.measured)") }
        if s.failed > 0 { parts.append("\(s.failed) failed") }
        return parts.joined(separator: " · ")
    }

    /// "3h 40m" / "12m" / "<1m" — the same vocabulary `Session.elapsed` uses, so the
    /// live rows and the digest do not describe time two different ways.
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(s / 60)m" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// One row: "AgentBar · 34m" — or just the project when it was never timed.
    static func line(_ e: Entry) -> String {
        let who = e.project.isEmpty ? Agent.byID(e.agent).name : e.project
        guard let d = e.duration else { return who }
        return "\(who) · \(duration(d))"
    }
}
