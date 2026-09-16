import Foundation
import SQLite3

/// What a session cost, read out of the agent's own local files.
///
/// Three of the ten agents keep an honest per-session number on disk and the other
/// seven keep nothing, so the type has to make "we could not measure this" a first
/// class answer rather than a zero. Every reader here returns `nil` on a miss; none
/// of them estimates, and none of them touches the network.
///
/// **The four components are stored separately on purpose.** The agents do not agree
/// on what "tokens" means: Claude's `usage` reports cache reads alongside the rest,
/// Codex folds cached input *into* its input count, Copilot keeps every category
/// apart. On one real session the difference between including cache reads and not
/// is 2.1 M against 222.9 M — a hundred-fold, from one definitional choice. Summing
/// them into a single integer at the point of writing would bake that choice into the
/// file where nobody could see it.
struct Weight: Equatable {
    /// Fresh input: prompt tokens that were not served from the cache.
    var input = 0
    /// Everything the model produced, reasoning included where the agent reports it.
    var output = 0
    /// Tokens written into the prompt cache.
    var cacheWrite = 0
    /// Tokens served from the prompt cache. Enormous, and not what a turn spends.
    var cacheRead = 0
    /// Which reader produced this, so a surprising number can be traced to a file.
    var source = ""

    /// The number the UI shows. Cache reads are left out: they dwarf everything else
    /// and reflect how long a conversation is, not how much work it did. This is the
    /// same formula `UsageCenter` already uses for the island's Claude line, so the
    /// live quota and the day's account cannot quietly disagree.
    var total: Int { input + output + cacheWrite }

    var isEmpty: Bool { input == 0 && output == 0 && cacheWrite == 0 && cacheRead == 0 }

    static func + (a: Weight, b: Weight) -> Weight {
        Weight(input: a.input + b.input, output: a.output + b.output,
               cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead,
               source: a.source.isEmpty ? b.source : a.source)
    }

    var json: [String: Any] {
        ["in": input, "out": output, "cacheWrite": cacheWrite, "cacheRead": cacheRead,
         "src": source]
    }

    init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0,
         source: String = "") {
        self.input = input; self.output = output
        self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
        self.source = source
    }

    init?(json: Any?) {
        guard let o = json as? [String: Any] else { return nil }
        input = (o["in"] as? NSNumber)?.intValue ?? 0
        output = (o["out"] as? NSNumber)?.intValue ?? 0
        cacheWrite = (o["cacheWrite"] as? NSNumber)?.intValue ?? 0
        cacheRead = (o["cacheRead"] as? NSNumber)?.intValue ?? 0
        source = o["src"] as? String ?? ""
    }
}

enum WeightReader {
    /// The one entry point. `agent` and `sessionId` come straight off the history
    /// record; `cwd` only fast-paths Claude's transcript lookup.
    ///
    /// Blocking file I/O — call it off the main queue. `HistoryStore` does.
    static func read(agent: String, sessionId: String, cwd: String) -> Weight? {
        switch agent {
        case "claude": return claude(sessionId: sessionId, cwd: cwd)
        case "codex": return codex(sessionId: sessionId)
        case "copilot": return copilot(sessionId: sessionId)
        default: return nil
        }
    }

    // MARK: - The shared transcript decode

    /// The four numbers one assistant transcript line reports.
    ///
    /// The **only** place `message.usage` is decoded. `UsageCenter` sums it over a
    /// rolling five-hour window and this file sums it over one session; two copies of
    /// these field names would drift the moment a provider adds a fifth category.
    ///
    /// Returns nil for every line that is not an assistant message carrying usage —
    /// which is most of them.
    static func usage(inLine o: [String: Any]) -> (id: String?, at: Date?, weight: Weight)? {
        guard o["type"] as? String == "assistant",
              let message = o["message"] as? [String: Any],
              let u = message["usage"] as? [String: Any]
        else { return nil }
        let w = Weight(input: u["input_tokens"] as? Int ?? 0,
                       output: u["output_tokens"] as? Int ?? 0,
                       cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0,
                       cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                       source: "claude-transcript")
        let at = (o["timestamp"] as? String).flatMap(parseISO)
        return (message["id"] as? String, at, w)
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    static func parseISO(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }

    // MARK: - Claude Code

    /// Every `~/.claude*` directory that holds a `projects/` folder, symlink-resolved
    /// and deduped.
    ///
    /// Globbed rather than listed, because the split-config layouts are named by
    /// whoever set them up: this machine has `.claude`, `.claude-work`,
    /// `.claude-personal` **and** `.claude-science`, and a hard-coded list of three
    /// silently ignored the fourth. Resolution matters because these are commonly
    /// symlinked to one another, and enumerating the same transcripts under two path
    /// strings counted every token twice.
    static func claudeRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let fm = FileManager.default
        var seen = Set<String>()
        return claudeConfigDirs(home: home)
            .map { $0.appendingPathComponent("projects") }
            .filter { fm.fileExists(atPath: $0.path) }
            .map { $0.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
    }

    /// Every Claude Code config directory on the machine, transcripts or not —
    /// `~/.claude` plus any `~/.claude-<something>` a `CLAUDE_CONFIG_DIR` created.
    /// `claudeRoots` is this list narrowed to the ones holding transcripts; things
    /// that live beside the transcripts (the credential file, the version marker)
    /// need the unnarrowed one. One rule for "where does Claude Code live", in one
    /// place, because two would disagree the first time someone adds a suffix.
    static func claudeConfigDirs(home: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: home.path) else { return [] }
        return items
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
            .sorted()
            .map { home.appendingPathComponent($0) }
    }

