import Foundation
import Testing
@testable import AgentBar

/// The two silent failures that motivated `agentbar doctor`, both of which came
/// down to a node path written into a config that outlives the next node upgrade.
/// Neither had a test, and neither announced itself when it broke — the rows just
/// stopped appearing.
@Suite struct HookInstallerTests {
    private static let script = "/Users/x/.agentbar/hooks/codex/notify.js"

    // MARK: - Codex: a moved interpreter has to be repaired, not preserved

    /// The regression. A config that is already ours but names a node that no longer
    /// exists must be rewritten; the old code returned at the marker and left it.
    // MARK: - The hooks block, which is the real Codex integration

    /// Codex speaks Claude's hook dialect, so the whole integration is one block of
    /// TOML pointing at the shared scripts. These assert the two promises the notify
    /// line already keeps: everything outside survives byte for byte, and a second
    /// copy is never appended.
    @Test func codexHooksBlockCarriesEveryEventAndItsOwnTimeout() {
        let plan = HookInstaller.codexHooksPlan(config: "model = \"o3\"\n",
                                                node: "/opt/homebrew/bin/node", dir: "/h")
        guard case .write(let next, let replaced) = plan else {
            Issue.record("a fresh config must produce a write, got \(plan)"); return
        }
        #expect(!replaced)
        #expect(next.hasPrefix("model = \"o3\"\n"))
        for e in HookInstaller.codexEvents {
            #expect(next.contains("[[hooks.\(e.event)]]"))
        }
        // The blocking one outlasts permission.js's own 600s wait, so the hook gives
        // up first and falls through to Codex's prompt rather than being killed.
        #expect(next.contains("command = \"\\\"/opt/homebrew/bin/node\\\" \\\"/h/codex/hook.js\\\" permission.js\"\ntimeout = 630"))
        // Codex clamps SessionEnd to 3s; asking for more earns a warning every session.
        #expect(next.contains("\"/h/codex/hook.js\\\" lifecycle.js end\"\ntimeout = 3"))
        #expect(next.contains("statusMessage = \"Waiting for you in AgentBar\""))
    }

    @Test func codexHooksBlockIsIdempotent() {
        guard case .write(let once, _) = HookInstaller.codexHooksPlan(
            config: "model = \"o3\"\n", node: "/n", dir: "/h") else {
            Issue.record("expected a write"); return
        }
        #expect(HookInstaller.codexHooksPlan(config: once, node: "/n", dir: "/h") == .unchanged)
    }

    /// A node that moved rewrites the block where it stands, rather than appending a
    /// second one — the same repair the notify line gets, for the same reason.
    @Test func codexHooksBlockIsReplacedInPlaceNotAppended() {
        guard case .write(let old, _) = HookInstaller.codexHooksPlan(
            config: "model = \"o3\"\n", node: "/old/node", dir: "/h") else {
            Issue.record("expected a write"); return
        }
        let trailing = old + "\n[profiles.mine]\nmodel = \"o4\"\n"
        guard case .write(let next, let replaced) = HookInstaller.codexHooksPlan(
            config: trailing, node: "/new/node", dir: "/h") else {
            Issue.record("expected a rewrite"); return
        }
        #expect(replaced)
        #expect(!next.contains("/old/node"))
        #expect(next.components(separatedBy: HookInstaller.codexBegin).count - 1 == 1)
        // Everything the user put after our block is still there, untouched.
        #expect(next.hasSuffix("[profiles.mine]\nmodel = \"o4\"\n"))
        #expect(next.hasPrefix("model = \"o3\"\n"))
    }

