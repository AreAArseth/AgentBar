import Foundation
import Testing
@testable import AgentBar

/// "Compacting…" rides on the label of a working row (docs/claude-code-states.md);
/// these hold the Swift side to the exact string update.js writes, and to the word
/// the bar shows in place of the rotating verbs.
@Suite struct CompactingTests {
    @Test func theHookAndTheAppAgreeOnTheLabel() throws {
        // update.js is the writer; a drift here means the bar never says it.
        let hook = try String(contentsOfFile: "Scripts/hooks/claude/update.js", encoding: .utf8)
        #expect(hook.contains("const COMPACTING = \"\(Session.compactingLabel)\";"))
    }

    @Test func aCompactingSessionHoldsOneWord() {
        let s = Session(preview: .thinking, project: "AgentBar", label: Session.compactingLabel)
        #expect(s.isCompacting)
        #expect(MascotDriver.fixedWord(for: s) == "Compacting")
    }

    @Test func ordinaryWorkStillRotates() {
        for label in ["Thinking…", "Running command", ""] {
            let s = Session(preview: .thinking, project: "AgentBar", label: label)
            #expect(MascotDriver.fixedWord(for: s) == nil)
        }
        #expect(MascotDriver.fixedWord(for: nil) == nil)
    }

    @Test func theLabelAloneOnAFinishedRowIsNotCompacting() {
        // Only a working row is compacting; a stale label on a done row is not.
        let s = Session(preview: .done, project: "AgentBar", label: Session.compactingLabel)
        #expect(!s.isCompacting)
        #expect(MascotDriver.fixedWord(for: s) == nil)
    }
}
