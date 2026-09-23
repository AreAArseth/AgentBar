import Foundation
import Testing
@testable import AgentBar

/// A note typed next to Deny goes to the agent as the denial's reason. These pin
/// what reaches it — one line, trimmed, capped — and that only a denial can carry
/// one, whether a person typed it or a rule they wrote says it.
@Suite struct DenyNoteTests {
    @Test func nothingWorthSendingIsNoNote() {
        #expect(DenyNote.clean(nil) == nil)
        #expect(DenyNote.clean("") == nil)
        #expect(DenyNote.clean("  \n\t ") == nil)
    }

    @Test func aNoteIsFlattenedToOneLine() {
        #expect(DenyNote.clean("  use pnpm\nhere,\t\tnot npm  ") == "use pnpm here, not npm")
        #expect(DenyNote.clean("a\u{0007}b") == "a b")
    }

    @Test func aLongNoteIsCapped() {
        let out = DenyNote.clean(String(repeating: "x", count: 2000))
        #expect(out?.count == DenyNote.maxLength)
        #expect(out?.hasSuffix("…") == true)
    }

    // MARK: - Rules that say why

    private func file() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-tell-\(UUID().uuidString).json")
    }

    @Test func aDenialThatTellsSurvivesARoundTrip() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let rule = RulesStore.Rule(id: "r-t", decision: "deny", shape: "bash:npm",
                                   tell: "use pnpm in this repo")
        #expect(RulesStore.save([rule], to: url))
        #expect(RulesStore.load(url: url).rules.first?.tell == "use pnpm in this repo")
    }

    /// An approval has nothing to explain, and a field that is sent to an agent
    /// must not ride along on the one kind of rule that says yes.
    @Test func anApprovalThatTellsVoidsTheFile() {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        try? #"{"v":1,"rules":[{"id":"r-a","decision":"allow","shape":"bash:npm test","cwd":"/r","tell":"x"}]}"#
            .data(using: .utf8)!.write(to: url)
        guard case .invalid(let why) = RulesStore.load(url: url) else {
            Issue.record("expected a refusal"); return
        }
        #expect(why.contains("only a denial"))
    }

    /// The memo and the message are different fields on purpose: a note written
    /// as a reminder to yourself must never start arriving in an agent's context.
    @Test func theMemoIsNotTheMessage() {
        let rule = RulesStore.Rule(json: ["id": "r-n", "decision": "deny", "shape": "bash:curl",
                                          "note": "my own reminder"])
        #expect(rule?.tell == "")
        #expect(rule?.note == "my own reminder")
    }
}
