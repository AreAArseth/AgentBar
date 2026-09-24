import Foundation

/// Just enough of TOML's shape to put a top-level key where TOML will read it as one.
///
/// A bare `key = value` belongs to the last table header above it, so "append it at
/// the end" is only right for a file that has no tables, and `~/.codex/config.toml`
/// almost always has some. Every release before this one appended Codex's `notify`
/// there; in a file ending in `[shell_environment_policy.set]` that is a string table,
/// and Codex refused to load the config at all.
///
/// This finds where each statement starts, which of them come before the first table
/// header, and where the top-level section's content ends. Comments, strings (all four
/// kinds) and the inside of multi-line arrays and inline tables are skipped, because a
/// line there can start with `[` or `notify =` and be neither a header nor a key.
///
/// It is not a parser and validates nothing. What it cannot read, it reads as "not a
/// key", and the callers treat that as a reason to leave the file alone.
struct TOMLOutline {
    struct Statement: Equatable {
        /// Start of the line the statement begins on.
        let lineStart: String.Index
        /// Its first character: the key, or the `[` of a header.
        let start: String.Index
        let isHeader: Bool
        /// Before the first table header, so a key here is a top-level key.
        let isTopLevel: Bool
    }

    let statements: [Statement]
    /// Just past the line ending the last top-level statement; nil when there is none.
    let topLevelEnd: String.Index?
    /// Start of the line holding the first table header; nil for a file without one.
    let firstHeader: String.Index?
    /// The scan ended back at the top level: no string, array or inline table left
    /// open, and no bracket closed that was never opened. When it is false the other
    /// answers describe a file TOML would not read either, and nothing may be written
    /// on the strength of them. A key inserted after an unterminated `"""` is text.
    let isComplete: Bool

    init(_ text: String) {
        let b = Array(text.utf8)
        let n = b.count
        let lf: UInt8 = 0x0A, cr: UInt8 = 0x0D, sp: UInt8 = 0x20, tab: UInt8 = 0x09
        let hash: UInt8 = 0x23, dq: UInt8 = 0x22, sq: UInt8 = 0x27, bs: UInt8 = 0x5C
        let lbr: UInt8 = 0x5B, rbr: UInt8 = 0x5D, lbc: UInt8 = 0x7B, rbc: UInt8 = 0x7D

        enum Mode { case code, comment, header, basic, literal, multiBasic, multiLiteral }
        var mode = Mode.code
        var depth = 0
        var lineStart = 0
        var atLineStart = true
        var headerSeen = false
        var dirty = false
        var found: [(line: Int, start: Int, header: Bool, top: Bool)] = []
        var topEnd: Int?
        var header: Int?
        var broken = false

        func triple(_ i: Int, _ q: UInt8) -> Bool {
            i + 2 < n && b[i] == q && b[i + 1] == q && b[i + 2] == q
        }
        // An escape never swallows a line ending: the line bookkeeping has to see it.
        func escaped(_ i: Int) -> Int { i + 1 < n && b[i + 1] != lf ? 2 : 1 }

        var i = 0
        while i < n {
            let c = b[i]
            if c == lf {
                if !headerSeen && dirty { topEnd = i + 1 }
                dirty = false
                if mode == .basic || mode == .literal { broken = true }
                if mode == .comment || mode == .header || mode == .basic || mode == .literal {
                    mode = .code
                }
                i += 1
                lineStart = i
                atLineStart = mode == .code && depth == 0
                continue
            }
            let blank = c == sp || c == tab || c == cr
            if !headerSeen && !blank && mode != .comment && !(mode == .code && c == hash) {
                dirty = true
            }
            switch mode {
            case .comment:
                i += 1
            case .header:
                if c == hash {
                    mode = .comment
                    i += 1
                } else if c == dq || c == sq {
                    var j = i + 1
                    while j < n && b[j] != c && b[j] != lf { j += (b[j] == bs && c == dq) ? escaped(j) : 1 }
                    i = j < n && b[j] == c ? j + 1 : j
                } else {
                    i += 1
                }
            case .basic:
                if c == bs { i += escaped(i); continue }
                if c == dq { mode = .code }
                i += 1
            case .literal:
                if c == sq { mode = .code }
                i += 1
            case .multiBasic, .multiLiteral:
                let q = mode == .multiBasic ? dq : sq
                if mode == .multiBasic && c == bs {
                    i += escaped(i)
                } else if triple(i, q) {
                    i += 3
                    var extra = 0
                    while extra < 2 && i < n && b[i] == q { i += 1; extra += 1 }
                    mode = .code
                } else {
                    i += 1
                }
            case .code:
                if blank { i += 1; continue }
                if c == hash { mode = .comment; i += 1; continue }
                if atLineStart {
                    atLineStart = false
                    if c == lbr {
                        found.append((lineStart, i, true, false))
                        if header == nil { header = lineStart }
                        headerSeen = true
                        mode = .header
                        i += 1
                        continue
                    }
                    found.append((lineStart, i, false, !headerSeen))
                }
                if triple(i, dq) { mode = .multiBasic; i += 3; continue }
                if triple(i, sq) { mode = .multiLiteral; i += 3; continue }
                if c == dq { mode = .basic } else if c == sq { mode = .literal }
                else if c == lbr || c == lbc { depth += 1 }
                else if c == rbr || c == rbc {
                    if depth == 0 { broken = true }
                    depth = max(0, depth - 1)
                }
                i += 1
            }
        }
        if !headerSeen && dirty { topEnd = n }
        isComplete = !broken && depth == 0
            && (mode == .code || mode == .comment || mode == .header)

        let u = text.utf8
        func at(_ o: Int) -> String.Index { u.index(u.startIndex, offsetBy: o) }
        statements = found.map {
            Statement(lineStart: at($0.line), start: at($0.start), isHeader: $0.header, isTopLevel: $0.top)
        }
        topLevelEnd = topEnd.map(at)
        firstHeader = header.map(at)
    }