    /// Claude Code's session id **is** its transcript's file name — verified against
    /// every transcript on the machine that wrote this. So the lookup is exact, with
    /// no matching heuristics: derive the project slug from `cwd` for the common case,
    /// and fall back to walking the project folders when that does not land (a session
    /// that moved, or a slug rule that changed).
    static func transcript(sessionId: String, cwd: String,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let fm = FileManager.default
        let roots = claudeRoots(home: home)
        let file = sessionId + ".jsonl"

        if !cwd.isEmpty {
            let slug = slugify(cwd)
            for root in roots {
                let guess = root.appendingPathComponent(slug).appendingPathComponent(file)
                if fm.fileExists(atPath: guess.path) { return guess }
            }
        }
        for root in roots {
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                         options: .skipsHiddenFiles)
            else { continue }
            for dir in dirs {
                let candidate = dir.appendingPathComponent(file)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    /// `/Users/me/src/My App` → `-Users-me-src-My-App`. Claude Code's own rule for
    /// naming a project folder: every character that is not a letter, digit or
    /// underscore becomes a dash.
    static func slugify(_ path: String) -> String {
        String(path.map { c in
            c.isLetter || c.isNumber || c == "_" ? c : "-"
        })
    }

    private static let cacheLock = NSLock()
    /// Per transcript: how far we have read, the running total, and the message ids
    /// already counted. A session is written to `history.jsonl` once per turn, so
    /// without this the last turn of a long session re-parses tens of megabytes.
    private static var claudeCache: [String: (offset: UInt64, weight: Weight, seen: Set<String>)] = [:]

    static func claude(sessionId: String, cwd: String,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Weight? {
        guard let url = transcript(sessionId: sessionId, cwd: cwd, home: home) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = UInt64((attrs?[.size] as? NSNumber)?.int64Value ?? 0)

        cacheLock.lock()
        var state = claudeCache[url.path] ?? (offset: 0, weight: Weight(), seen: [])
        cacheLock.unlock()
        // A transcript that shrank was replaced, not appended to; start over.
        if state.offset > size { state = (0, Weight(), []) }

        if state.offset < size {
            let (w, ids, consumed) = scan(url, from: state.offset, skipping: state.seen)
            state.weight = state.weight + w
            state.seen.formUnion(ids)
            state.offset += consumed
        }

        cacheLock.lock()
        claudeCache[url.path] = state
        cacheLock.unlock()

        guard !state.weight.isEmpty else { return nil }
        var out = state.weight
        out.source = "claude-transcript"
        return out
    }

    /// Reads the bytes appended since `offset` and folds them into one weight.
    ///
    /// One assistant message spans several transcript lines — one per content block —
    /// each repeating the same `usage` object verbatim, so the same numbers appear two
    /// or three times. Deduping by `message.id` is not a nicety: on a real session it
    /// is the difference between 665 messages and 1329 lines.
    private static func scan(_ url: URL, from offset: UInt64, skipping seen: Set<String>)
    -> (Weight, Set<String>, UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (Weight(), [], 0) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return (Weight(), [], 0) }
        // Everything after the last newline is a line still being written.
        guard let lastBreak = data.lastIndex(of: UInt8(ascii: "\n")) else { return (Weight(), [], 0) }
        let complete = data[data.startIndex...lastBreak]

        var total = Weight()
        var ids = Set<String>()
        for line in String(decoding: complete, as: UTF8.self).split(separator: "\n") {
            guard line.contains("\"usage\""), line.contains("\"assistant\""),
                  let lineData = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let parsed = usage(inLine: o)
            else { continue }
            if let id = parsed.id {
                guard !seen.contains(id), ids.insert(id).inserted else { continue }
            }
            total = total + parsed.weight
        }
        return (total, ids, UInt64(complete.count))
    }

    // MARK: - Codex

    /// Codex writes one rollout file per thread and stamps a cumulative
    /// `total_token_usage` into it on every turn, so the last one is the session total.
    ///
    /// The fragile step is the identity, not the numbers: AgentBar's adapter writes
    /// `codex-<thread-id>` (`Scripts/hooks/codex/notify.js`), and its two fallbacks —
    /// a turn id and a pid — match no rollout file at all. So this looks the file up
    /// and returns nil when it is not there. A wrong number would be worse than none.
    static func codex(sessionId: String, base: URL? = nil) -> Weight? {
        let id = sessionId.hasPrefix("codex-") ? String(sessionId.dropFirst(6)) : sessionId
        guard !id.isEmpty, let url = rollout(id: id, base: base),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return codexRollout(text)
    }

    /// `$CODEX_HOME`, or `~/.codex`. Passed in by tests, which must not depend on
    /// whichever of those the machine running them happens to have.
    static func codexHome() -> URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static func rollout(id: String, base: URL? = nil) -> URL? {
        let fm = FileManager.default
        let sessions = (base ?? codexHome()).appendingPathComponent("sessions")
        guard let walker = fm.enumerator(at: sessions, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles])
        else { return nil }
        for case let f as URL in walker where f.pathExtension == "jsonl" {
            if f.lastPathComponent.hasSuffix("-\(id).jsonl") { return f }
        }
        return nil
    }

    /// Pure, over the rollout's text. `total_token_usage` is cumulative for the file,
    /// so the last `token_count` event wins and nothing is summed.
    ///
    /// Codex counts cached input *inside* `input_tokens`, unlike the other two, so it
    /// is split back out here — otherwise the same conversation would look bigger under
    /// Codex than under Claude purely because of how the provider phrases its report.
    static func codexRollout(_ text: String) -> Weight? {
        var out: Weight?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("token_count"),
                  let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = o["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let t = info["total_token_usage"] as? [String: Any]
            else { continue }
            let cached = t["cached_input_tokens"] as? Int ?? 0
            out = Weight(input: max(0, (t["input_tokens"] as? Int ?? 0) - cached),
                         output: t["output_tokens"] as? Int ?? 0,
                         cacheWrite: t["cache_write_input_tokens"] as? Int ?? 0,
                         cacheRead: cached,
                         source: "codex-rollout")
        }
        return out.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Copilot

    /// Copilot CLI keeps a SQLite database whose `assistant_usage_events` rows carry
    /// the session id verbatim — the same string AgentBar already writes into
    /// `history.jsonl`, so there is nothing to match up.
    ///
    /// Opened **read-only**, and that is not a precaution about our own writes: a
    /// normal open of a WAL database can checkpoint the log of the process that owns
    /// it. Read-only or not at all.
    static func copilot(sessionId: String, base: URL? = nil) -> Weight? {
        guard !sessionId.isEmpty, let handle = openCopilotDB(base: base) else { return nil }
        defer { sqlite3_close(handle) }

        let sql = """
            SELECT coalesce(sum(input_tokens), 0), coalesce(sum(output_tokens), 0),
                   coalesce(sum(cache_write_tokens), 0), coalesce(sum(cache_read_tokens), 0)
            FROM assistant_usage_events WHERE session_id = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let w = Weight(input: Int(sqlite3_column_int64(stmt, 0)),
                       output: Int(sqlite3_column_int64(stmt, 1)),
                       cacheWrite: Int(sqlite3_column_int64(stmt, 2)),
                       cacheRead: Int(sqlite3_column_int64(stmt, 3)),
                       source: "copilot-db")
        return w.isEmpty ? nil : w
    }

    /// **Read-only, and it has to stay that way.** A plain open of a WAL database
    /// lets this process checkpoint a log another process is still writing; the
    /// URI form with `mode=ro` is the one that promises not to. One opener, so
    /// there is no second place for that promise to be forgotten.
    static func openCopilotDB(base: URL? = nil) -> OpaquePointer? {
        let home = ProcessInfo.processInfo.environment["COPILOT_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot")
        let db = (base ?? home).appendingPathComponent("session-store.db")
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2("file:\(db.path)?mode=ro", &handle,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else { sqlite3_close(handle); return nil }
        return handle
    }

    /// What Copilot charged itself over one **local** day, in the unit it bills
    /// in. `created_at` is UTC ISO-8601 text, so the boundary is computed here and
    /// passed as a range: a string prefix would take somebody else's day on either
    /// side of midnight, and be wrong by a whole evening in half the world.
    struct CopilotSpend: Equatable {
        var nanoAIU = 0
        var tokens = 0
        var events = 0
    }

    static func copilotSpend(day: Date = Date(), calendar: Calendar = .current,
                             base: URL? = nil) -> CopilotSpend? {
        guard let handle = openCopilotDB(base: base) else { return nil }
        defer { sqlite3_close(handle) }

        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(24 * 3600)
        let sql = """
            SELECT coalesce(sum(total_nano_aiu), 0),
                   coalesce(sum(input_tokens + output_tokens + cache_write_tokens), 0),
                   count(*)
            FROM assistant_usage_events WHERE created_at >= ? AND created_at < ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, utcStamp(start), -1, transient)
        sqlite3_bind_text(stmt, 2, utcStamp(end), -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        // Cache reads are left out of `tokens` for the same reason `Weight.total`
        // leaves them out: they are two orders of magnitude larger than the rest
        // and are not what a turn spends.
        return CopilotSpend(nanoAIU: Int(sqlite3_column_int64(stmt, 0)),
                            tokens: Int(sqlite3_column_int64(stmt, 1)),
                            events: Int(sqlite3_column_int64(stmt, 2)))
    }

    /// The exact text shape the column uses ("2026-09-16T19:36:51.160Z"), so the
    /// comparison is a plain lexicographic one and SQLite needs no date support.
    static func utcStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.string(from: d)
    }
}
