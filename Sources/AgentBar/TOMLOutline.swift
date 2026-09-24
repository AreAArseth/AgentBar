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
                else if c == rbr || c == rbc { depth = max(0, depth - 1) }
                i += 1
            }
        }
        if !headerSeen && dirty { topEnd = n }

        let u = text.utf8
        func at(_ o: Int) -> String.Index { u.index(u.startIndex, offsetBy: o) }
        statements = found.map {
            Statement(lineStart: at($0.line), start: at($0.start), isHeader: $0.header, isTopLevel: $0.top)
        }
        topLevelEnd = topEnd.map(at)
        firstHeader = header.map(at)
    }

    /// The top-level statement assigning `key`, bare or quoted; dotted keys don't count.
    func topLevelKey(_ key: String, in text: String) -> Statement? {
        let pattern = "(\(key)|\"\(key)\"|'\(key)')[ \\t]*="
        return statements.first {
            $0.isTopLevel && !$0.isHeader
                && text.range(of: pattern, options: [.regularExpression, .anchored],
                              range: $0.start..<text.endIndex) != nil
        }
    }
}
