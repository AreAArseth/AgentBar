import Foundation

/// What you decided about permission prompts, kept so the next prompt can say what
/// you did last time.
///
/// AgentBar sits in the permission path — the blocking hook is its own — which
/// means it is the only thing on the machine that can know this. Today it throws
/// every decision away the moment it is made: `RequestStore` never even learns
/// *why* a request vanished, only that it is gone. Two things become possible once
/// the decisions are kept:
///
/// - the card can say **"allowed 23× here"** at the moment you are deciding again,
///   which is the only place that fact is worth anything;
/// - the day can say how long agents spent **blocked on you**, which nothing else
///   measures because nothing else is standing at that door.
///
/// **It never decides anything itself.** A repeat count is offered next to the
/// *Always* button that was already there; the click stays yours. Since 1.28.0 one
/// thing does answer without a click — a rule the person wrote in Settings ▸
/// Approvals — and the way that stays honest is this file: every firing writes a
/// row naming the rule, and `firings(rule:in:)` is what the rules list reads back.
/// A rule is the person deciding in advance; this is where it is shown that they
/// did, and what came of it. See `RuleEngine`.
///
/// **What is not written here matters as much as what is.** `AgentActions.keystroke`
/// presses a key at a terminal for agents with no request file (Codex, Antigravity)
/// and never learns what the terminal did with it — recording that as "you allowed"
/// would be a claim this project does not get to make. So the ledger covers the
/// agents that speak `requests.d`: Claude Code and Copilot CLI. A plan approval is
/// likewise a keystroke, and likewise absent.
final class DecisionLedger {
    static let shared = DecisionLedger()

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentbar/decisions.jsonl", isDirectory: false)

    /// The same span and ceiling `history.jsonl` keeps, for the same reasons.
    static let maxAge: TimeInterval = 30 * 86_400
    static let maxRecords = 5_000