    /// The top-level statement assigning exactly `key`, however it is spelled: bare,
    /// literal-quoted, or basic-quoted with escapes (`"\u006eotify"` is `notify`).
    func topLevelKey(_ key: String, in text: String) -> Statement? {
        statements.first { $0.isTopLevel && !$0.isHeader && keyPath(of: $0, in: text) == [key] }
    }

    /// Whether a top-level `key = …` would collide with something already in the file:
    /// the key itself, a dotted key or a table header under it (`key.x = 1`, `[key]`),
    /// which TOML counts as defining it too. A key this cannot read counts as a
    /// collision, because the alternative is guessing and a wrong guess is a file
    /// Codex refuses to load.
    func claims(_ key: String, in text: String) -> Bool {
        statements.contains { s in
            guard s.isHeader || s.isTopLevel else { return false }
            guard let path = keyPath(of: s, in: text) else { return true }
            return path.first == key
        }
    }

    /// The dotted key a statement assigns, or the one its header names, each part
    /// decoded. Nil when it cannot be read.
    func keyPath(of s: Statement, in text: String) -> [String]? {
        var cur = Cursor(text.unicodeScalars, at: s.start)
        if s.isHeader {
            cur.advance()
            if cur.c == "[" { cur.advance() }
            return cur.key(endingAt: "]")
        }
        return cur.key(endingAt: "=")
    }

    /// A key statement's decoded dotted key, and where its value starts. Nil for a
    /// header or a key that cannot be read.
    func assignment(of s: Statement, in text: String) -> (key: [String], value: String.Index)? {
        guard !s.isHeader else { return nil }
        var cur = Cursor(text.unicodeScalars, at: s.start)
        guard let key = cur.key(endingAt: "=") else { return nil }
        cur.advance()
        cur.skipBlanks()
        return (key, cur.i)
    }

    /// Whether a header opens an array of tables (`[[a.b]]`) rather than a table.
    func isArrayHeader(_ s: Statement, in text: String) -> Bool {
        s.isHeader && text[s.start...].hasPrefix("[[")
    }

