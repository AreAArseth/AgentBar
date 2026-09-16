import Foundation
import Testing
@testable import AgentBar

/// The diff on an approval card. The case that matters most is the one the old
/// mini-diff got wrong every single time: a change in the **middle** of a file.
@Suite struct LineDiffTests {
    private func kinds(_ rows: [LineDiff.Row]) -> [LineDiff.Kind] { rows.map(\.kind) }
    private func texts(_ rows: [LineDiff.Row]) -> [String] { rows.map(\.text) }

    /// The regression this exists for. Showing the first three lines of each side
    /// gives three identical lines of context twice over and leaves the edit off
    /// the bottom — you were approving a change you could not see.
    @Test func aChangeInTheMiddleIsWhatYouSee() throws {
        let old = ["import Foundation", "", "func run() {", "    let x = 1", "    return x", "}"]
        let new = ["import Foundation", "", "func run() {", "    let x = 2", "    return x", "}"]
        let rows = LineDiff.rows(old: old, new: new, context: 1)
        #expect(texts(rows).contains("    let x = 1"))
        #expect(texts(rows).contains("    let x = 2"))
        #expect(!texts(rows).contains("import Foundation"))   // context, not the change
    }

    @Test func anAdditionIsAnAdditionAndNotARewrite() {
        let rows = LineDiff.rows(old: ["a", "b"], new: ["a", "new", "b"])
        #expect(kinds(rows) == [.same, .add, .same])
    }

    @Test func aDeletionIsADeletion() {
        let rows = LineDiff.rows(old: ["a", "gone", "b"], new: ["a", "b"])
        #expect(kinds(rows) == [.same, .del, .same])
    }

    /// Deletions print before insertions at the same spot, which is the order every
    /// diff tool uses and therefore the order people read.
    @Test func aReplacementReadsOldThenNew() {
        let rows = LineDiff.rows(old: ["x = 1"], new: ["x = 2"])
        #expect(kinds(rows) == [.del, .add])
    }

    /// Two edits far apart are two places, not one long wall of context.
    @Test func farApartChangesAreSeparatedByAGap() throws {
        let old = (1...20).map { "line \($0)" }
        var new = old
        new[1] = "line 2 changed"
        new[18] = "line 19 changed"
        let rows = LineDiff.rows(old: old, new: new, context: 1, limit: 40)
        #expect(rows.contains { $0.kind == .gap })
        #expect(texts(rows).contains("line 2 changed"))
        #expect(texts(rows).contains("line 19 changed"))
        // The fifteen untouched lines in between are summarised, not printed.
        #expect(!texts(rows).contains("line 10"))
    }

    /// The cap says what it took rather than stopping silently — silence is how the
    /// old one hid the edit.
    @Test func theCapAnnouncesItself() throws {
        let old = (1...40).map { "line \($0)" }
        let new = (1...40).map { "changed \($0)" }
        let rows = LineDiff.rows(old: old, new: new, context: 1, limit: 6)
        #expect(rows.count == 6)
        let last = try #require(rows.last)
        #expect(last.kind == .gap)
        #expect(last.text.contains("more line"))
    }

    @Test func identicalTextHasNothingToShow() {
        #expect(LineDiff.rows(old: ["a", "b"], new: ["a", "b"]).isEmpty)
    }

    @Test func oneSidedInputIsAllAddsOrAllDeletes() {
        #expect(kinds(LineDiff.rows(old: [], new: ["a", "b"])) == [.add, .add])
        #expect(kinds(LineDiff.rows(old: ["a", "b"], new: [])) == [.del, .del])
    }

    // MARK: - The changed middle of a one-line edit

    /// A renamed variable is one bright word, not two lines that look identical.
    @Test func aOneLineEditMarksOnlyWhatMoved() throws {
        let rows = LineDiff.rows(old: ["let total = a + b"], new: ["let total = a - b"])
        let del = try #require(rows.first { $0.kind == .del })
        let add = try #require(rows.first { $0.kind == .add })
        let delRange = try #require(del.emphasis)
        let addRange = try #require(add.emphasis)
        #expect(String(Array(del.text)[delRange]) == "+")
        #expect(String(Array(add.text)[addRange]) == "-")
    }

