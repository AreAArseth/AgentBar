import Foundation
import Testing
@testable import AgentBar

/// The two empties: a fresh install says what to do next, an ordinary quiet
/// moment says one line and nothing else.
@Suite struct EmptyStateTests {
    @Test func aFreshInstallSaysWhatToDo() {
        #expect(EmptyState.title(firstRun: true) == "Waiting for your first session")
        let hint = EmptyState.hint(firstRun: true) ?? ""
        #expect(hint.contains("already open"))
    }

    @Test func anOrdinaryQuietMomentStaysOneLine() {
        #expect(EmptyState.title(firstRun: false) == "No active sessions")
        #expect(EmptyState.hint(firstRun: false) == nil)
    }

    @Test func aMenuLineWrapsAtWordsAndKeepsEveryWord() {
        let text = EmptyState.hint(firstRun: true)!
        let out = MenuBuilder.wrapped(text, width: 46)
        #expect(out.split(separator: "\n").allSatisfy { $0.count <= 46 })
        #expect(out.replacingOccurrences(of: "\n", with: " ") == text)
    }

    @Test func aWordLongerThanTheLineIsNotSplit() {
        #expect(MenuBuilder.wrapped("a supercalifragilistic b", width: 5) == "a\nsupercalifragilistic\nb")
    }
}
