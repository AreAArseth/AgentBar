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

    /// A scan that ends inside a value has read a file TOML would not; nothing it says
    /// about positions may be acted on.
    @Test(arguments: [
        "a = 1\nb = \"\"\"\nnever closed\n",
        "a = '''\nnever closed",
        "a = [\n  1,\n",
        "a = { b = 1\n",
        "a = 1]\n",
        "a = \"one line, never closed\nb = 2\n",
    ])
    func aScanThatEndsInsideAValueIsIncomplete(_ text: String) {
        #expect(!TOMLOutline(text).isComplete)
    }

    @Test(arguments: ["", "a = 1", "a = 1\n# trailing", "a = 1\n[t]", "a = [\n  [1],\n]\n", "a = \"\"\"\nx\"\"\"\n"])
    func aScanThatEndsAtTheTopLevelIsComplete(_ text: String) {
        #expect(TOMLOutline(text).isComplete)
    }

    @Test(arguments: [
        ("\"\\u006eotify\" = 1\n", ["notify"]),
        ("\"\\U0000006Eotify\" = 1\n", ["notify"]),
        ("\"not\\x69fy\" = 1\n", ["notify"]),
        ("'notify' = 1\n", ["notify"]),
        ("a . \"b\\\"c\" . 'd' = 1\n", ["a", "b\"c", "d"]),
        ("[ \"x\" . y ]\n", ["x", "y"]),
        ("[[t.u-v_1]]\n", ["t", "u-v_1"]),
    ])
    func keysAreReadTheWayTOMLReadsThem(_ text: String, _ want: [String]) {
        let outline = TOMLOutline(text)
        #expect(outline.keyPath(of: outline.statements[0], in: text) == want)
    }

    @Test(arguments: ["\"\\q\" = 1\n", "\"open = 1\n", "\"\\uD800\" = 1\n", "a b = 1\n", "= 1\n"])
    func aKeyThatCannotBeReadIsNil(_ text: String) {
        let outline = TOMLOutline(text)
        #expect(outline.keyPath(of: outline.statements[0], in: text) == nil)
    }

    /// `claims` answers "would a top-level `notify = …` be a duplicate?", so a dotted
    /// key or a header under the name counts, and so does a key nobody can read.
    @Test(arguments: [
        ("\"\\u006eotify\" = [\"x\"]\n", true),
        ("notify.x = 1\n", true),
        ("a = 1\n[notify]\nx = 1\n", true),
        ("a = 1\n[notify.sub]\n", true),
        ("\"\\q\" = 1\n", true),
        ("notifyer = 1\n[t]\nnotify = 1\n", false),
        ("a = 1\n[tui]\n\"notify\" = true\n", false),
    ])
    func claimsSeesEverySpellingOfTheKey(_ text: String, _ want: Bool) {
        #expect(TOMLOutline(text).claims("notify", in: text) == want)
    }

    @Test(arguments: [
        ("notify = [\"/a]b/node\", '/c]/x.js']\n", ["/a]b/node", "/c]/x.js"]),
        ("notify = [ \"a\" ,\n  # why\n  'b', ]\n", ["a", "b"]),
        ("\"\\u006eotify\" = [\"a\\\"]\"]\n", ["a\"]"]),
        ("notify = []\n", []),
    ])
    func stringArraysAreReadWithTheirQuoting(_ text: String, _ want: [String]) {
        let outline = TOMLOutline(text)
        let got = outline.stringArray(assignedTo: "notify", by: outline.statements[0], in: text)
        #expect(got?.values == want)
        #expect(got.map { text[$0.end...].hasPrefix("\n") } == true)
    }

    @Test(arguments: ["notify = \"x\"\n", "notify = [\"a\", 1]\n", "other = [\"a\"]\n",
                      "notify = [\"a\"\n", "notify.x = [\"a\"]\n", "[notify]\n"])
    func anythingElseIsNotAStringArray(_ text: String) {
        let outline = TOMLOutline(text)
        #expect(outline.stringArray(assignedTo: "notify", by: outline.statements[0], in: text) == nil)
    }

    @Test func basicStringsRoundTrip() {
        let raw = "q\"uote \\ tab\t nl\n bell\u{07} ]"
        let text = "k = [\(TOMLOutline.basicString(raw))]\n"
        let outline = TOMLOutline(text)
        #expect(outline.isComplete)
        #expect(outline.stringArray(assignedTo: "k", by: outline.statements[0], in: text)?.values == [raw])
    }

    @Test func topLevelKeyIgnoresDottedAndLongerNames() {
        let text = "notify.x = 1\nnotifyer = 2\n[t]\nnotify = 3\n"
        #expect(TOMLOutline(text).topLevelKey("notify", in: text) == nil)
    }
}