    /// A line rewritten from end to end shares nothing, and emphasising all of it
    /// would emphasise none of it.
    @Test func aWholeLineRewriteIsNotEmphasised() {
        #expect(LineDiff.changedMiddle("abc", "xyz") == nil)
    }

    /// Only a clean one-for-one swap gets the treatment: two lines replaced by one
    /// is a rewrite, and pairing them up would draw a resemblance that isn't there.
    @Test func multiLineReplacementsAreNotPairedUp() {
        let rows = LineDiff.rows(old: ["one", "two"], new: ["three"])
        #expect(rows.allSatisfy { $0.emphasis == nil })
    }

    /// The emphasis is measured in Characters. Anything that reads it as UTF-16 —
    /// which is what `NSRange` is — is wrong the moment a line holds an accent or
    /// an emoji, and out of bounds soon after.
    @Test func theRangeIsCharactersEvenWhenTheLineIsNot() throws {
        let rows = LineDiff.rows(old: ["let řeka = \"🙂 ok\""], new: ["let řeka = \"🙂 no\""])
        let add = try #require(rows.first { $0.kind == .add })
        let range = try #require(add.emphasis)
        let chars = Array(add.text)
        #expect(range.upperBound <= chars.count)
        #expect(String(chars[range]).contains("n"))
    }

    // MARK: - Fitting a long line

    /// The emphasis is pointless on exactly the lines that need it if the line
    /// truncates at the right edge first: two identical-looking lines and an
    /// ellipsis where the difference was.
    @Test func aChangeBeyondTheEdgeIsSlidIntoView() throws {
        let text = String(repeating: "x", count: 60) + "CHANGED" + String(repeating: "y", count: 20)
        let emphasis = 60..<67
        let (shown, moved) = LineDiff.window(text, emphasis: emphasis, width: 40)
        #expect(shown.hasPrefix("…"))
        let range = try #require(moved)
        #expect(String(Array(shown)[range]) == "CHANGED")
        #expect(range.upperBound <= 40)     // now inside what will be drawn
    }

    @Test func aLineThatAlreadyFitsIsLeftAlone() {
        let (shown, moved) = LineDiff.window("short line", emphasis: 0..<5, width: 40)
        #expect(shown == "short line")
        #expect(moved == 0..<5)
    }

    /// A `−`/`+` pair slid independently lands at two different offsets, and two
    /// lines meant to be compared column against column stop lining up.
    @Test func aPairCanBeSlidByOneSharedAmount() throws {
        let a = String(repeating: "x", count: 60) + "maxAge else { return nil }"
        let b = String(repeating: "x", count: 60) + "Self.maxAge else { return nil }"
        let startA = LineDiff.windowStart(a, emphasis: 60..<66, width: 40)
        let startB = LineDiff.windowStart(b, emphasis: 60..<71, width: 40)
        let shared = min(startA, startB)
        let slidA = LineDiff.slide(a, emphasis: 60..<66, by: shared)
        let slidB = LineDiff.slide(b, emphasis: 60..<71, by: shared)
        // The same characters begin both lines, so the eye can run down them.
        #expect(slidA.text.prefix(10) == slidB.text.prefix(10))
    }

    /// What a summary should say. Counting the whole old and new blocks reported a
    /// one-character edit inside an eight-line window as "+8 −8".
    @Test func theSummaryCountsWhatMovedAndNotTheWindow() {
        let old = ["a", "b", "c", "d", "e", "f", "g", "h"]
        var new = old
        new[3] = "d changed"
        let counts = LineDiff.counts(old: old, new: new)
        #expect(counts.added == 1)
        #expect(counts.removed == 1)
    }

}