    /// On by default — unlike sounds and notifications, nothing here appears on
    /// screen unprompted. It is a switch because `display` is a line of a command
    /// somebody may have typed a secret into, and anyone who would rather not keep
    /// that deserves a first-class way not to (`agentbar forget` empties it).
    static var enabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "rememberDecisions") != nil else { return true }
            return UserDefaults.standard.bool(forKey: "rememberDecisions")
        }
        set { UserDefaults.standard.set(newValue, forKey: "rememberDecisions") }
    }

    private let url: URL
    /// Appends off the main thread, in order, exactly like `HistoryStore`: a
    /// decision is written while the user is watching the card disappear.
    private let writer = DispatchQueue(label: "agentbar.decisions", qos: .utility)

    init(url: URL = DecisionLedger.fileURL) { self.url = url }

    // MARK: - One decision

    struct Record: Equatable {
        var ts: TimeInterval = 0
        var agent = ""
        var sessionId = ""
        var project = ""
        var cwd = ""
        var tool = ""
        /// The normalised key repeats are counted by — see `shape(of:)`.
        var shape = ""
        /// The request's own one-line summary, for showing a person what a count
        /// refers to. Capped by the hook at ~60 characters before it ever gets here.
        var display = ""
        /// allow | always | deny | defer | answer
        var decision = ""
        /// How long the agent sat blocked before this landed. The half of the loop
        /// nobody measures.
        var waited: TimeInterval = 0
        /// app | cli | rule — which frontend answered, or that nobody did and a
        /// rule the human wrote answered for them.
        var via = ""
        /// The id of the rule that answered, when `via` is "rule". This is what
        /// makes a rule auditable: the row names the decision it came from, so
        /// "what did this rule ever do" is a question with an answer.
        var rule = ""

        var json: [String: Any] {
            ["v": 1, "ts": Int(ts), "agent": agent, "sessionId": sessionId,
             "project": project, "cwd": cwd, "tool": tool, "shape": shape,
             "display": display, "decision": decision,
             "waited": Int(waited.rounded()), "via": via, "rule": rule]
        }

        init() {}

        init?(jsonLine: String) {
            guard let data = jsonLine.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let shape = o["shape"] as? String, !shape.isEmpty,
                  let decision = o["decision"] as? String
            else { return nil }
            self.shape = shape
            self.decision = decision
            ts = (o["ts"] as? NSNumber)?.doubleValue ?? 0
            agent = o["agent"] as? String ?? ""
            sessionId = o["sessionId"] as? String ?? ""
            project = o["project"] as? String ?? ""
            cwd = o["cwd"] as? String ?? ""
            tool = o["tool"] as? String ?? ""
            display = o["display"] as? String ?? ""
            waited = (o["waited"] as? NSNumber)?.doubleValue ?? 0
            via = o["via"] as? String ?? ""
            rule = o["rule"] as? String ?? ""
        }
    }

    /// Records a decision that actually reached `answers.d`. Callers pass only what
    /// they already hold at the click; nothing here goes looking for more.
    func record(_ decision: String, request: ApprovalRequest, session: Session?,
                via: String = "app", rule: String = "",
                now: TimeInterval = Date().timeIntervalSince1970) {
        guard Self.enabled else { return }
        var r = Record()
        r.ts = now
        r.agent = request.agentID
        r.sessionId = request.sessionId
        r.project = session?.project ?? ""
        // The hook carries the directory since 1.28.0; the session join is the
        // fallback for a request written by an older one.
        r.cwd = request.cwd.isEmpty ? (session?.cwd ?? "") : request.cwd
        r.tool = request.toolName
        r.shape = Self.shape(of: request)
        r.display = request.display
        r.decision = decision
        // A request whose `ts` is missing or in the future contributes no wait
        // rather than a negative one that would quietly shrink the day's total.
        r.waited = request.ts > 0 ? max(0, now - request.ts) : 0
        r.via = via
        r.rule = rule
        writer.async { [url] in Self.append([r], to: url) }
    }

    func flush() { writer.sync {} }

    // MARK: - The shape a repeat is counted by

    /// The key two prompts are "the same prompt" under.
    ///
    /// It has to be coarse enough to repeat and specific enough to mean something:
    /// `git push` repeats, `git push origin feature/PR-4113` never does. It also has
    /// to be **free of arguments** — paths, URLs and flags are where a one-off
    /// lives, and where a secret would live if one ever got typed into a command.
    static func shape(of request: ApprovalRequest) -> String {
        switch request.context {
        case .bash(let command):
            return "bash:" + verb(of: command)
        default:
            break
        }
        if let path = filePath(in: request.toolInputPretty) {
            return "\(request.toolName.lowercased()):\(folder(of: path))"
        }
        return "tool:" + request.toolName
    }

    /// The first two words that matter. `git`, `npm` and friends are multiplexers —
    /// their verb is the second word, and collapsing `git push` into `git` would
    /// count a commit and a force-push as the same decision.
    static let multiplexers: Set<String> = [
        "git", "gh", "npm", "pnpm", "yarn", "bun", "cargo", "go", "docker", "kubectl",
        "brew", "make", "swift", "dotnet", "pip", "pip3", "uv", "poetry", "rails",
        "terraform", "aws", "gcloud", "systemctl", "apt", "apt-get", "flutter",
    ]

    static func verb(of command: String) -> String {
        // Only the first command of a pipeline or a chain: what follows is
        // consequence, and `cmd && rm -rf /` must never be counted as `cmd`.
        let head = command.split(whereSeparator: { "|;&\n".contains($0) }).first.map(String.init)
            ?? command
        var words = head.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // Leading environment assignments and `sudo` are how the same command
        // arrives wearing a different hat.
        while let first = words.first,
              first == "sudo" || first == "command" || first == "env"
                || (first.contains("=") && !first.hasPrefix("-")) {
            words.removeFirst()
        }
        guard let head = words.first else { return "" }
        let name = (head as NSString).lastPathComponent
        guard Self.multiplexers.contains(name) else { return name }
        // The subcommand, if there is one that isn't a flag.
        guard let next = words.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return name }
        return "\(name) \(next)"
    }

    /// Tool inputs are JSON, capped at 4 KB by the hook. Edits and writes name a
    /// file in there; nothing else needs to be understood.
    static func filePath(in toolInputPretty: String) -> String? {
        guard let data = toolInputPretty.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["file_path", "notebook_path", "path", "filePath"] {
            if let p = o[key] as? String, !p.isEmpty { return p }
        }
        return nil
    }

    /// `Sources/AgentBar/Weight.swift` → `Sources/*.swift`. A directory and an
    /// extension repeat across a session's worth of edits; a file name does not,
    /// and a full path is both a one-off and somebody's home directory.
    static func folder(of path: String) -> String {
        let ext = (path as NSString).pathExtension
        let parts = path.split(separator: "/").map(String.init)
        // The last component is the file itself; the one before it is the local
        // neighbourhood, which is what repeats.
        let dir = parts.dropLast().last ?? ""
        let suffix = ext.isEmpty ? "*" : "*.\(ext)"
        return dir.isEmpty ? suffix : "\(dir)/\(suffix)"
    }

    // MARK: - What it adds up to

    struct Summary: Equatable {
        var allowed = 0
        var denied = 0
        var lastAt: TimeInterval = 0

        var total: Int { allowed + denied }
        var isEmpty: Bool { total == 0 }
    }

    /// How this exact shape was decided before, **in this repo**. A command that is
    /// routine in one checkout can be the opposite in another, so the count is
    /// scoped by working directory and says "here" when it is shown. With no
    /// directory to scope by, everything counts — that is the honest reading of
    /// "nobody knows where this ran".
    /// Rows a rule wrote are **not** counted here. The sentence this feeds says
    /// "Allowed 23× here", which is a claim about the person — and a rule that
    /// answered for them is precisely not them deciding again. Those rows are
    /// counted by `firings(rule:in:)`, under the rule that made them.
    static func summary(shape: String, cwd: String, in records: [Record]) -> Summary {
        var out = Summary()
        for r in records where r.shape == shape && r.via != "rule"
            && (cwd.isEmpty || r.cwd == cwd) {
            switch r.decision {
            case "allow", "always": out.allowed += 1
            case "deny": out.denied += 1
            default: continue          // defer and answer are not verdicts
            }
            out.lastAt = max(out.lastAt, r.ts)
        }
        return out
    }

    /// "Allowed 23× here · last Tue". Nil below two, because "allowed 1× here" is
    /// the thing you just did and tells you nothing.
    static func hint(_ s: Summary, now: Date = Date()) -> String? {
        guard s.total >= 2 else { return nil }
        var parts: [String] = []
        if s.allowed > 0 { parts.append("Allowed \(s.allowed)×") }
        if s.denied > 0 { parts.append("denied \(s.denied)×") }
        var text = parts.joined(separator: ", ") + " here"
        if s.lastAt > 0 { text += " · last \(ago(Date(timeIntervalSince1970: s.lastAt), now: now))" }
        return text
    }

    /// A weekday inside the week, a date beyond it. "last Tue" is a memory; "last
    /// 14 days ago" is arithmetic.
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        let days = now.timeIntervalSince(d) / 86_400
        if days < 1, Calendar.current.isDate(d, inSameDayAs: now) { return "today" }
        if days < 6 { f.dateFormat = "EEE" } else { f.dateFormat = "d MMM" }
        return f.string(from: d)
    }

    /// Enough repeats, never refused, and a rule Claude Code itself suggested: the
    /// *Always* button is worth pointing at. It is still a button somebody has to
    /// press — a count is not consent.
    static let promoteAfter = 5

    static func shouldPromoteAlways(_ s: Summary, hasRule: Bool) -> Bool {
        hasRule && s.denied == 0 && s.allowed >= promoteAfter
    }

    /// Whether a rule is worth offering for this prompt, and which way it would go.
    ///
    /// Note what is NOT a condition: a `ruleSuggestion`. `shouldPromoteAlways`
    /// needs one because *Always* pins a permission Claude Code offered. A rule of
    /// ours is the opposite kind of object — it is written from what the person
    /// repeatedly did, and it must never originate in anything the agent produced.
    /// That is the same posture as never reading a token out of a record by key
    /// name: do not trust content made by the thing you are guarding.
    ///
    /// Only when the answer has been the same every single time. A prompt someone
    /// has allowed nine times and refused once is exactly the prompt that still
    /// deserves to be asked.
    static func shouldOfferRule(_ s: Summary) -> String? {
        if s.denied == 0, s.allowed >= promoteAfter { return "allow" }
        if s.allowed == 0, s.denied >= promoteAfter { return "deny" }
        return nil
    }

    /// What one rule has actually done. The rules file holds the intent and never
    /// a counter; this is where "fired 12× · last today" comes from, so the audit
    /// stays the single source of truth about what happened.
    static func firings(rule id: String, in records: [Record]) -> Summary {
        var out = Summary()
        for r in records where r.rule == id && r.via == "rule" {
            switch r.decision {
            case "allow": out.allowed += 1
            case "deny":  out.denied += 1
            default:      continue
            }
            out.lastAt = max(out.lastAt, r.ts)
        }
        return out
    }

    /// "Allowed 12× · last today" for a rule's row. Unlike `hint`, one firing is
    /// worth saying: it is the first proof the rule does what it says.
    static func firingLine(_ s: Summary, now: Date = Date()) -> String {
        guard !s.isEmpty else { return "Never fired yet" }
        var parts: [String] = []
        if s.allowed > 0 { parts.append("Allowed \(s.allowed)×") }
        if s.denied > 0 { parts.append("Denied \(s.denied)×") }
        var text = parts.joined(separator: ", ")
        if s.lastAt > 0 { text += " · last \(ago(Date(timeIntervalSince1970: s.lastAt), now: now))" }
        return text
    }

    /// How many decisions in a span were made by a rule rather than by a person.
    /// The day's account says both, because "18 answered" that quietly included
    /// six a rule made would be the wrong number in the most important place.
    static func byRules(in records: [Record], since: TimeInterval, until: TimeInterval) -> Int {
        records.filter { $0.ts >= since && $0.ts <= until && $0.via == "rule" }.count
    }

    /// How long agents sat blocked on the human over a span. The other half of the
    /// day's account: `history.jsonl` says how long the machine worked, and this
    /// says how long it waited.
    static func waiting(in records: [Record], since: TimeInterval, until: TimeInterval)
    -> (answered: Int, waited: TimeInterval) {
        var out = (answered: 0, waited: TimeInterval(0))
        // A rule answers in milliseconds and nobody was asked, so counting its
        // rows here would inflate "18 answered" with decisions the person never
        // made and deflate the average wait with times nobody waited.
        for r in records where r.ts >= since && r.ts <= until && r.via != "rule" {
            out.answered += 1
            out.waited += r.waited
        }
        return out
    }

    // MARK: - Reading and writing the file

    /// Every line that still parses, oldest first. Unlike `history.jsonl` nothing
    /// collapses here: two decisions about the same command are two decisions, and
    /// counting them is the entire point.
    static func read(url: URL = DecisionLedger.fileURL) -> [Record] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { Record(jsonLine: String($0)) }
    }

    /// `read()` memoised on `(mtime, size)`, for the same reason `HistoryStore` has
    /// one: an approval card is rebuilt about once a second while a request is open.
    static func cached(url: URL = DecisionLedger.fileURL) -> [Record] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                     (attrs?[.size] as? Int) ?? 0)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let c = cache, c.url == url.path, c.stamp == stamp { return c.records }
        let records = read(url: url)
        cache = (url.path, stamp, records)
        return records
    }

    private static let cacheLock = NSLock()
    private static var cache: (url: String, stamp: (TimeInterval, Int), records: [Record])?

    static func append(_ records: [Record], to url: URL = DecisionLedger.fileURL) {
        let lines = records.compactMap { r -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: r.json,
                                                         options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8)
            else { return nil }
            return line + "\n"
        }
        guard !lines.isEmpty, let data = lines.joined().data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // O_APPEND, like the history: the app and a CLI on a shared home must not be
        // able to truncate each other.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    static func prune(url: URL = DecisionLedger.fileURL,
                      now: TimeInterval = Date().timeIntervalSince1970) {
        let all = read(url: url)
        var kept = all.filter { now - $0.ts <= maxAge }
        if kept.count > maxRecords { kept = Array(kept.suffix(maxRecords)) }
        guard kept.count != all.count else { return }
        let body = kept.compactMap { r -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: r.json,
                                                      options: [.sortedKeys])
            else { return nil }
            return String(data: d, encoding: .utf8)
        }.joined(separator: "\n")
        try? (body.isEmpty ? "" : body + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
