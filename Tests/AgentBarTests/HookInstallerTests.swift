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
