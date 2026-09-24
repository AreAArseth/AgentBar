import Foundation

/// Idempotent hook installation, re-run on every launch (scripts refresh with the app
/// version; configs are only rewritten when the content actually changes). Copies the
/// bundled hook scripts to `~/.agentbar/hooks/` and wires them into each agent's own
/// hook mechanism. Never blocks the UI; failures are logged and retried on next launch.
enum HookInstaller {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static var hooksDir: URL { home.appendingPathComponent(".agentbar/hooks", isDirectory: true) }

    /// Resolved once per launch: the fallback probes the user's login shell, which can
    /// cost hundreds of ms on nvm/fnm setups — never pay that four times.
    private static let nodePath: String? = findNode()
    /// The interpreter and the scripts, for anything that needs to *run* a hook
    /// rather than install one — `ApprovalSelfTest` is the only caller.
    static var resolvedNode: String? { nodePath }
    static var installedHooks: URL { hooksDir }

    /// Agent ids whose hooks this launch actually wired — the tools the user has,
    /// minus any whose config we refused to touch. The welcome window reports it, so
    /// an otherwise invisible side effect becomes something the user can check.
    /// Mutated and read on the MAIN queue only: the install pass runs on a utility
    /// queue and hands each note to main, so a welcome window shown mid-pass reads
    /// a consistent (possibly still growing) list instead of racing the append.
    /// `onFinish` is enqueued after every note, so "done" really is complete.
    private(set) static var wired: [String] = []
    /// Called on the main queue when the install pass finishes.
    static var onFinish: (() -> Void)?

    private static func note(_ agentID: String) {
        DispatchQueue.main.async {
            if !wired.contains(agentID) { wired.append(agentID) }
        }
    }

    static func installIfNeeded() {
        DispatchQueue.global(qos: .utility).async {
            guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("hooks") else { return }
            // Without the scripts on disk there is nothing worth wiring to.
            guard step("copy scripts", { try copyScripts(from: bundled) }) else {
                DispatchQueue.main.async { onFinish?() }
                return
            }
            for dir in claudeConfigDirs() {
                _ = step("claude (\(dir.path))") { try installClaude(configDir: dir) }
            }
            _ = step("codex", installCodex)
            _ = step("cursor", installCursor)
            _ = step("gemini", installGemini)
            _ = step("antigravity", installAntigravity)
            _ = step("qwen", installQwen)
            _ = step("copilot", installCopilot)
            _ = step("opencode", installOpenCode)
            DispatchQueue.main.async { onFinish?() }
        }
    }

