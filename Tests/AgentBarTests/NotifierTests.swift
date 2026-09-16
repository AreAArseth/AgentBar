import Foundation
import Testing
@testable import AgentBar

/// What deserves a banner, and — the part that matters more — what must stop being
/// one. Everything here runs against the pure decision functions; nothing touches
/// `UNUserNotificationCenter`, which needs a real bundle and a real user.
@Suite struct NotifierTests {
    private let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentbar-notify-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func session(_ id: String, state: String, project: String = "AgentBar",
                         started: Bool = true, recap: String = "", ts: TimeInterval = 1_000) throws -> Session {
        let url = dir.appendingPathComponent("\(id).json")
        let o: [String: Any] = ["agent": "claude", "state": state, "started": started,
                                "ts": ts, "project": project, "label": "build",
                                "recap": recap, "pid": 4242]
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        return try #require(Session(fileURL: url))
    }

    private func request(_ name: String, session: String = "a",
                         display: String = "Bash: git push", question: Bool = false) throws -> ApprovalRequest {
        let url = dir.appendingPathComponent(name)
        var o: [String: Any] = ["sessionId": session, "agent": "claude", "toolName": "Bash",
                                "display": display, "toolInputPretty": "{}",
                                "pid": 1, "hookPid": 2, "ts": 1_000]
        if question {
            o["context"] = ["kind": "question",
                            "questions": [["question": "Which one?", "header": "Pick",
                                           "multiSelect": false,
                                           "options": [["label": "A", "description": ""]]]]]
        }
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        return try #require(ApprovalRequest(fileURL: url))
    }

    // MARK: - Off means off

    /// Rule 2 says nothing unfolds over the screen on its own. The switch being off
    /// is what makes this an exception rather than a violation, so it is the first
    /// thing worth a test.
    @Test func nothingIsPostedWhileTheSwitchIsOff() throws {
        let r = try request("r1.json")
        let (post, _) = Notifier.requestEvents(previous: [], requests: [r], sessions: [], enabled: false)
        #expect(post.isEmpty)

        let done = try session("a", state: "done")
        #expect(Notifier.sessionEvents(previous: ["a": .thinking], sessions: [done], enabled: false).isEmpty)
    }

    /// Turning approvals off has to take back what is already on screen, or a banner
    /// outlives the setting that allowed it.
    @Test func turningItOffWithdrawsWhatIsAlreadyShowing() throws {
        let r = try request("r1.json")
        let (_, withdraw) = Notifier.requestEvents(previous: ["r1.json"], requests: [r],
                                                   sessions: [], enabled: false)
        #expect(withdraw == ["r1.json"])
    }

    // MARK: - Approvals

    @Test func anApprovalIsPostedOnceAndNamesTheProject() throws {
        let s = try session("a", state: "permission", project: "AgentBar")
        let r = try request("r1.json")
        let (post, _) = Notifier.requestEvents(previous: [], requests: [r], sessions: [s], enabled: true)
        #expect(post.count == 1)
        #expect(post[0].kind == .approval)
        #expect(post[0].title == "AgentBar needs approval")
        #expect(post[0].body == "Bash: git push")
        #expect(post[0].id == "r1.json")

        // Already showing: the store fires on every tick, and re-posting would make
        // one pending approval buzz forever.
        let (again, _) = Notifier.requestEvents(previous: ["r1.json"], requests: [r],
                                                sessions: [s], enabled: true)
        #expect(again.isEmpty)
    }

    /// The one that makes the buttons trustworthy: answered in the menu, by the
    /// hotkey, or simply timed out — either way the banner has to come down, because
    /// two live buttons that do nothing are worse than no banner at all.
    @Test func anAnsweredRequestIsWithdrawn() throws {
        let (post, withdraw) = Notifier.requestEvents(previous: ["r1.json"], requests: [],
                                                      sessions: [], enabled: true)
        #expect(post.isEmpty)
        #expect(withdraw == ["r1.json"])
    }

    /// A question's answer is a list or free text; two buttons cannot carry it, so
    /// it is posted without them and the tap jumps to the session instead.
    @Test func aQuestionGetsNoButtons() throws {
        let s = try session("a", state: "question")
        let r = try request("q1.json", question: true)
        let (post, _) = Notifier.requestEvents(previous: [], requests: [r], sessions: [s], enabled: true)
        #expect(post.first?.kind == .question)
    }

    /// No session row yet — the request can arrive before the state file lands.
    @Test func anApprovalWithNoSessionRowStillSaysSomething() throws {
        let r = try request("r1.json")
        let (post, _) = Notifier.requestEvents(previous: [], requests: [r], sessions: [], enabled: true)
        #expect(post.first?.title == "Claude needs approval")
    }

    // MARK: - Finished sessions

    @Test func aFinishedSessionIsAnnouncedOnce() throws {
        let working = try session("a", state: "thinking")
        let done = try session("a", state: "done", recap: "Pushed 3 commits")
        let out = Notifier.sessionEvents(previous: ["a": working.state], sessions: [done], enabled: true)
        #expect(out.count == 1)
        #expect(out[0].title == "AgentBar finished")
        #expect(out[0].body == "Pushed 3 commits")

        // The row sits in `done` for hours before pruning reaches it.
        #expect(Notifier.sessionEvents(previous: ["a": .done], sessions: [done], enabled: true).isEmpty)
    }

    @Test func anErrorSaysSoRatherThanClaimingSuccess() throws {
        let failed = try session("a", state: "error")
        let out = Notifier.sessionEvents(previous: ["a": .tool], sessions: [failed], enabled: true)
        #expect(out.first?.title == "AgentBar failed")
    }

    /// A watchdog guessing that a quiet session is over is not the agent saying it
    /// finished. Announcing it would invent an outcome the user then acts on.
    @Test func aDecayedEndIsNotAnnounced() throws {
        var decayed = try session("a", state: "done")
        decayed.decayed = true
        #expect(Notifier.sessionEvents(previous: ["a": .tool], sessions: [decayed], enabled: true).isEmpty)
    }

    @Test func aSessionThatNeverStartedIsNotAnnounced() throws {
        let ghost = try session("ghost", state: "done", started: false)
        #expect(Notifier.sessionEvents(previous: [:], sessions: [ghost], enabled: true).isEmpty)
    }

    /// Two turns of one session are two endings, so the identifier has to change or
    /// the second banner would silently replace the first under the same id.
    @Test func twoTurnsOfOneSessionGetDistinctIdentifiers() throws {
        let first = try session("a", state: "done", ts: 1_000)
        let second = try session("a", state: "done", ts: 2_000)
        let a = Notifier.sessionEvents(previous: ["a": .tool], sessions: [first], enabled: true)
        let b = Notifier.sessionEvents(previous: ["a": .thinking], sessions: [second], enabled: true)
        #expect(a.first?.id != b.first?.id)
    }
}
