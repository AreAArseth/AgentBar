import Foundation
import SQLite3
import Testing
@testable import AgentBar

/// What the providers say is left. Most of these are about the cases where the
/// honest answer is a gap: a window nobody has written since it rolled over, a
/// ceiling that does not exist locally, a number that is somebody else's day.
@Suite struct UsageTests {
    /// 2026-09-17 12:00:00 UTC, with a UTC calendar wherever a day boundary
    /// matters — a test that inherits the runner's timezone passes in Prague and
    /// fails in CI.
    private static let noon = Date(timeIntervalSince1970: 1_789_646_400)
    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// The exact text shape Copilot's `created_at` column uses. Written out again
    /// here rather than borrowed from the code under test, so a format that drifts
    /// on one side shows up as a failure instead of agreeing with itself.
    private func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.string(from: d)
    }

    private func rollout(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    private func tokenCount(limitID: String?, primary: String = "null",
                            secondary: String = "null", credits: String = "null",
                            at: Date = UsageTests.noon) -> String {
        let iso = ISO8601DateFormatter().string(from: at)
        let id = limitID.map { "\"\($0)\"" } ?? "null"
        return """
        {"timestamp":"\(iso)","payload":{"type":"token_count","info":{},"rate_limits":\
        {"limit_id":\(id),"primary":\(primary),"secondary":\(secondary),"credits":\(credits)}}}
        """
    }

    private func window(_ percent: Double, minutes: Int, resets: Date) -> String {
        """
        {"used_percent":\(percent),"window_minutes":\(minutes),\
        "resets_at":\(Int(resets.timeIntervalSince1970))}
        """
    }

    // MARK: - Codex

    /// The regression this release exists for: a rollout carries more than one
    /// bucket, and on a real machine the **last** `token_count` line was the
    /// `premium` one with both windows null. Reading only the newest matching
    /// line found nothing and the whole row vanished.
    @Test func codexReadsPastAPremiumLineToTheAccountWindows() throws {
        let tail = rollout([
            tokenCount(limitID: "codex",
                       primary: window(97, minutes: 300, resets: Self.noon.addingTimeInterval(1800)),
                       secondary: window(27, minutes: 10080,
                                         resets: Self.noon.addingTimeInterval(86400))),
            tokenCount(limitID: "premium",
                       credits: #"{"has_credits":false,"unlimited":false,"balance":"0"}"#),
        ])
        let usage = try #require(UsageCenter.codexUsage(tail: tail, now: Self.noon))
        #expect(usage.windows.count == 2)
        #expect(usage.windows[0].name == "5h")
        #expect(usage.windows[0].usedPercent == 97)
        #expect(usage.windows[1].name == "weekly")
        #expect(usage.windows[1].usedPercent == 27)
    }

    /// An account with no credits has a balance of "0", and "0 credits left" is
    /// bad news about a thing that was never true.
    @Test func codexShowsNoCreditLineWithoutCredits() throws {
        let tail = rollout([
            tokenCount(limitID: "codex",
                       primary: window(10, minutes: 300, resets: Self.noon.addingTimeInterval(600))),
            tokenCount(limitID: "premium",
                       credits: #"{"has_credits":false,"unlimited":false,"balance":"0"}"#),
        ])
        let usage = try #require(UsageCenter.codexUsage(tail: tail, now: Self.noon))
        #expect(usage.creditsNote == nil)
    }

    @Test func codexShowsTheBalanceWhenThereAreCredits() throws {
        let tail = rollout([
            tokenCount(limitID: "codex",
                       primary: window(10, minutes: 300, resets: Self.noon.addingTimeInterval(600))),
            tokenCount(limitID: "premium",
                       credits: #"{"has_credits":true,"unlimited":false,"balance":"12.50"}"#),
        ])
        let usage = try #require(UsageCenter.codexUsage(tail: tail, now: Self.noon))
        #expect(usage.creditsNote == "12.50 credits left")
    }

    /// Model-specific buckets answer a different question, and taking one for the
    /// account's would understate a busy day.
    @Test func codexIgnoresPerModelBuckets() throws {
        let tail = rollout([
            tokenCount(limitID: "codex",
                       primary: window(80, minutes: 300, resets: Self.noon.addingTimeInterval(600))),
            tokenCount(limitID: "codex_gpt-5",
                       primary: window(3, minutes: 300, resets: Self.noon.addingTimeInterval(600))),
        ])
        let usage = try #require(UsageCenter.codexUsage(tail: tail, now: Self.noon))
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].usedPercent == 80)
    }

    /// Rollouts predate `limit_id` entirely; a missing one is the account bucket.
    @Test func codexTreatsAMissingLimitIDAsTheAccount() throws {
        let tail = rollout([
            tokenCount(limitID: nil,
                       primary: window(42, minutes: 300, resets: Self.noon.addingTimeInterval(600))),
        ])
        let usage = try #require(UsageCenter.codexUsage(tail: tail, now: Self.noon))
        #expect(usage.windows.first?.usedPercent == 42)
    }

    /// A March window shown in August. Silence is the only honest rendering of a
    /// number whose window rolled over a dozen times since it was written.
    @Test func codexRefusesAStaleTail() {
        let old = Self.noon.addingTimeInterval(-48 * 3600)
        let tail = rollout([
            tokenCount(limitID: "codex",
                       primary: window(97, minutes: 300, resets: old.addingTimeInterval(600)),
                       at: old),
        ])
        #expect(UsageCenter.codexUsage(tail: tail, now: Self.noon) == nil)
    }

    /// A window the account doesn't have comes back as null — no meter, never a
    /// confident zero.
    @Test func codexSkipsNullWindows() throws {
        let tail = rollout([
            tokenCount(limitID: "codex",
                       primary: window(55, minutes: 300, resets: Self.noon.addingTimeInterval(600)),
                       secondary: "null"),
        ])
        let usage = try #require(UsageCenter.codexUsage(tail: tail, now: Self.noon))
        #expect(usage.windows.count == 1)
    }

    @Test func codexWithNothingToSaySaysNothing() {
        #expect(UsageCenter.codexUsage(tail: "", now: Self.noon) == nil)
        #expect(UsageCenter.codexUsage(tail: "not json at all\n", now: Self.noon) == nil)
    }

    // MARK: - The sentence

    @Test func remainingIsWhatIsLeft() {
        let w = UsageWindow(name: "5h", usedPercent: 97, resetsAt: nil)
        #expect(w.remainingPercent == 3)
        #expect(UsageCenter.short(w, now: Self.noon) == "3% left")
    }

    @Test func aRolledOverWindowSaysSoInsteadOfQuotingTheOldNumber() {
        let w = UsageWindow(name: "5h", usedPercent: 97,
                            resetsAt: Self.noon.addingTimeInterval(-60))
        #expect(w.expired(now: Self.noon))
        #expect(UsageCenter.short(w, now: Self.noon) == "window reset")
    }

    /// A clock for today, a weekday for anything further out: "resets 14:31" for
    /// next Thursday is not an answer.
    @Test func resetsReadAsAClockOrAWeekday() {
        let soon = UsageWindow(name: "5h", usedPercent: 50,
                               resetsAt: Self.noon.addingTimeInterval(3600))
        #expect(UsageCenter.short(soon, now: Self.noon).contains("resets"))
        let far = UsageWindow(name: "weekly", usedPercent: 50,
                              resetsAt: Self.noon.addingTimeInterval(4 * 86400))
        let text = UsageCenter.short(far, now: Self.noon)
        #expect(text.contains("50% left"))
        #expect(!text.contains(":"))   // a weekday, not a time of day
    }

    /// A window that has just rolled over has nothing to say, so the line leads
    /// with one that does — otherwise the island spends its whole usage line on
    /// "window reset" while "74% of the week left" hides in a tooltip.
    @Test func theOneLineFormLeadsWithAWindowThatHasNews() throws {
        let r = try #require(UsageCenter.reading(provider: "Codex", windows: [
            UsageWindow(name: "5h", usedPercent: 97, resetsAt: Self.noon.addingTimeInterval(-60)),
            UsageWindow(name: "weekly", usedPercent: 26,
                        resetsAt: Self.noon.addingTimeInterval(4 * 86_400)),
        ], now: Self.noon))
        #expect(r.text.hasPrefix("74% left"))
        #expect(r.detail?.contains("5h: window reset") == true)
    }

    /// When every window has rolled over there is no news to lead with, and the
    /// line says exactly that rather than reaching for the old number.
    @Test func allWindowsResetStillSaysSo() throws {
        let r = try #require(UsageCenter.reading(provider: "Codex", windows: [
            UsageWindow(name: "5h", usedPercent: 97, resetsAt: Self.noon.addingTimeInterval(-60)),
        ], now: Self.noon))
        #expect(r.text == "window reset")
    }

    /// The meter rows: a provider says its name once, an expired window carries no
    /// meter at all, and a note rides along without pretending to be a window.
    @Test func meterRowsSayTheNameOnceAndSkipMetersNobodyMeasured() {
        let reading = UsageCenter.Reading(
            provider: "Codex", text: "x", detail: nil,
            windows: [UsageWindow(name: "5h", usedPercent: 97,
                                  resetsAt: Date(timeIntervalSince1970: 1)),
                      UsageWindow(name: "weekly", usedPercent: 27,
                                  resetsAt: Date(timeIntervalSinceNow: 86400))],
            note: "12.50 credits left")
        let rows = UsageMeterView.rows(for: [reading])
        #expect(rows.count == 3)
        #expect(rows[0].provider == "Codex")
        #expect(rows[0].used == nil)          // rolled over: no meter
        #expect(rows[1].provider.isEmpty)     // said once
        #expect(rows[1].used == 27)
        #expect(rows[2].trailing == "12.50 credits left")
        #expect(rows[2].window.isEmpty)
    }

    /// A provider with no published ceiling gets a number, not a meter against a
    /// guess.
    @Test func aProviderWithoutACeilingGetsNoMeter() {
        let rows = UsageMeterView.rows(for: [
            UsageCenter.Reading(provider: "Copilot", text: "2.4 AIU today"),
        ])
        #expect(rows.count == 1)
        #expect(rows[0].used == nil)
        #expect(rows[0].trailing == "2.4 AIU today")
    }

    @Test func aiuKeepsTheDecimalsThatMatter() {
        #expect(UsageCenter.aiu(33_104_000) == "0.03")   // a morning of small edits
        #expect(UsageCenter.aiu(2_373_072_000) == "2.4")
        #expect(UsageCenter.aiu(42_000_000_000) == "42")
    }

    // MARK: - Claude's quota (parsing only — nothing here reaches the network)

    private static let payload = """
    {"five_hour":{"utilization":33.0,"resets_at":"2026-09-16T17:00:00.528743+00:00"},
     "seven_day":{"utilization":13.0,"resets_at":"2026-09-20T00:59:59.951713+00:00"},
     "seven_day_opus":null,
     "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null}}
    """

    @Test func quotaParsesBothWindows() throws {
        let snap = try #require(ClaudeQuota.parse(Data(Self.payload.utf8), account: "someone"))
        #expect(snap.windows.count == 2)
        #expect(snap.windows[0].name == "5h")
        #expect(snap.windows[0].usedPercent == 33)
        #expect(snap.windows[1].name == "weekly")
        #expect(snap.windows[1].resetsAt != nil)
        #expect(snap.account == "someone")
    }

    /// `utilization` is already a percentage. Readers that take it for a fraction
    /// render 1 % as 100 % or 55 % as half a percent — both have been filed
    /// against other clients of this endpoint, so it is worth a test of its own.
    @Test func quotaTreatsUtilizationAsAPercentageNotAFraction() throws {
        let json = #"{"five_hour":{"utilization":1.0,"resets_at":null}}"#
        let snap = try #require(ClaudeQuota.parse(Data(json.utf8)))
        #expect(snap.windows[0].usedPercent == 1)
    }

    @Test func quotaSkipsWindowsTheAccountDoesNotHave() throws {
        let json = #"{"five_hour":null,"seven_day":{"utilization":8.0,"resets_at":null}}"#
        let snap = try #require(ClaudeQuota.parse(Data(json.utf8)))
        #expect(snap.windows.count == 1)
        #expect(snap.windows[0].name == "weekly")
    }

    @Test func quotaWithNoWindowsIsNoReading() {
        #expect(ClaudeQuota.parse(Data(#"{"extra_usage":{}}"#.utf8)) == nil)
        #expect(ClaudeQuota.parse(Data("nonsense".utf8)) == nil)
    }

    /// The credential's shape has changed before; the token is found by name at
    /// any depth rather than through a hard-coded path.
    @Test func theTokenIsFoundWhereverItSits() {
        #expect(ClaudeQuota.accessToken(in: ["claudeAiOauth": ["accessToken": "sk-x"]]) == "sk-x")
        #expect(ClaudeQuota.accessToken(in: ["access_token": "sk-y"]) == "sk-y")
        #expect(ClaudeQuota.accessToken(in: ["accessToken": ""]) == nil)
        #expect(ClaudeQuota.accessToken(in: ["somethingElse": 1]) == nil)
    }

    /// An expired token is not an error worth surfacing: the CLI renews it on its
    /// own next run, and asking with it would only spend a 401.
    @Test func anExpiredCredentialIsNotUsed() {
        let past = ["claudeAiOauth": ["expiresAt": 1_000_000]]
        #expect(ClaudeQuota.expired(past, now: Self.noon))
        let future = ["claudeAiOauth": ["expiresAt": Self.noon.timeIntervalSince1970 * 1000 + 60_000]]
        #expect(!ClaudeQuota.expired(future, now: Self.noon))
        #expect(!ClaudeQuota.expired(["no": "expiry"], now: Self.noon))
    }

    /// The header the endpoint routes on, with our own name after it rather than
    /// instead of it.
    @Test func theUserAgentNamesBothProgrammes() {
        let ua = ClaudeQuota.userAgent(appVersion: "1.19.0")
        #expect(ua.hasPrefix("claude-code/"))
        #expect(ua.contains("AgentBar/1.19.0"))
    }

    // MARK: - Copilot's own ledger

    private func copilotDB(rows: [(created: String, nano: Int, input: Int, output: Int,
                                   cacheWrite: Int)]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(base.appendingPathComponent("session-store.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE assistant_usage_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
                model TEXT NOT NULL, input_tokens INTEGER, output_tokens INTEGER,
                cache_read_tokens INTEGER, cache_write_tokens INTEGER,
                total_nano_aiu INTEGER, created_at TEXT);
            """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        for r in rows {
            let sql = """
                INSERT INTO assistant_usage_events (session_id, model, input_tokens,
                    output_tokens, cache_read_tokens, cache_write_tokens, total_nano_aiu, created_at)
                VALUES ('s', 'gpt-5.6', \(r.input), \(r.output), 999999, \(r.cacheWrite),
                        \(r.nano), '\(r.created)');
                """
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        return base
    }

    /// The day is a **local** day against a UTC column, so the boundary is a range
    /// and not a string prefix — a prefix takes somebody else's day on either side
    /// of midnight. Fixed to UTC here so the test means the same thing in Prague
    /// and in CI.
    @Test func copilotCountsOneLocalDayAndNoOther() throws {
        let utc = Self.utc
        let midnight = utc.startOfDay(for: Self.noon)
        let base = try copilotDB(rows: [
            (stamp(midnight.addingTimeInterval(-1)), 1_000_000_000, 10, 1, 0),      // yesterday
            (stamp(midnight.addingTimeInterval(1)), 2_000_000_000, 100, 10, 5),     // today
            (stamp(midnight.addingTimeInterval(19 * 3600)), 500_000_000, 200, 20, 5), // today
            (stamp(midnight.addingTimeInterval(86_401)), 9_000_000_000, 999, 99, 0), // tomorrow
        ])
        let spend = try #require(WeightReader.copilotSpend(day: Self.noon, calendar: utc, base: base))
        #expect(spend.events == 2)
        #expect(spend.nanoAIU == 2_500_000_000)
        // Cache reads stay out, exactly as they do in `Weight.total`.
        #expect(spend.tokens == 340)
    }

    @Test func copilotWithNoDatabaseSaysNothing() {
        let nowhere = URL(fileURLWithPath: "/tmp/agentbar-not-a-copilot-dir")
        #expect(WeightReader.copilotSpend(base: nowhere) == nil)
    }

    /// Every `~/.claude*` counts as a config directory, transcripts or not —
    /// the credential and the version marker live beside them, not inside
    /// `projects/`.
    @Test func claudeConfigDirsSeeMoreThanTranscriptFolders() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-home-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent(".claude/projects"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".claude-work"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".config"),
                               withIntermediateDirectories: true)
        let dirs = WeightReader.claudeConfigDirs(home: home).map(\.lastPathComponent)
        #expect(dirs == [".claude", ".claude-work"])
        #expect(WeightReader.claudeRoots(home: home).count == 1)
    }
}
