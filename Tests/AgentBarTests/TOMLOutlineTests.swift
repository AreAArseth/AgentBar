import Testing
@testable import AgentBar

/// The outline only has to answer "is this a top-level key, and where does the
/// top-level section end" — but it has to answer it through every construct in which
/// a line can look like a key or a header without being one.
@Suite struct TOMLOutlineTests {
    private func keys(_ text: String, topLevel: Bool) -> [String] {
        TOMLOutline(text).statements.filter { !$0.isHeader && $0.isTopLevel == topLevel }.map {
            String(text[$0.start...].prefix { $0 != " " && $0 != "=" })
        }
    }

    @Test func keysBeforeTheFirstHeaderAreTopLevelAndTheRestAreNot() {
        let text = "a = 1\n  b = 2\n\n[t]\nc = 3\n[[u]]\nd = 4\n"
        #expect(keys(text, topLevel: true) == ["a", "b"])
        #expect(keys(text, topLevel: false) == ["c", "d"])
        let outline = TOMLOutline(text)
        #expect(outline.firstHeader == text.range(of: "[t]")?.lowerBound)
        #expect(outline.topLevelEnd == text.range(of: "b = 2\n")?.upperBound)
    }

    @Test func stringsArraysAndInlineTablesHideWhatLooksLikeStructure() {
        let text = """
            a = '''
            [x]
            b = 1'''
            c = "[y] \\" # not a comment"
            d = [
              [1, 2],
              { e = 3 },
            ]
            f = { g = [
            ] }
            h = \"""
            [i]
            [z]
            \"""
            [real."quoted ] bracket"] # and a comment
            j = 1

            """
        #expect(keys(text, topLevel: true) == ["a", "c", "d", "f", "h"])
        #expect(keys(text, topLevel: false) == ["j"])
        #expect(TOMLOutline(text).statements.filter(\.isHeader).count == 1)
        #expect(TOMLOutline(text).topLevelEnd == text.range(of: "[z]\n\"\"\"\n")?.upperBound)
    }

    @Test func aFileWithoutTablesOrContentHasNoTopLevelEnd() {
        #expect(TOMLOutline("").topLevelEnd == nil)
        #expect(TOMLOutline("# only a comment\n\n").topLevelEnd == nil)
        #expect(TOMLOutline("# only a comment\n[t]\n").topLevelEnd == nil)
        let bare = "a = 1"
        #expect(TOMLOutline(bare).topLevelEnd == bare.endIndex)
    }

    @Test func crlfLineEndingsReadTheSame() {
        let text = "a = 1\r\nnotify = [\"x\"]\r\n[t]\r\nnotify = 2\r\n"
        let outline = TOMLOutline(text)
        #expect(outline.topLevelKey("notify", in: text)?.start == text.range(of: "notify")?.lowerBound)
        #expect(keys(text, topLevel: false) == ["notify"])
    }

    @Test func topLevelKeyIgnoresDottedAndLongerNames() {
        let text = "notify.x = 1\nnotifyer = 2\n[t]\nnotify = 3\n"
        #expect(TOMLOutline(text).topLevelKey("notify", in: text) == nil)
    }
}
