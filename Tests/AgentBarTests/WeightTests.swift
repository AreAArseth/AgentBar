import Foundation
import SQLite3
import Testing
@testable import AgentBar

/// What a session cost. Every test here is really the same test: the number has to
/// be the agent's own, or there has to be no number.
@Suite struct WeightTests {
    private let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentbar-weight-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Claude Code

    private func transcript(_ sessionId: String, root: String = ".claude",
                            project: String = "-tmp-AgentBar", lines: [String]) throws -> URL {
        let dirURL = dir.appendingPathComponent(root).appendingPathComponent("projects")
            .appendingPathComponent(project)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let url = dirURL.appendingPathComponent("\(sessionId).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func assistantLine(id: String, input: Int, output: Int,
                               cacheWrite: Int = 0, cacheRead: Int = 0) -> String {
        #"{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"id":"\#(id)","usage":"#
            + #"{"input_tokens":\#(input),"output_tokens":\#(output),"#
            + #""cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead)}}}"#
    }

    /// One assistant message spans several transcript lines — one per content block —
    /// each repeating the same `usage` object verbatim. On a real session that is 1329
    /// lines for 665 messages, so counting lines would roughly double the answer.
    @Test func linesSharingAMessageIdAreCountedOnce() throws {
        _ = try transcript("s1", lines: [
            assistantLine(id: "msg_1", input: 10, output: 20, cacheWrite: 5, cacheRead: 1_000),
            assistantLine(id: "msg_1", input: 10, output: 20, cacheWrite: 5, cacheRead: 1_000),
            assistantLine(id: "msg_2", input: 1, output: 2),
        ])
        let w = try #require(WeightReader.claude(sessionId: "s1", cwd: "/tmp/AgentBar", home: dir))
        #expect(w.input == 11)
        #expect(w.output == 22)
        #expect(w.cacheWrite == 5)
        #expect(w.cacheRead == 1_000)
        #expect(w.source == "claude-transcript")
    }

    /// Cache reads are the difference between 2.1 M and 222.9 M on one real session.
    /// The stored number keeps them; the shown number does not.
    @Test func theShownTotalLeavesCacheReadsOut() {
        let w = Weight(input: 1_330, output: 622_024, cacheWrite: 1_453_897, cacheRead: 220_795_232)
        #expect(w.total == 2_077_251)
    }

    /// Everything that is not an assistant message with usage: user turns, tool
    /// results, and the half-written last line of a transcript still being appended to.
    @Test func nonUsageLinesAndATornTailAreIgnored() throws {
        let dirURL = dir.appendingPathComponent(".claude/projects/-tmp-AgentBar")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let body = #"{"type":"user","message":{"content":"hi"}}"# + "\n"
            + assistantLine(id: "m", input: 7, output: 3) + "\n"
            + #"{"type":"assistant","message":{"id":"m2","usa"#   // no trailing newline
        try body.write(to: dirURL.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)

        let w = try #require(WeightReader.claude(sessionId: "s2", cwd: "/tmp/AgentBar", home: dir))
        #expect(w.input == 7)
        #expect(w.output == 3)
    }

    /// The split-config layouts are named by whoever set them up. A hard-coded list
    /// of three silently ignored a fourth on the machine this was written on.
    @Test func anyClaudeRootIsSearchedNotJustTheThreeFamiliarOnes() throws {
        _ = try transcript("s3", root: ".claude-science",
                           lines: [assistantLine(id: "m", input: 5, output: 5)])
        #expect(WeightReader.claude(sessionId: "s3", cwd: "/tmp/AgentBar", home: dir)?.total == 10)
    }

    /// The slug is a fast path, not the answer. A session whose `cwd` no longer maps
    /// to its folder still has exactly one transcript named after it.
    @Test func aTranscriptIsFoundEvenWhenTheProjectSlugDoesNotMatch() throws {
        _ = try transcript("s4", project: "-somewhere-else",
                           lines: [assistantLine(id: "m", input: 5, output: 5)])
        #expect(WeightReader.claude(sessionId: "s4", cwd: "/tmp/AgentBar", home: dir)?.total == 10)
    }

    @Test func noTranscriptMeansNoNumberRatherThanZero() {
        #expect(WeightReader.claude(sessionId: "nope", cwd: "/tmp/AgentBar", home: dir) == nil)
    }

    @Test(arguments: [("/Users/me/src/My App", "-Users-me-src-My-App"),
                      ("/tmp/a.b", "-tmp-a-b")])
    func slugsFollowClaudesOwnRule(_ path: String, _ want: String) {
        #expect(WeightReader.slugify(path) == want)
    }

    // MARK: - Codex

    private func rollout(_ id: String, usages: [(input: Int, cached: Int, output: Int)]) throws -> URL {
        let day = dir.appendingPathComponent(".codex/sessions/2026/09/16")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        var lines = [#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp"}}"#]
        for u in usages {
            lines.append(#"{"type":"event_msg","payload":{"type":"token_count","info":{"#
                + #""total_token_usage":{"input_tokens":\#(u.input),"cached_input_tokens":\#(u.cached),"#
                + #""cache_write_input_tokens":0,"output_tokens":\#(u.output),"total_tokens":0}}}}"#)
        }
        let url = day.appendingPathComponent("rollout-2026-09-16T11-51-27-\(id).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// `total_token_usage` is cumulative for the rollout, so the last one is the
    /// session's total and summing them would multiply it.
    @Test func theLastTokenCountWinsBecauseItIsAlreadyCumulative() throws {
        _ = try rollout("01a0aa0e", usages: [(10, 0, 1), (60, 40, 5), (125_900, 106_496, 812)])
        let w = try #require(WeightReader.codex(sessionId: "codex-01a0aa0e",
                                                base: dir.appendingPathComponent(".codex")))
        // Codex folds cached input *into* input_tokens, unlike the other two — split
        // back out, or the same conversation looks bigger under Codex than Claude for
        // no reason but phrasing.
        #expect(w.input == 19_404)
        #expect(w.cacheRead == 106_496)
        #expect(w.output == 812)
        #expect(w.source == "codex-rollout")
    }

    /// The one unproven link in the chain: the adapter writes `codex-<thread-id>` and
    /// its fallbacks are a turn id and a pid, neither of which names a rollout file.
    /// When the file is not there the answer is nothing, never a guess.
    @Test func anIdThatMatchesNoRolloutProducesNoWeight() throws {
        _ = try rollout("01a0aa0e", usages: [(10, 0, 1)])
        #expect(WeightReader.codex(sessionId: "codex-99999",
                                   base: dir.appendingPathComponent(".codex")) == nil)
    }

    @Test func aRolloutWithNoTokenCountsProducesNoWeight() throws {
        _ = try rollout("empty", usages: [])
        #expect(WeightReader.codex(sessionId: "codex-empty",
                                   base: dir.appendingPathComponent(".codex")) == nil)
    }

    // MARK: - Copilot

    /// Builds the two columns of Copilot's schema this actually reads. Written with
    /// the real SQLite API rather than a fixture file, so a renamed column fails here
    /// instead of silently returning nothing on someone's Mac.
    private func copilotDB(rows: [(session: String, input: Int, output: Int,
                                   cacheWrite: Int, cacheRead: Int)]) throws -> URL {
        let base = dir.appendingPathComponent("copilot")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let path = base.appendingPathComponent("session-store.db").path

        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE assistant_usage_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
                model TEXT NOT NULL, input_tokens INTEGER, output_tokens INTEGER,
                cache_read_tokens INTEGER, cache_write_tokens INTEGER, total_nano_aiu INTEGER);
            """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        for r in rows {
            let sql = """
                INSERT INTO assistant_usage_events
                  (session_id, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens)
                VALUES ('\(r.session)', 'gpt-5.6', \(r.input), \(r.output), \(r.cacheRead), \(r.cacheWrite));
                """
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        return base
    }

    /// Copilot's own session id is the string AgentBar already writes into
    /// `history.jsonl`, so the join needs no matching at all.
    @Test func copilotSumsTheRowsForOneSession() throws {
        let base = try copilotDB(rows: [
            ("s-a", 100, 10, 5, 1_000), ("s-a", 200, 20, 5, 2_000), ("s-b", 999, 99, 9, 9),
        ])
        let w = try #require(WeightReader.copilot(sessionId: "s-a", base: base))
        #expect(w.input == 300)
        #expect(w.output == 30)
        #expect(w.cacheWrite == 10)
        #expect(w.cacheRead == 3_000)
        #expect(w.source == "copilot-db")
    }

    @Test func aSessionWithNoRowsProducesNoWeight() throws {
        let base = try copilotDB(rows: [("s-a", 1, 1, 1, 1)])
        #expect(WeightReader.copilot(sessionId: "unknown", base: base) == nil)
    }

    @Test func noDatabaseProducesNoWeight() {
        #expect(WeightReader.copilot(sessionId: "s-a", base: dir.appendingPathComponent("nope")) == nil)
    }

    // MARK: - The seven that publish nothing

    @Test(arguments: ["gemini", "antigravity", "cursor", "qwen", "opencode", "devin"])
    func agentsWithNothingOnDiskReportNothing(_ agent: String) {
        #expect(WeightReader.read(agent: agent, sessionId: "x", cwd: "/tmp") == nil)
    }
}