    /// The trap this release had to fix first: the marker check used to match the path
    /// anywhere in the file, so once the hooks block existed — which carries the same
    /// path — a config with no `notify` key was read as "already wired" and notify was
    /// never installed at all.
    @Test func theHooksBlockDoesNotHideAMissingNotify() {
        guard case .write(let withHooks, _) = HookInstaller.codexHooksPlan(
            config: "model = \"o3\"\n", node: "/n", dir: "/h") else {
            Issue.record("expected a write"); return
        }
        #expect(withHooks.contains("/.agentbar/hooks/codex/") == false)   // dir is /h here
        let real = withHooks.replacingOccurrences(of: "/h/codex/", with: "/u/.agentbar/hooks/codex/")
        let plan = HookInstaller.codexPlan(config: real, node: "/n",
                                           script: "/u/.agentbar/hooks/codex/notify.js",
                                           isExecutable: { _ in true })
        guard case .write(let next, let repaired) = plan else {
            Issue.record("notify must still be installed beside the hooks block, got \(plan)")
            return
        }
        #expect(!repaired)
        #expect(next.contains("notify = [\"/n\", \"/u/.agentbar/hooks/codex/notify.js\"]"))
    }

    @Test func codexRepairsAnInterpreterThatHasMoved() {
        let stale = "model = \"o3\"\nnotify = [\"/Users/x/.nvm/versions/node/v20.11.0/bin/node\", \"\(Self.script)\"]\n"
        let plan = HookInstaller.codexPlan(config: stale, node: "/opt/homebrew/bin/node",
                                           script: Self.script, isExecutable: { _ in false })
        guard case .write(let next, let repaired) = plan else {
            Issue.record("a dead interpreter must produce a write, got \(plan)"); return
        }
        #expect(repaired)
        #expect(next.contains("notify = [\"/opt/homebrew/bin/node\""))
        #expect(!next.contains("v20.11.0"))
        // Codex accepts exactly one notify key, and the rest of the file is the
        // user's — repairing must not append or disturb anything.
        #expect(next.components(separatedBy: "notify = [").count - 1 == 1)
        #expect(next.hasPrefix("model = \"o3\"\n"))
    }

