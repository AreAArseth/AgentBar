import Foundation
import Testing
@testable import AgentBar

/// The day's account. Every number here is one a person would quote back, so the
/// tests are mostly about the cases where the honest answer is to say less.
@Suite struct HistoryDigestTests {
    /// 2026-09-16 12:00:00 UTC, and a fixed UTC calendar — "today" is defined by
    /// local midnight, and a test that inherits the runner's timezone would pass in
    /// Prague and fail in CI.
    private static let noon: TimeInterval = 1_789_646_400
    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func record(_ id: String, agent: String = "claude", project: String = "AgentBar",
                        state: String = "done", started: TimeInterval, ended: TimeInterval)
    -> HistoryStore.Record {
        let json = #"{"agent":"\#(agent)","sessionId":"\#(id)","project":"\#(project)","state":"\#(state)","startedAt":\#(Int(started)),"endedAt":\#(Int(ended)),"cwd":"/tmp/x"}"#
        return HistoryStore.Record(jsonLine: json)!
    }

    // MARK: - The window

    /// "Today" means since local midnight. A digest that starts counting from
    /// whenever you happen to open the menu is not a day.
    @Test func yesterdayIsNotToday() {
        let today = record("a", started: Self.noon - 600, ended: Self.noon - 300)
        let yesterday = record("b", started: Self.noon - 90_000, ended: Self.noon - 89_000)
        let (summary, entries) = HistoryDigest.today([today, yesterday],
                                                     now: Self.noon, calendar: Self.utc)
        #expect(summary.sessions == 1)
        #expect(entries.map(\.agent) == ["claude"])
    }

    @Test func entriesComeBackNewestFirst() {
        let early = record("a", started: Self.noon - 3_000, ended: Self.noon - 2_400)
        let late = record("b", project: "Other", started: Self.noon - 600, ended: Self.noon - 300)
        let (_, entries) = HistoryDigest.today([early, late], now: Self.noon, calendar: Self.utc)
        #expect(entries.map(\.project) == ["Other", "AgentBar"])
    }

    // MARK: - Numbers that must not overstate

    @Test func durationsAddUpAndFailuresAreCounted() {
        let a = record("a", started: Self.noon - 3_600, ended: Self.noon - 1_800)   // 30m
        let b = record("b", state: "error", started: Self.noon - 900, ended: Self.noon - 300) // 10m
        let (summary, _) = HistoryDigest.today([a, b], now: Self.noon, calendar: Self.utc)
        #expect(summary.sessions == 2)
        #expect(summary.failed == 1)
        #expect(summary.seconds == 2_400)
        #expect(summary.measured == 2)
        #expect(HistoryDigest.headline(summary) == "2 sessions · 40m · 1 failed")
    }

    /// `started_at` is optional in the protocol, so some rows cannot be timed at all.
    /// Summing the ones that can and presenting it as the day's total would be a
    /// number someone quotes — say what it covers instead.
    @Test func aPartialTotalSaysWhatItCovers() {
        let timed = record("a", started: Self.noon - 3_600, ended: Self.noon - 1_800)
        let untimed = record("b", project: "Untimed", started: 0, ended: Self.noon - 300)
        let (summary, entries) = HistoryDigest.today([timed, untimed],
                                                     now: Self.noon, calendar: Self.utc)
        #expect(summary.measured == 1)
        #expect(summary.sessions == 2)
        #expect(HistoryDigest.headline(summary) == "2 sessions · 30m across 1")
        // And the untimed row must not invent a duration of its own.
        #expect(entries.first { $0.project == "AgentBar" }?.duration == 1_800)
        #expect(entries.first { $0.project == "Untimed" }?.duration == nil)
    }

    /// A clock that went backwards, or a writer that stamped them out of order.
    @Test func anEndBeforeItsStartIsNotATimedSession() {
        let backwards = record("a", started: Self.noon, ended: Self.noon - 60)
        let (_, entries) = HistoryDigest.digest([backwards], since: 0, until: Self.noon)
        #expect(entries.first?.duration == nil)
    }

    @Test func anEmptyDaySaysSoRatherThanShowingZeroes() {
        let (summary, entries) = HistoryDigest.today([], now: Self.noon, calendar: Self.utc)
        #expect(entries.isEmpty)
        #expect(HistoryDigest.headline(summary) == "Nothing finished yet today")
    }

    @Test func oneSessionIsNotPluralised() {
        let one = record("a", started: Self.noon - 60, ended: Self.noon - 30)
        let (summary, _) = HistoryDigest.today([one], now: Self.noon, calendar: Self.utc)
        #expect(HistoryDigest.headline(summary) == "1 session · <1m")
    }

    // MARK: - Formatting

    @Test(arguments: [(0.0, "<1m"), (59.0, "<1m"), (60.0, "1m"), (3_599.0, "59m"),
                      (3_600.0, "1h"), (13_200.0, "3h 40m")])
    func durationsReadTheWayTheLiveRowsDo(_ seconds: Double, _ want: String) {
        #expect(HistoryDigest.duration(seconds) == want)
    }

    /// A session with no project falls back to the agent's name; a bare row that
    /// says nothing about whose work it was is not worth a line in the menu.
    @Test func aRowWithoutAProjectNamesTheAgent() {
        let e = record("a", agent: "codex", project: "", started: 0, ended: Self.noon)
        let (_, entries) = HistoryDigest.digest([e], since: 0, until: Self.noon)
        #expect(HistoryDigest.line(entries[0]) == "Codex")
    }
}