    /// The strings of an array a statement assigns to `key` (`key = ["a", 'b']`), and
    /// where the array ends. Read with the same quoting rules as everything else, so a
    /// `]` inside a quoted path is part of the path. Nil for any other shape.
    func stringArray(assignedTo key: String, by s: Statement, in text: String)
        -> (values: [String], end: String.Index)? {
        guard !s.isHeader else { return nil }
        var cur = Cursor(text.unicodeScalars, at: s.start)
        guard cur.key(endingAt: "=") == [key] else { return nil }
        cur.advance()
        cur.skipBlanks()
        guard let values = cur.stringArray() else { return nil }
        return (values, cur.i)
    }

    private struct Cursor {
        let s: String.UnicodeScalarView
        var i: String.Index
        init(_ s: String.UnicodeScalarView, at i: String.Index) { self.s = s; self.i = i }

        var c: Unicode.Scalar? { i < s.endIndex ? s[i] : nil }
        mutating func advance() { if i < s.endIndex { i = s.index(after: i) } }
        mutating func skipBlanks() { while c == " " || c == "\t" { advance() } }

        /// A dotted key up to `end`, which is left unread.
        mutating func key(endingAt end: Unicode.Scalar) -> [String]? {
            var parts: [String] = []
            while true {
                skipBlanks()
                if c == "\"" || c == "'" {
                    guard let part = string() else { return nil }
                    parts.append(part)
                } else {
                    var part = ""
                    while let ch = c, ("a"..."z").contains(ch) || ("A"..."Z").contains(ch)
                            || ("0"..."9").contains(ch) || ch == "_" || ch == "-" {
                        part.unicodeScalars.append(ch)
                        advance()
                    }
                    if part.isEmpty { return nil }
                    parts.append(part)
                }
                skipBlanks()
                if c == "." { advance(); continue }
                return c == end ? parts : nil
            }
        }

        /// A one-line basic or literal string, decoded; the cursor ends past its quote.
        mutating func string() -> String? {
            guard let q = c, q == "\"" || q == "'" else { return nil }
            advance()
            var out = ""
            while c != q {
                guard let ch = c, ch != "\n", ch != "\r" else { return nil }
                advance()
                if q == "\"" && ch == "\\" {
                    guard let decoded = escape() else { return nil }
                    out.unicodeScalars.append(decoded)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
            advance()
            return out
        }

        /// `[ "a", 'b', ]`, with the blank lines and comments TOML allows between items.
        mutating func stringArray() -> [String]? {
            guard c == "[" else { return nil }
            advance()
            var out: [String] = []
            while true {
                skipSpace()
                if c == "]" { advance(); return out }
                guard let v = string() else { return nil }
                out.append(v)
                skipSpace()
                if c == "," { advance(); continue }
                guard c == "]" else { return nil }
                advance()
                return out
            }
        }

        private mutating func skipSpace() {
            while let ch = c {
                if ch == " " || ch == "\t" || ch == "\r" || ch == "\n" { advance() }
                else if ch == "#" { while c != nil && c != "\n" { advance() } }
                else { return }
            }
        }

        /// One escape in a basic string, the backslash already read. TOML 1.0's set,
        /// plus 1.1's `\e` and `\xHH`; anything else is unreadable.
        private mutating func escape() -> Unicode.Scalar? {
            guard let e = c else { return nil }
            advance()
            func hex(_ n: Int) -> Unicode.Scalar? {
                var v: UInt32 = 0
                for _ in 0..<n {
                    guard let d = c, let x = UInt32(String(d), radix: 16) else { return nil }
                    advance()
                    v = v * 16 + x
                }
                return Unicode.Scalar(v)
            }
            switch e {
            case "b": return "\u{08}"
            case "t": return "\t"
            case "n": return "\n"
            case "f": return "\u{0C}"
            case "r": return "\r"
            case "e": return "\u{1B}"
            case "\"": return "\""
            case "\\": return "\\"
            case "x": return hex(2)
            case "u": return hex(4)
            case "U": return hex(8)
            default: return nil
            }
        }
    }

    /// `value` as a TOML basic string, quotes included.
    static func basicString(_ value: String) -> String {
        var out = "\""
        for u in value.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20 || u.value == 0x7F:
                out += String(format: "\\u%04X", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}