    /// The other half: a working interpreter must not be rewritten on every launch,
    /// or `install-hooks` stops being idempotent and churns the user's config.
    @Test func codexLeavesAWorkingInterpreterAlone() {
        let fine = "notify = [\"/opt/homebrew/bin/node\", \"\(Self.script)\"]\n"
        #expect(HookInstaller.codexPlan(config: fine, node: "/usr/local/bin/node",
                                        script: Self.script, isExecutable: { _ in true }) == .unchanged)
    }

    @Test func codexAppendsToAConfigThatHasNoNotifyYet() {
        let plan = HookInstaller.codexPlan(config: "model = \"o3\"", node: "/opt/homebrew/bin/node",
                                           script: Self.script, isExecutable: { _ in true })
        guard case .write(let next, let repaired) = plan else {
            Issue.record("a fresh config must be written, got \(plan)"); return
        }
        #expect(!repaired)
        // The file had no trailing newline; appending to it must not join two keys.
        #expect(next == "model = \"o3\"\nnotify = [\"/opt/homebrew/bin/node\", \"\(Self.script)\"]\n")
    }

    /// Someone else's notify hook stays theirs even when ours is dead — a status
    /// bridge must never take a key the user pointed somewhere on purpose.
    @Test func codexRefusesToTakeOverAForeignNotify() {
        #expect(HookInstaller.codexPlan(config: "notify = [\"/usr/bin/say\", \"done\"]\n",
                                        node: "/opt/homebrew/bin/node", script: Self.script,
                                        isExecutable: { _ in false }) == .foreignNotify)
    }

    /// Our marker in a shape the line pattern can't read (a comment, hand-edited
    /// formatting) must fall through to "leave it", never to "append a second key".
    @Test func codexDoesNotAppendWhenTheMarkerIsThereInAnUnreadableShape() {
        let odd = "# wired by agentbar: /Users/x/.agentbar/hooks/codex/notify.js\n"
        #expect(HookInstaller.codexPlan(config: odd, node: "/opt/homebrew/bin/node",
                                        script: Self.script, isExecutable: { _ in false }) == .unchanged)
    }

    // MARK: - Codex: notify has to land where TOML reads it as top-level

    /// The shape that broke a real config: the user's own `notify` on line 4, a file
    /// ending in a string table, and every release up to 1.30.0 appending its line
    /// under that table, where Codex refuses the whole file ("invalid type: sequence,
    /// expected a string").
    private static let userConfig = """
        model = "gpt-5"
        model_reasoning_effort = "high"
        approvals_reviewer = "guardian_subagent"
        notify = ["/Users/x/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient", "turn-ended"]
        service_tier = "default"

        [projects."/Users/x"]
        trust_level = "trusted"

        [mcp_servers.node_repl]
        command = "node"
        args = ["repl.js"]

        [mcp_servers.node_repl.env]
        NODE_OPTIONS = ""

        [features]
        js_repl = false

        [shell_environment_policy.set]
        NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S = "8e86beb8"

        """
    private static let hooksDir = "/Users/x/.agentbar/hooks"
    private static let oursLine = "notify = [\"/opt/homebrew/bin/node\", \"\(script)\"]\n"

    private static func withBlock(_ config: String) -> String {
        guard case .write(let next, _) = HookInstaller.codexHooksPlan(
            config: config, node: "/opt/homebrew/bin/node", dir: hooksDir) else { return config }
        return next
    }

    /// Both steps `installCodex` takes, in its order.
    private static func install(_ config: String) -> String {
        var text = config
        if case .write(let next, _) = HookInstaller.codexPlan(
            config: text, node: "/opt/homebrew/bin/node", script: script, isExecutable: { _ in true }) {
            text = next
        }
        if case .write(let next, _) = HookInstaller.codexHooksPlan(
            config: text, node: "/opt/homebrew/bin/node", dir: hooksDir) {
            text = next
        }
        return text
    }

    @Test func aForeignNotifyBelowLineOneIsStillForeign() {
        #expect(HookInstaller.codexPlan(config: Self.userConfig, node: "/opt/homebrew/bin/node",
                                        script: Self.script, isExecutable: { _ in true }) == .foreignNotify)
    }

    /// The exact file 1.30.0 left behind: our line under `[shell_environment_policy.set]`,
    /// the hooks block after it. The repair takes our line out and nothing else; the
    /// user's own notify on line 4 stays the one Codex runs.
    @Test func theLineAnEarlierReleaseWroteUnderATableIsTakenBackOut() {
        let healthy = Self.withBlock(Self.userConfig)
        let broken = healthy.replacingOccurrences(
            of: "NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S = \"8e86beb8\"\n",
            with: "NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S = \"8e86beb8\"\n" + Self.oursLine)
        #expect(broken != healthy)

        let plan = HookInstaller.codexPlan(config: broken, node: "/opt/homebrew/bin/node",
                                           script: Self.script, isExecutable: { _ in true })
        guard case .write(let next, let repaired) = plan else {
            Issue.record("the stray line must be removed, got \(plan)"); return
        }
        #expect(repaired)
        #expect(next == healthy)
        #expect(Self.install(broken) == healthy)
        #expect(Self.install(healthy) == healthy)
    }

    /// A CRLF file: the line ending is one `Character` in Swift, and a search for
    /// `"\n"` that misses it would take the rest of the file along with the stray line.
    @Test func theRepairTakesOneLineOutOfACRLFFile() {
        let healthy = Self.withBlock(Self.userConfig).replacingOccurrences(of: "\n", with: "\r\n")
        let broken = healthy.replacingOccurrences(
            of: "SHA256S = \"8e86beb8\"\r\n",
            with: "SHA256S = \"8e86beb8\"\r\n" + Self.oursLine.replacingOccurrences(of: "\n", with: "\r\n"))
        guard case .write(let next, true) = HookInstaller.codexPlan(
            config: broken, node: "/opt/homebrew/bin/node", script: Self.script,
            isExecutable: { _ in true }) else {
            Issue.record("expected a repair"); return
        }
        #expect(next == healthy)
    }

    /// With no notify of the user's, the stray one is moved rather than dropped.
    @Test func aStrayLineWithoutAForeignNotifyMovesToTheTopLevel() {
        let mine = Self.userConfig.replacingOccurrences(of: "notify = [\"/Users/x/.codex", with: "# was: [\"/Users/x/.codex")
        let broken = mine + Self.oursLine
        guard case .write(let next, true) = HookInstaller.codexPlan(
            config: broken, node: "/opt/homebrew/bin/node", script: Self.script,
            isExecutable: { _ in true }) else {
            Issue.record("expected a repair"); return
        }
        #expect(next.components(separatedBy: "notify = [").count - 1 == 1)
        #expect(next.contains("service_tier = \"default\"\n" + Self.oursLine + "\n[projects."))
        #expect(next.hasSuffix("SHA256S = \"8e86beb8\"\n"))
    }

    /// A first install onto a file that ends in a table: before, the line went to the
    /// end and became that table's key even with no notify anywhere.
    @Test func aFirstInstallGoesAfterTheLastTopLevelKeyNotAtTheEnd() {
        let config = "model = \"o3\"\n\n[profiles.mine]\nmodel = \"o4\"\n"
        guard case .write(let next, false) = HookInstaller.codexPlan(
            config: config, node: "/opt/homebrew/bin/node", script: Self.script,
            isExecutable: { _ in true }) else {
            Issue.record("expected a first install"); return
        }
        #expect(next == "model = \"o3\"\n" + Self.oursLine + "\n[profiles.mine]\nmodel = \"o4\"\n")
        #expect(HookInstaller.codexPlan(config: next, node: "/opt/homebrew/bin/node",
                                        script: Self.script, isExecutable: { _ in true }) == .unchanged)
    }

    @Test func aFileThatStartsWithATableGetsNotifyAboveIt() {
        let config = "# my codex config\n[profiles.mine]\nmodel = \"o4\"\n"
        guard case .write(let next, false) = HookInstaller.codexPlan(
            config: config, node: "/opt/homebrew/bin/node", script: Self.script,
            isExecutable: { _ in true }) else {
            Issue.record("expected a first install"); return
        }
        #expect(next == "# my codex config\n" + Self.oursLine + "\n[profiles.mine]\nmodel = \"o4\"\n")
    }

    /// `notify` that is not a top-level key: a comment, the inside of a multi-line
    /// string, a key of a table. None of them is the user's hook, so ours goes in,
    /// after the multi-line string rather than inside it.
    @Test func notifyThatIsNotATopLevelKeyIsNotForeign() {
        let config = """
            # notify = ["/usr/bin/say"]
            developer_instructions = \"""
            notify = ["not a key"]
            [not.a.header]
            \"""

            [tui]
            notify = true

            """
        guard case .write(let next, false) = HookInstaller.codexPlan(
            config: config, node: "/opt/homebrew/bin/node", script: Self.script,
            isExecutable: { _ in true }) else {
            Issue.record("expected a first install"); return
        }
        #expect(next.contains("[not.a.header]\n\"\"\"\n" + Self.oursLine + "\n[tui]"))
    }

    /// A nested array whose rows start with `[` is not a table header, so the notify
    /// after it is still top-level, and still the user's.
    @Test(arguments: [
        "model = \"o3\"\nmatrix = [\n  [\"a\", \"b\"],\n]\nnotify = [\"/usr/bin/say\"]\n[t]\nk = 1\n",
        "model = \"o3\"\n\"notify\" = [\"/usr/bin/say\"]\n[t]\n",
        "model = \"o3\"\n  notify=[\"/usr/bin/say\"] # mine\n",
    ])
    func aTopLevelNotifyInAnyShapeIsForeign(_ config: String) {
        #expect(HookInstaller.codexPlan(config: config, node: "/opt/homebrew/bin/node",
                                        script: Self.script, isExecutable: { _ in true }) == .foreignNotify)
    }

    /// TOML reads all of these as `notify` or as something under it; adding ours
    /// beside any of them is a duplicate key and Codex refuses the file.
    @Test(arguments: [
        "model = \"o3\"\n\"\\u006eotify\" = [\"/usr/bin/say\"]\n[t]\n",
        "model = \"o3\"\n\"not\\x69fy\" = [\"/usr/bin/say\"]\n",
        "model = \"o3\"\nnotify.command = \"/usr/bin/say\"\n",
        "model = \"o3\"\n\n[notify]\ncommand = \"/usr/bin/say\"\n",
        "model = \"o3\"\n\"\\q\" = 1\n",
    ])
    func aKeyThatIsOrMightBeNotifyMakesAgentBarStandDown(_ config: String) {
        #expect(HookInstaller.codexPlan(config: config, node: "/opt/homebrew/bin/node",
                                        script: Self.script, isExecutable: { _ in true }) == .foreignNotify)
    }

    /// A file that ends inside an unterminated value: every position in it is a guess,
    /// and the first "top-level" line after the opening `"""` is string content.
    @Test(arguments: [
        "model = \"o3\"\ninstructions = \"\"\"\nnever closed\n",
        "model = \"o3\"\nargs = [\n  \"a\",\n",
    ])
    func aFileThatEndsInsideAValueIsLeftAlone(_ config: String) {
        #expect(HookInstaller.codexPlan(config: config, node: "/opt/homebrew/bin/node",
                                        script: Self.script, isExecutable: { _ in true }) == .unchanged)
        #expect(HookInstaller.codexHooksPlan(config: config, node: "/opt/homebrew/bin/node",
                                             dir: Self.hooksDir) == .unchanged)
    }

    /// The hand workaround for the broken file, our stray line commented out, keeps
    /// AgentBar standing down: deleting it would have had the old installer write it
    /// back, so this is what a user's config may look like when the fix arrives.
    @Test func theCommentedOutWorkaroundIsLeftAlone() {
        let config = Self.withBlock(Self.userConfig + "# " + Self.oursLine)
        #expect(HookInstaller.codexPlan(config: config, node: "/opt/homebrew/bin/node",
                                        script: Self.script, isExecutable: { _ in true }) == .unchanged)
        #expect(Self.install(config) == config)
    }

    // MARK: - Codex: a human's trust survives the next launch

    /// Where Codex's own writer (`config/batchWrite`, codex-cli 0.156.1) put the trust
    /// a human gave: at the end of the document, ahead of its trailing comment — which
    /// is our end marker. Every launch after that replaced the block whole, the seven
    /// `trusted_hash` entries went with it, and Codex asked about "7 hooks new or
    /// changed" all over again.
    private static func trustedByCodex(_ config: String) -> String {
        let cfg = "/Users/x/.codex/config.toml"
        let state = "[hooks.state]\n\n" + ["session_start", "session_end", "user_prompt_submit",
                                            "pre_tool_use", "post_tool_use", "stop", "permission_request"]
            .map { "[hooks.state.\"\(cfg):\($0):0:0\"]\ntrusted_hash = \"sha256:\($0)\"\n\n" }.joined()
        return config.replacingOccurrences(of: HookInstaller.codexEnd, with: state + HookInstaller.codexEnd)
    }

    @Test func trustCodexWroteInsideTheBlockIsMovedOutNotDeleted() {
        let trusted = Self.trustedByCodex(Self.withBlock(Self.userConfig))
        #expect(trusted.components(separatedBy: "trusted_hash").count - 1 == 7)

        guard case .write(let next, true) = HookInstaller.codexHooksPlan(
            config: trusted, node: "/opt/homebrew/bin/node", dir: Self.hooksDir) else {
            Issue.record("the block must be rewritten without the foreign tables"); return
        }
        #expect(next.components(separatedBy: "trusted_hash").count - 1 == 7)
        guard let end = next.range(of: HookInstaller.codexEnd),
              let state = next.range(of: "[hooks.state]") else {
            Issue.record("marker or state missing"); return
        }
        #expect(state.lowerBound > end.upperBound)
        #expect(next.hasPrefix(Self.withBlock(Self.userConfig).trimmingCharacters(in: .newlines)))
        #expect(HookInstaller.codexHooksPlan(config: next, node: "/opt/homebrew/bin/node",
                                             dir: Self.hooksDir) == .unchanged)
        #expect(Self.install(next) == next)
    }

    /// A real rewrite (node moved) keeps the trust too. Codex will call the hooks
    /// changed, because they are, but that is Codex's question, not our deletion.
    @Test func aRewrittenBlockKeepsTheTrustBesideIt() {
        let trusted = Self.trustedByCodex(Self.withBlock(Self.userConfig))
        guard case .write(let next, true) = HookInstaller.codexHooksPlan(
            config: trusted, node: "/usr/local/bin/node", dir: Self.hooksDir) else {
            Issue.record("expected a rewrite"); return
        }
        #expect(next.contains("\\\"/usr/local/bin/node\\\""))
        #expect(!next.contains("\\\"/opt/homebrew/bin/node\\\""))
        #expect(next.components(separatedBy: "trusted_hash").count - 1 == 7)
        #expect(next.components(separatedBy: HookInstaller.codexBegin).count - 1 == 1)
    }

    @Test func onlyTablesWeDidNotWriteCountAsForeign() {
        let inner = "\n[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ntype = \"command\"\r\n\n"
            + "[hooks.state.\"/c:stop:0:0\"]\ntrusted_hash = \"sha256:a\"\n\n"
            + "[[hooks.PreToolUse]]\r\n[[hooks.PreToolUse.hooks]]\ntimeout = 5\n\n"
            + "[profiles.mine] # the user's\nmodel = \"o4\"\n"
        #expect(HookInstaller.codexForeignTables(in: inner)
                == "[hooks.state.\"/c:stop:0:0\"]\ntrusted_hash = \"sha256:a\"\n\n[profiles.mine] # the user's\nmodel = \"o4\"")
    }

    // MARK: - firstQuoted

    @Test(arguments: [
        ("notify = [\"/usr/bin/node\", \"/x/notify.js\"]", "/usr/bin/node"),
        ("notify = [\"\", \"/x\"]", ""),
    ])
    func firstQuotedReadsTheInterpreter(_ line: String, _ want: String) {
        #expect(HookInstaller.firstQuoted(line) == want)
    }

    @Test(arguments: ["notify = []", "", "no quotes here", "\"unterminated"])
    func firstQuotedIsNilWithoutAClosedPair(_ line: String) {
        #expect(HookInstaller.firstQuoted(line) == nil)
    }

    // MARK: - Node paths

    /// A path that does not resolve comes back untouched. An nvm-only machine has no
    /// stable alias at all, and inventing one would write a path that isn't there —
    /// `agentbar doctor` reports the situation instead.
    @Test func anUnresolvablePathIsReturnedUnchanged() {
        #expect(HookInstaller.stableNodeAlias(for: "/nope/not/a/node") == "/nope/not/a/node")
    }

    /// The actual fix: a version-pinned path that names the same binary as a stable
    /// alias must come back as the alias. Built from whatever node this machine has.
    @Test func aVersionPinnedPathIsSwappedForItsStableAlias() throws {
        let fm = FileManager.default
        guard let stable = HookInstaller.stableNodePaths.first(where: { fm.isExecutableFile(atPath: $0) }),
              let real = HookInstaller.realPath(stable)
        else { return }   // no node on this machine: nothing to assert against

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-node-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Stand in for ~/.nvm/versions/node/v20.11.0/bin/node: a different path that
        // resolves to the very same interpreter.
        let pinned = dir.appendingPathComponent("node")
        try fm.createSymbolicLink(at: pinned, withDestinationURL: URL(fileURLWithPath: real))

        let resolved = HookInstaller.stableNodeAlias(for: pinned.path)
        #expect(resolved != pinned.path, "a pinned path with a stable alias must not survive")
        #expect(HookInstaller.realPath(resolved) == real)
        #expect(HookInstaller.stableNodePaths.contains(resolved))
    }
}