    /// Each integration is independent: one agent's config blowing up must not cost the
    /// user every integration that comes after it in the pass. Returns whether it ran.
    @discardableResult
    private static func step(_ name: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            return true
        } catch {
            NSLog("AgentBar hook install step '\(name)' failed: \(error)")
            return false
        }
    }

    /// Every Claude config dir we should wire hooks into. Covers a custom
    /// `CLAUDE_CONFIG_DIR` (issue #4) — read from the app's environment if present, or
    /// from a hint file the installer drops (the app is launched via `open`, so it
    /// usually doesn't inherit the shell's env; install.sh rewrites or clears the hint
    /// on every run, so it can't go stale). The default `~/.claude` is always
    /// included so a user who runs Claude both ways stays covered. Deduped.
    private static func claudeConfigDirs() -> [URL] {
        var dirs = [home.appendingPathComponent(".claude")]
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            dirs.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        let hint = home.appendingPathComponent(".agentbar/claude-config-dir")
        if let raw = try? String(contentsOf: hint, encoding: .utf8) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { dirs.append(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) }
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    /// Always refresh the script copies — they're versioned with the app.
    private static func copyScripts(from bundled: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        for agent in (try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil)) ?? [] {
            let dest = hooksDir.appendingPathComponent(agent.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: agent, to: dest)
        }
    }

    /// Parse an existing JSON config. Missing file → empty object (fresh install).
    /// Present-but-unparseable (JSONC comments, trailing comma, torn write) → nil:
    /// the caller must SKIP, never overwrite — rewriting from `[:]` would silently
    /// destroy the user's config.
    /// An unreadable file counts as present-but-unparseable, not as missing: a
    /// permission glitch or a torn read must never look like a fresh install.
    private static func readConfig(at url: URL) -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
            NSLog("AgentBar: \(url.path) exists but could not be read (\(error)) — leaving it untouched")
            return nil
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("AgentBar: \(url.path) exists but is not parseable JSON — leaving it untouched")
            return nil
        }
        return parsed
    }

    /// Atomic write, skipped when the file already has exactly this content — avoids
    /// mtime churn (tools watch these configs) and shrinks the window for racing a
    /// tool that is writing its own settings at the same moment.
    private static func writeIfChanged(_ data: Data, to url: URL) throws {
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try data.write(to: url, options: .atomic)
    }

    /// Paths that keep naming *a* node across upgrades.
    ///
    /// Order matters here in a way it does not in the Linux CLI. There this list only
    /// maps an already-known-good interpreter onto an equivalent alias, so any match
    /// is the same binary and the order is arbitrary. Here it also decides which node
    /// gets used at all — so Homebrew's prefix stays ahead of `/usr/local`, where an
    /// old nodejs.org pkg tends to linger.
    static var stableNodePaths: [String] {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node",
         home.appendingPathComponent(".local/bin/node").path]
    }

    /// Swap a version-pinned path for a stable alias that resolves to the same binary.
    ///
    /// Whatever this returns is written into config files that outlive the next node
    /// upgrade, so a pinned path is a silent time bomb: after `nvm install 22` or a
    /// Homebrew Cellar bump the interpreter named in every config is simply gone, and
    /// every hook stops firing with no error anywhere — indistinguishable from "the
    /// agent isn't reporting". The Linux CLI has done this since 5d5316c; this side
    /// never got it.
    ///
    /// The input comes back unchanged when no alias resolves to the same binary: an
    /// nvm-only machine genuinely has none, and `agentbar doctor` says so rather than
    /// this guessing at a path that does not exist.
    static func stableNodeAlias(for path: String) -> String {
        guard let target = realPath(path) else { return path }
        let fm = FileManager.default
        let alias = stableNodePaths.first {
            $0 != path && fm.isExecutableFile(atPath: $0) && realPath($0) == target
        }
        return alias ?? path
    }

    /// `realpath(3)` — symlinks resolved, exactly what the CLI's `fs.realpathSync` does.
    static func realPath(_ path: String) -> String? {
        guard let c = realpath(path, nil) else { return nil }
        defer { free(c) }
        return String(cString: c)
    }

    /// Find a node binary the hooks can rely on (login-shell PATHs vary wildly).
    private static func findNode() -> String? {
        if let hit = stableNodePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        // Version-manager setups (nvm/fnm) and Cellar paths: ask the user's shell once.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
        } catch {
            NSLog("AgentBar: could not probe the login shell for node (\(error))")
            return nil
        }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // This is where the pinned paths come from: under nvm/fnm `command -v node`
        // answers with the version's own bin dir. Map it back onto a stable alias
        // when one names the same binary.
        return out.isEmpty ? nil : stableNodeAlias(for: out)
    }

    // MARK: - Claude Code (<configDir>/settings.json)

    private static func installClaude(configDir: URL) throws {
        guard let node = nodePath else { NSLog("AgentBar: node not found, Claude hooks skipped"); return }
        let settingsURL = configDir.appendingPathComponent("settings.json")
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard var root = readConfig(at: settingsURL) else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        let dir = hooksDir.appendingPathComponent("claude").path
        let events: [(event: String, cmd: String, matcher: Bool, timeout: Int?)] = [
            ("SessionStart",     "\"\(node)\" \"\(dir)/lifecycle.js\" start", false, nil),
            ("SessionEnd",       "\"\(node)\" \"\(dir)/lifecycle.js\" end", false, nil),
            ("UserPromptSubmit", "\"\(node)\" \"\(dir)/update.js\" prompt", false, nil),
            ("PreToolUse",       "\"\(node)\" \"\(dir)/update.js\" pre", true, nil),
            ("PostToolUse",      "\"\(node)\" \"\(dir)/update.js\" post", true, nil),
            // Blocking approval hook: its own wait is 600s, so give Claude Code slack.
            // (No Notification hook: late permission notifications used to overwrite
            // newer state and strand sessions on "needs approval".)
            ("PermissionRequest","\"\(node)\" \"\(dir)/permission.js\"", true, 630),
            ("Stop",             "\"\(node)\" \"\(dir)/update.js\" stop", false, nil),
            // "Compacting…" while the session summarises its context. There is no
            // PostCompact here on purpose: the SessionStart (source "compact") that
            // follows every compaction already ends it, and an event name an older
            // Claude Code does not know is a settings file it may refuse.
            ("PreCompact",       "\"\(node)\" \"\(dir)/update.js\" compact", false, nil),
        ]

        // Drop earlier AgentBar entries from EVERY event (path match), so events we
        // no longer register (e.g. Notification) don't linger from old installs.
        for (event, value) in hooks {
            guard var rules = value as? [[String: Any]] else { continue }
            rules.removeAll { rule in
                ((rule["hooks"] as? [[String: Any]]) ?? []).contains { cmd in
                    (cmd["command"] as? String)?.contains("/.agentbar/hooks/claude/") == true
                }
            }
            if rules.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = rules }
        }

        for e in events {
            var rules = hooks[e.event] as? [[String: Any]] ?? []
            var hookEntry: [String: Any] = ["type": "command", "command": e.cmd]
            if let t = e.timeout { hookEntry["timeout"] = t }
            var rule: [String: Any] = ["hooks": [hookEntry]]
            if e.matcher { rule["matcher"] = "*" }
            rules.append(rule)
            hooks[e.event] = rules
        }
        root["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try writeIfChanged(data, to: settingsURL) // never leave settings.json half-written
        note("claude")
    }

    // MARK: - Codex (~/.codex/config.toml: the hooks block, and the notify bridge)

    private static func installCodex() throws {
        guard let node = nodePath else { NSLog("AgentBar: node not found, Codex hooks skipped"); return }
        let codexDir = home.appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: codexDir.path) else { return } // not a Codex user
        let configURL = codexDir.appendingPathComponent("config.toml")
        let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let script = hooksDir.appendingPathComponent("codex/notify.js").path

        // Two independent keys in one file, applied in order. `notify` is the older
        // integration and stays: it is the only thing that reports a Codex session
        // until the human accepts the hooks in Codex's own trust prompt.
        guard TOMLOutline(config).isComplete else {
            NSLog("AgentBar: ~/.codex/config.toml ends inside an unterminated value, not touching it")
            return
        }
        var text = config
        switch codexPlan(config: text, node: node, script: script) {
        case .foreignNotify:
            NSLog("AgentBar: ~/.codex/config.toml already has a notify hook, not touching it")
        case .unchanged:
            break
        case .write(let next, let repaired):
            text = next
            if repaired { NSLog("AgentBar: repaired its notify line in ~/.codex/config.toml") }
        }
        if case .write(let next, _) = codexHooksPlan(config: text, node: node,
                                                     dir: hooksDir.path, path: configURL.path) {
            text = next
        }
        if text != config { try text.write(to: configURL, atomically: true, encoding: .utf8) }
        note("codex")
    }

    /// The events Codex fires, and which shared script answers each.
    ///
    /// Codex speaks Claude's hook dialect, so these are the `claude/` scripts, reached
    /// through `codex/hook.js` — Codex's handler has no `env` field and runs the command
    /// without a shell, so the shim is where `AGENTBAR_AGENT` and the row prefix get set.
    ///
    /// Timeouts are per event and Codex clamps them: `SessionEnd`'s ceiling is 3s, so
    /// asking for 5 there would earn a warning on every session. `PermissionRequest`
    /// keeps its 630 — above `permission.js`'s own 600s wait, so the hook is the thing
    /// that gives up first and exits silently into Codex's own prompt, rather than being
    /// killed mid-wait. Verified against codex-cli 0.155.0; see Scripts/hooks/codex/README.md.
    static let codexEvents: [(event: String, script: String, arg: String?, timeout: Int)] = [
        ("SessionStart",     "lifecycle.js", "start",  5),
        ("SessionEnd",       "lifecycle.js", "end",    3),
        ("UserPromptSubmit", "update.js",    "prompt", 5),
        ("PreToolUse",       "update.js",    "pre",    5),
        ("PostToolUse",      "update.js",    "post",   5),
        ("Stop",             "update.js",    "stop",   5),
        ("PermissionRequest", "permission.js", nil,   630),
    ]

    static let codexBegin = "# >>> agentbar >>> written by AgentBar; edit outside these two lines"
    static let codexEnd = "# <<< agentbar <<<"

    /// The block AgentBar owns inside `~/.codex/config.toml`.
    ///
    /// Array-of-tables rather than dotted keys, because Codex writes its own
    /// `[hooks.state]` section when a human trusts a hook, and a `hooks.X = […]`
    /// dotted key would make that a redefinition TOML refuses. Appended at the end of
    /// the file for the same family of reason: a bare `key = value` written after a
    /// `[[table]]` header belongs to that table, so a block in the middle would
    /// silently capture whatever the user adds next.
    static func codexHooksBlock(node: String, dir: String) -> String {
        var out = [codexBegin]
        for e in codexEvents {
            let arg = e.arg.map { " " + $0 } ?? ""
            out += ["[[hooks.\(e.event)]]",
                    "[[hooks.\(e.event).hooks]]",
                    "type = \"command\"",
                    "command = \"\\\"\(node)\\\" \\\"\(dir)/codex/hook.js\\\" \(e.script)\(arg)\"",
                    "timeout = \(e.timeout)"]
            if e.event == "PermissionRequest" {
                out.append("statusMessage = \"Waiting for you in AgentBar\"")
            }
            out.append("")
        }
        out.append(codexEnd)
        return out.joined(separator: "\n")
    }

    /// Replace our block where it already is, or append it at the end. Pure, so the
    /// "unknown keys survive byte for byte" promise is a test rather than a hope.
    ///
    /// `path` is the config file's own path, which Codex puts in every trust key.
    /// With it, a handler this rewrites loses its trust entry (see below); without
    /// it, trust entries are left as they are.
    static func codexHooksPlan(config: String, node: String, dir: String, path: String? = nil) -> CodexPlan {
        let outline = TOMLOutline(config)
        guard outline.isComplete else { return .unchanged }
        let block = codexHooksBlock(node: node, dir: dir)
        if let range = codexBlockRange(config, outline: outline) {
            let current = String(config[range])
            if current == block { return .unchanged }
            // Codex adds a new table at the end of the document, ahead of the trailing
            // comment, and that comment is our end marker: the `[hooks.state]` written
            // when a human trusts these hooks lands inside this block. Replacing the
            // block whole deleted it on the next launch and Codex asked all over again.
            // Every table here that is not ours moves below the marker, intact.
            let inner = config.index(range.lowerBound, offsetBy: codexBegin.count)
                ..< config.index(range.upperBound, offsetBy: -codexEnd.count)
            guard let foreign = codexForeignTables(in: String(config[inner])) else { return .unchanged }
            var next = config
            next.replaceSubrange(range, with: foreign.isEmpty ? block : block + "\n\n" + foreign)
            // A handler whose tables changed (a node that moved, a new timeout) is one
            // Codex no longer trusts: its hash covers exactly those tables, so it skips
            // the hook until a human answers again. Keeping the old entry would tell
            // doctor and notify.js otherwise, and notify.js would fall silent while
            // nothing reports the session. The entry goes, as Codex will treat it.
            if let path {
                let before = codexAgentBarHandlers(config, outline: TOMLOutline(config))
                let after = codexAgentBarHandlers(next, outline: TOMLOutline(next))
                let stale = Set(before.compactMap { event, old -> String? in
                    after[event]?.tables == old.tables ? nil
                        : "\(path):\(Diagnostics.codexEventLabel(event)):\(old.group):\(old.handler)"
                })
                if !stale.isEmpty { next = removingCodexTrust(for: stale, in: next) }
            }
            return .write(next, repaired: true)
        }
        // Marker text that is not a pair of standalone comment lines is someone
        // else's (inside a string, say): nothing here can tell what replacing or
        // appending around it would mean, so the file is left as it is.
        if config.contains(codexBegin) || config.contains(codexEnd) { return .unchanged }
        var next = config
        if !next.isEmpty && !next.hasSuffix("\n") { next += "\n" }
        if !next.isEmpty { next += "\n" }
        return .write(next + block + "\n", repaired: false)
    }

    /// Our block, from the `#` of the begin marker to the end of the end marker, when
    /// both are comments with a line to themselves in the file's own structure. The
    /// same text inside a multi-line string is part of that string, however
    /// well-formed the TOML between the two copies happens to be.
    static func codexBlockRange(_ text: String, outline: TOMLOutline) -> Range<String.Index>? {
        outline.commentBlock(from: codexBegin, to: codexEnd, in: text)
    }

    /// AgentBar's handler for each event: its group and handler positions, counted the
    /// way Codex's discovery counts them (`[[hooks.<Event>]]` groups in file order,
    /// `[[hooks.<Event>.hooks]]` handlers under each), and the text of its group and
    /// handler tables, which is what Codex's trust hash covers. A handler is AgentBar's
    /// when its decoded `command` runs `codex/hook.js` from AgentBar's hooks folder; a
    /// comment naming that path is not the command.
    static func codexAgentBarHandlers(_ text: String, outline: TOMLOutline)
        -> [String: (group: Int, handler: Int, tables: String)] {
        var out: [String: (group: Int, handler: Int, tables: String)] = [:]
        var group: [String: Int] = [:], handler: [String: Int] = [:]
        var groupTable: [String: Range<String.Index>] = [:]
        var open: (event: String, start: String.Index, ours: Bool)?
        var groupOpen: (event: String, start: String.Index)?

        func close(at end: String.Index) {
            if let g = groupOpen { groupTable[g.event] = g.start..<end; groupOpen = nil }
            guard let h = open else { return }
            open = nil
            guard h.ours, out[h.event] == nil, let g = group[h.event], let i = handler[h.event] else { return }
            let body = (groupTable[h.event].map { String(text[$0]) } ?? "") + text[h.start..<end]
            let tables = body.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .joined(separator: "\n")
            out[h.event] = (g, i, tables)
        }

        for s in outline.statements {
            if s.isHeader {
                close(at: s.lineStart)
                guard outline.isArrayHeader(s, in: text), let p = outline.keyPath(of: s, in: text),
                      p.first == "hooks", p.count >= 2 else { continue }
                let event = p[1]
                if p.count == 2 {
                    group[event, default: -1] += 1
                    handler[event] = -1
                    groupTable[event] = nil
                    groupOpen = (event, s.lineStart)
                } else if p.count == 3, p[2] == "hooks", group[event] != nil {
                    handler[event, default: -1] += 1
                    open = (event, s.lineStart, false)
                }
            } else if let h = open, !h.ours,
                      let a = outline.assignment(of: s, in: text), a.key == ["command"],
                      outline.string(at: a.value, in: text)?.contains("/.agentbar/hooks/codex/hook.js") == true {
                open?.ours = true
            }
        }
        close(at: text.endIndex)
        return out
    }

    /// `text` without Codex's `[hooks.state]` entries for `keys`, in any spelling:
    /// the `[hooks.state."k"]` table with its keys, or a `"k".…` / `"k" = { … }` line
    /// under `[hooks.state]`.
    static func removingCodexTrust(for keys: Set<String>, in text: String) -> String {
        let outline = TOMLOutline(text)
        guard outline.isComplete else { return text }
        var cut: [Range<String.Index>] = []
        var table: [String]? = []
        var dropping: String.Index?
        for s in outline.statements {
            if s.isHeader {
                if let from = dropping { cut.append(from..<s.lineStart); dropping = nil }
                table = outline.isArrayHeader(s, in: text) ? nil : outline.keyPath(of: s, in: text)
                if let t = table, t.count == 3, t[0] == "hooks", t[1] == "state", keys.contains(t[2]) {
                    dropping = s.lineStart
                }
                continue
            }
            guard dropping == nil, let t = table, let a = outline.assignment(of: s, in: text) else { continue }
            let full = t + a.key
            if full.count >= 3, full[0] == "hooks", full[1] == "state", keys.contains(full[2]) {
                cut.append(wholeLines(of: s.lineStart..<a.value, in: text))
            }
        }
        if let from = dropping { cut.append(from..<text.endIndex) }
        var out = "", from = text.startIndex
        for r in cut { out += text[from..<r.lowerBound]; from = r.upperBound }
        return out + text[from...]
    }

    /// The tables between our markers that `codexHooksBlock` did not write, each with
    /// its keys, in the order they stood. Nil when the text between the markers does
    /// not read as whole TOML on its own (a marker inside someone's string, say):
    /// then there is no telling what a replacement would cut, and nothing is replaced.
    static func codexForeignTables(in inner: String) -> String? {
        let ours = Set(codexEvents.flatMap { ["[[hooks.\($0.event)]]", "[[hooks.\($0.event).hooks]]"] })
        let outline = TOMLOutline(inner)
        guard outline.isComplete else { return nil }
        let headers = outline.statements.filter(\.isHeader)
        var out: [String] = []
        for (i, h) in headers.enumerated() {
            let lineEnd = inner[h.start...].firstIndex(where: \.isNewline) ?? inner.endIndex
            let header = inner[h.start..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            if ours.contains(header) { continue }
            let next = i + 1 < headers.count ? headers[i + 1].lineStart : inner.endIndex
            out.append(inner[h.lineStart..<next].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out.joined(separator: "\n\n")
    }

    /// What `installCodex` should do with the TOML it found.
    enum CodexPlan: Equatable {
        /// Wired and working, or wired in a shape we deliberately won't touch.
        case unchanged
        /// Someone else's `notify` key — Codex allows exactly one, so we stay out.
        case foreignNotify
        /// The full text to write; `repaired` distinguishes a fix from a first install.
        case write(String, repaired: Bool)
    }

    /// Pure so the repair has a test that doesn't need a `~/.codex` on the machine.
    ///
    /// The interesting case is the second one. Every other agent's config is rewritten
    /// whenever its content differs, so an interpreter that moved heals on the next
    /// launch; Codex used to stop at the marker, which made it the one integration
    /// where a stale node path was permanent — relaunching the app, reinstalling it,
    /// nothing rewrote that line, and the rows just never appeared again.
    static func codexPlan(
        config: String, node: String, script: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> CodexPlan {
        let ours = "notify = [\(TOMLOutline.basicString(node)), \(TOMLOutline.basicString(script))]"
        let outline = TOMLOutline(config)
        // A file that ends inside an unterminated value is one TOML will not read
        // either, and every position below would be a guess into that value.
        guard outline.isComplete else { return .unchanged }
        // Ours is a notify array with our hooks path in it, read as TOML reads it: a
        // `]` inside a quoted node or home path belongs to the path.
        let mine = outline.statements.compactMap { s -> (top: Bool, line: Range<String.Index>, values: [String])? in
            guard let array = outline.stringArray(assignedTo: "notify", by: s, in: config),
                  array.values.contains(where: { $0.contains("/.agentbar/hooks/codex/") })
            else { return nil }
            return (s.isTopLevel, s.lineStart..<array.end, array.values)
        }

        // Our line under a table header is what every release up to 1.30.0 wrote into
        // a file that had tables: Codex reads it as that table's key and either rejects
        // the whole config or quietly never notifies. It carries our path, so it is
        // ours to take out; what happens next is decided on the file without it.
        let stray = mine.filter { !$0.top }.map { wholeLines(of: $0.line, in: config) }
        if !stray.isEmpty {
            var fixed = "", from = config.startIndex
            for r in stray {
                fixed += config[from..<r.lowerBound]
                from = r.upperBound
            }
            fixed += config[from...]
            if case .write(let next, _) = codexPlan(config: fixed, node: node, script: script,
                                                   isExecutable: isExecutable) {
                return .write(next, repaired: true)
            }
            return .write(fixed, repaired: true)
        }

        if let line = mine.first?.line {
            guard let interpreter = mine.first?.values.first, !isExecutable(interpreter)
            else { return .unchanged }
            var next = config
            next.replaceSubrange(line, with: ours)
            return .write(next, repaired: true)
        }
        // Our marker somewhere the array reader could not read — a comment, a value
        // that is not an array of one-line strings: leave it alone rather than
        // appending a second notify key.
        //
        // Our own hooks block is cut out first, and that is not a detail. It carries the
        // same path on every line, so without the cut a config holding the block and no
        // `notify` at all would read as "notify is already wired" and notify would never
        // be installed again.
        if withoutCodexBlock(config).contains("/.agentbar/hooks/codex/") { return .unchanged }
        // Codex takes one top-level `notify`, on whatever line the user put it.
        // So does anything else that already defines `notify` (`notify.x`, `[notify]`),
        // and a key that cannot be read at all: adding ours beside either would be a
        // duplicate key, and Codex refuses the whole file for one.
        if outline.claims("notify", in: config) { return .foreignNotify }

        // Never at the end of the file: after a table header, a bare key is that
        // table's. It goes after the last top-level statement, or above the first
        // header when there is none.
        var next = config
        if let end = outline.topLevelEnd {
            let lead = end == config.endIndex && !config.hasSuffix("\n") ? "\n" : ""
            next.insert(contentsOf: lead + ours + "\n", at: end)
        } else if let header = outline.firstHeader {
            next.insert(contentsOf: ours + "\n\n", at: header)
        } else {
            if !next.isEmpty && !next.hasSuffix("\n") { next += "\n" }
            next += ours + "\n"
        }
        return .write(next, repaired: false)
    }

    /// `range` widened to whole lines, including the line ending after it. `isNewline`
    /// rather than `"\n"`: a CRLF ending is one `Character`, and never equals `"\n"`.
    static func wholeLines(of range: Range<String.Index>, in text: String) -> Range<String.Index> {
        let end = text[range.upperBound...].firstIndex(where: \.isNewline).map { text.index(after: $0) }
            ?? text.endIndex
        return range.lowerBound..<end
    }

    /// The config with AgentBar's own hooks block removed, for the questions that are
    /// about what the *user* put in the file.
    static func withoutCodexBlock(_ config: String) -> String {
        guard let range = codexBlockRange(config, outline: TOMLOutline(config)) else { return config }
        var out = config
        out.removeSubrange(range)
        return out
    }
    // MARK: - Cursor CLI (~/.cursor/hooks.json)

    private static func installCursor() throws {
        // ~/.cursor also exists for IDE-only users; that's intentional — the same
        // hooks.json drives IDE agent sessions, and the bridge is observe-only.
        let cursorDir = home.appendingPathComponent(".cursor")
        guard FileManager.default.fileExists(atPath: cursorDir.path) else { return } // not a Cursor user
        let cfgURL = cursorDir.appendingPathComponent("hooks.json")
        let scriptURL = hooksDir.appendingPathComponent("cursor/cursor.js")
        try pinNodeShebang(of: scriptURL)

        guard var root = readConfig(at: cfgURL) else { return }
        root["version"] = root["version"] ?? 1
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let marker = "/.agentbar/hooks/cursor/"

        // Cursor's command is a single executable path (our script is +x with a shebang).
        // Only observational events: the before* hooks gate permissions and belong to
        // the user, not to a status bridge.
        for event in ["sessionStart", "sessionEnd", "preToolUse", "postToolUse",
                      "afterAgentResponse", "stop"] {
            var rules = (hooks[event] as? [[String: Any]] ?? [])
                .filter { ($0["command"] as? String)?.contains(marker) != true }
            rules.append(["command": scriptURL.path])
            hooks[event] = rules
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try writeIfChanged(data, to: cfgURL)
        note("cursor")
    }

    /// Cursor runs the script directly via its shebang, and a GUI-launched Cursor
    /// inherits the launchd PATH — often without /opt/homebrew/bin — so
    /// `#!/usr/bin/env node` would silently never fire. Pin the resolved node path.
    private static func pinNodeShebang(of scriptURL: URL) throws {
        guard let node = nodePath else {
            NSLog("AgentBar: node not found, \(scriptURL.lastPathComponent) left on its bundled shebang")
            return
        }
        guard var text = try? String(contentsOf: scriptURL, encoding: .utf8),
              text.hasPrefix("#!") else { return }
        let rest = text.drop(while: { $0 != "\n" })
        text = "#!\(node)\(rest)"
        try text.write(to: scriptURL, atomically: false, encoding: .utf8) // keep inode + mode
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    // MARK: - Antigravity (~/.gemini/antigravity{,-cli}/hooks.json)

    /// Antigravity 2.x (desktop app and `agy` CLI) reads hooks.json from its own
    /// customization dir. Top level is named rule groups; we own exactly one key
    /// ("agentbar") and never touch the rest. The script runs via its shebang, so
    /// the node path is pinned the same way as Cursor's bridge.
    private static func installAntigravity() throws {
        let scriptURL = hooksDir.appendingPathComponent("antigravity/antigravity.js")
        let dirs = ["antigravity", "antigravity-cli"].map {
            home.appendingPathComponent(".gemini/\($0)", isDirectory: true)
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !dirs.isEmpty else { return } // not an Antigravity user
        try pinNodeShebang(of: scriptURL)

        // Observational events only; PreToolUse stays decision-free (no stdout).
        // The stdin payload carries no event name, so it rides along as an argument.
        var group: [String: Any] = [:]
        for event in ["PreInvocation", "PreToolUse", "PostToolUse", "PostInvocation", "Stop"] {
            let entry: [String: Any] = ["type": "command",
                                        "command": "\"\(scriptURL.path)\" \(event)",
                                        "timeout": 5]
            var rule: [String: Any] = ["hooks": [entry]]
            if event.hasSuffix("ToolUse") { rule["matcher"] = "*" }
            group[event] = [rule]
        }
        for dir in dirs {
            let cfgURL = dir.appendingPathComponent("hooks.json")
            guard var root = readConfig(at: cfgURL) else { continue }
            root["agentbar"] = group
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try writeIfChanged(data, to: cfgURL)
            note("antigravity")
        }
    }

    // MARK: - Qwen Code (~/.qwen/settings.json)

    /// Qwen Code speaks Claude-style hooks (same event names, same stdin JSON),
    /// so the claude/ scripts serve it as-is — AGENTBAR_AGENT names the rows.
    /// Observational events only: its PermissionRequest decision contract is
    /// unverified against permission.js, and a blocking hook must never be wired
    /// on faith. Timeouts here are milliseconds (Qwen), not seconds (Claude).
    private static func installQwen() throws {
        guard let node = nodePath else { NSLog("AgentBar: node not found, Qwen hooks skipped"); return }
        let qwenDir = home.appendingPathComponent(".qwen")
        guard FileManager.default.fileExists(atPath: qwenDir.path) else { return } // not a Qwen user
        let cfgURL = qwenDir.appendingPathComponent("settings.json")
        let dir = hooksDir.appendingPathComponent("claude").path

        guard var root = readConfig(at: cfgURL) else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let marker = "/.agentbar/hooks/claude/"

        // Drop earlier AgentBar entries from every event before re-adding.
        for (event, value) in hooks {
            guard var rules = value as? [[String: Any]] else { continue }
            rules.removeAll { rule in
                ((rule["hooks"] as? [[String: Any]]) ?? []).contains { cmd in
                    (cmd["command"] as? String)?.contains(marker) == true
                }
            }
            if rules.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = rules }
        }

        let events: [(event: String, cmd: String, matcher: Bool)] = [
            ("SessionStart",     "\"\(node)\" \"\(dir)/lifecycle.js\" start", false),
            ("SessionEnd",       "\"\(node)\" \"\(dir)/lifecycle.js\" end", false),
            ("UserPromptSubmit", "\"\(node)\" \"\(dir)/update.js\" prompt", false),
            ("PreToolUse",       "\"\(node)\" \"\(dir)/update.js\" pre", true),
            ("PostToolUse",      "\"\(node)\" \"\(dir)/update.js\" post", true),
            // Qwen splits the failure paths into their own events; without them
            // a turn that errors out keeps animating as if it were still working.
            ("PostToolUseFailure", "\"\(node)\" \"\(dir)/update.js\" post", true),
            ("Stop",             "\"\(node)\" \"\(dir)/update.js\" stop", false),
            ("StopFailure",      "\"\(node)\" \"\(dir)/update.js\" fail", false),
        ]
        for e in events {
            var rules = hooks[e.event] as? [[String: Any]] ?? []
            let entry: [String: Any] = ["type": "command", "command": e.cmd,
                                        "timeout": 5000,
                                        "env": ["AGENTBAR_AGENT": "qwen"]]
            var rule: [String: Any] = ["hooks": [entry]]
            if e.matcher { rule["matcher"] = "*" }
            rules.append(rule)
            hooks[e.event] = rules
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try writeIfChanged(data, to: cfgURL)
        note("qwen")
    }

    // MARK: - GitHub Copilot CLI (~/.copilot/hooks/agentbar.json)

    /// Copilot CLI hooks come in two spellings, and the PascalCase one delivers the
    /// VS Code/Claude payload shape (`session_id`, `tool_name`, Claude tool names) —
    /// so the claude/ scripts serve it unchanged, with AGENTBAR_AGENT naming the rows.
    ///
    /// `exec` + `args` rather than a `bash` line, for a reason that matters: a shell
    /// wrapper would make the hook's parent a shell that exits immediately, and
    /// `pid: process.ppid` is the liveness handle the app prunes sessions by — every
    /// row would vanish on the next refresh.
    ///
    /// `permissionRequest` blocks and decides, which is what remote Allow/Deny needs.
    /// It was left unwired until its input payload had been logged off a real
    /// session rather than taken on faith — see `Scripts/hooks/copilot/README.md`.
    /// Not `preToolUse`: those are fail-*closed* on a crash, so one unhandled
    /// exception in a status bridge would silently deny a user's tool call.
    ///
    /// AgentBar owns the whole file: Copilot loads every `*.json` in the hooks dir,
    /// so our entries live in ours and the user's live in theirs.
    private static func installCopilot() throws {
        guard let node = nodePath else { NSLog("AgentBar: node not found, Copilot hooks skipped"); return }
        // COPILOT_HOME wins when set, exactly as the CLI resolves it.
        let copilotDir = ProcessInfo.processInfo.environment["COPILOT_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? home.appendingPathComponent(".copilot")
        guard FileManager.default.fileExists(atPath: copilotDir.path) else { return } // not a Copilot user
        let hooksFileDir = copilotDir.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksFileDir, withIntermediateDirectories: true)
        let dir = hooksDir.appendingPathComponent("claude").path

        let events: [(event: String, script: String, arg: String?)] = [
            ("SessionStart",       "lifecycle.js", "start"),
            ("SessionEnd",         "lifecycle.js", "end"),
            ("UserPromptSubmit",   "update.js", "prompt"),
            ("PreToolUse",         "update.js", "pre"),
            ("PostToolUse",        "update.js", "post"),
            // A failed tool call is still mid-turn: keep the session working.
            ("PostToolUseFailure", "update.js", "post"),
            ("Stop",               "update.js", "stop"),
            // Only Copilot reports errors as their own event; update.js reads the
            // payload's `recoverable` so a retry doesn't end the turn early.
            ("ErrorOccurred",      "update.js", "fail"),
        ]
        var hooks: [String: Any] = [:]
        for e in events {
            var args = ["\(dir)/\(e.script)"]
            if let arg = e.arg { args.append(arg) }
            hooks[e.event] = [["type": "command", "exec": node, "args": args,
                               "timeoutSec": 5, "env": ["AGENTBAR_AGENT": "copilot"]]]
        }
        // The blocking one. Its timeout must sit ABOVE the hook's own wait (600s,
        // `AGENTBAR_APPROVAL_TIMEOUT` in permission.js) so the hook is the thing that
        // gives up first and exits silently into the terminal prompt — the other way
        // round, Copilot would kill it mid-wait. Claude's entry uses 630 for exactly
        // the same reason. Copilot's own timeouts fail open (1.0.67+), so even that
        // lands on the terminal prompt rather than a denial.
        hooks["permissionRequest"] = [["type": "command", "exec": node,
                                       "args": ["\(dir)/permission.js"],
                                       "timeoutSec": 630,
                                       "env": ["AGENTBAR_AGENT": "copilot"]]]
        let root: [String: Any] = ["version": 1, "hooks": hooks]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try writeIfChanged(data, to: hooksFileDir.appendingPathComponent("agentbar.json"))
        note("copilot")
    }

    // MARK: - OpenCode (~/.config/opencode/plugins/agentbar.js)

    /// OpenCode loads JS plugins from its config dir; ours observes the event bus
    /// and mirrors it into state files. The copy refreshes with the app version.
    private static func installOpenCode() throws {
        let configDir = home.appendingPathComponent(".config/opencode")
        guard FileManager.default.fileExists(atPath: configDir.path) else { return } // not an OpenCode user
        let pluginsDir = configDir.appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        let src = hooksDir.appendingPathComponent("opencode/agentbar.js")
        let dest = pluginsDir.appendingPathComponent("agentbar.js")
        let data = try Data(contentsOf: src)
        try writeIfChanged(data, to: dest)
        note("opencode")
    }

    // MARK: - Gemini CLI (~/.gemini/settings.json)

    private static func installGemini() throws {
        guard let node = nodePath else { NSLog("AgentBar: node not found, Gemini hooks skipped"); return }
        let geminiDir = home.appendingPathComponent(".gemini")
        guard FileManager.default.fileExists(atPath: geminiDir.path) else { return } // not a Gemini user
        let cfgURL = geminiDir.appendingPathComponent("settings.json")
        let script = hooksDir.appendingPathComponent("gemini/gemini.js").path
        let command = "\"\(node)\" \"\(script)\""

        guard var root = readConfig(at: cfgURL) else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let marker = "/.agentbar/hooks/gemini/"

        // Gemini groups hooks as [{ hooks: [{type:"command", command}] }].
        func ours(_ group: [String: Any]) -> Bool {
            ((group["hooks"] as? [[String: Any]]) ?? []).contains {
                ($0["command"] as? String)?.contains(marker) == true
            }
        }
        // timeout is in milliseconds (Gemini docs; default 60000) → 5s.
        // BeforeAgent gives "thinking" at turn start, so a no-tool turn still shows life.
        for event in ["SessionStart", "SessionEnd", "BeforeAgent", "BeforeTool",
                      "AfterTool", "AfterAgent"] {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !ours($0) }
            groups.append(["hooks": [["type": "command", "command": command, "timeout": 5000]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try writeIfChanged(data, to: cfgURL)
        note("gemini")
    }
}
