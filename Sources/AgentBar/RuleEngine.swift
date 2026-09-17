import Foundation

/// Answers a permission request from a rule the human wrote, and records that it
/// did. The only code path in AgentBar that writes an answer nobody clicked.
///
/// The posture, in one line: **a rule is the person deciding in advance, so the
/// product's job is to make sure the thing it answers is the thing they pictured.**
/// A rule is keyed by the ledger's `shape` — `bash:git push` — which is coarse on
/// purpose, because arguments never repeat and are where a secret would be. Coarse
/// is fine for a denial: refusing more than you meant costs a prompt. It is not
/// fine for an approval, so every approval is checked a second time against the
/// **live command**, and `refusal(for:)` is what stands between a shape and a
/// silent yes.
///
/// Everything here degrades to the ordinary prompt. A rule that does not match, a
/// rules file that will not parse, a command that will not tokenise, a request with
/// no session: all of them mean nobody answers, and nobody answering is exactly the
/// product without rules.
final class RuleEngine {
    static let shared = RuleEngine()

    struct Verdict: Equatable {
        let behavior: String     // "allow" | "deny"
        let rule: RulesStore.Rule
    }

    /// One firing, kept in memory for this launch so a surface can say what just
    /// happened without re-reading the ledger. The ledger is the record; this is
    /// the glance.
    struct Firing: Equatable {
        let at: Date
        let ruleID: String
        let decision: String
        let display: String
    }

    private let lock = NSLock()
    /// Requests already answered, by `ApprovalRequest.identity`. `refresh()` runs on
    /// every directory event and every two seconds, and the hook needs up to 100 ms
    /// to collect its answer — without this the same rule would write the same
    /// answer repeatedly and the ledger would count one decision many times.
    private var answered: Set<String> = []
    private var firings: [Firing] = []

    /// Newest first, capped: a glance, not a log.
    var recent: [Firing] {
        lock.lock(); defer { lock.unlock() }
        return firings
    }

    /// True when this request was answered from a rule and must not be shown as
    /// pending. False for everything else, including every failure.
    func handle(_ request: ApprovalRequest, session: Session?,
                load: RulesStore.Load? = nil, now: Date = Date()) -> Bool {
        guard RulesStore.enabled else { return false }
        lock.lock()
        let seen = answered.contains(request.identity)
        lock.unlock()
        if seen { return true }

        let rules = (load ?? RulesStore.cached()).rules
        let cwd = request.cwd.isEmpty ? (session?.cwd ?? "") : request.cwd
        guard let verdict = Self.verdict(for: request, cwd: cwd, rules: rules) else { return false }
        guard AnswerWriter.write(behavior: verdict.behavior, for: request) else { return false }

        lock.lock()
        answered.insert(request.identity)
        firings.insert(Firing(at: now, ruleID: verdict.rule.id, decision: verdict.behavior,
                              display: request.display), at: 0)
        if firings.count > 20 { firings.removeLast(firings.count - 20) }
        lock.unlock()

        DecisionLedger.shared.record(verdict.behavior, request: request, session: session,
                                     via: "rule", rule: verdict.rule.id,
                                     now: now.timeIntervalSince1970)
        return true
    }

    /// Drops the memory of requests that no longer exist, so a long-running app
    /// does not accumulate identities for ever.
    func forget(keeping live: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        answered.formIntersection(live)
    }

    // MARK: - Matching

    /// Which rule, if any, speaks for this request. Pure: every input is a
    /// parameter, which is what makes the table below testable.
    static func verdict(for request: ApprovalRequest, cwd: String,
                        rules: [RulesStore.Rule]) -> Verdict? {
        let shape = DecisionLedger.shape(of: request)
        let matching = rules.filter { matches($0, shape: shape, agent: request.agentID, cwd: cwd) }
        guard !matching.isEmpty else { return nil }
        // Deny wins. A person who wrote both meant the stricter one, and this is
        // how every access list on earth resolves the same collision.
        if let deny = matching.first(where: { $0.decision == "deny" }) {
            return Verdict(behavior: "deny", rule: deny)
        }
        guard let allow = matching.first(where: { $0.isAllow }) else { return nil }
        // The second look, at the live command rather than its shape.
        guard refusal(for: request, cwd: cwd) == nil else { return nil }
        return Verdict(behavior: "allow", rule: allow)
    }

    static func matches(_ rule: RulesStore.Rule, shape: String, agent: String, cwd: String) -> Bool {
        guard rule.enabled, rule.shape == shape else { return false }
        if !rule.agent.isEmpty, rule.agent != agent { return false }
        if rule.cwd.isEmpty { return true }          // denials only; enforced at load
        // A directory inside the one that was named is still inside it — that is
        // what "in this repository" means to the person who picked it.
        return cwd == rule.cwd || cwd.hasPrefix(rule.cwd + "/")
    }

    // MARK: - What an approval will never do

    /// Why this request may not be approved by a rule, or nil when it may.
    ///
    /// Every clause here is a case where the shape is a true description of the
    /// request and still not enough to say yes. Denials never come through here:
    /// refusing more than you meant is safe, approving more than you meant is the
    /// failure this whole feature has to not have.
    static func refusal(for request: ApprovalRequest, cwd: String) -> String? {
        // A plan approval is a keystroke at a dialog, not a hook decision — the
        // hook would swallow an allow anyway (permission.js). A question is not a
        // permission at all.
        if request.isPlanRequest { return "a plan review is approved in the terminal, not by a rule" }
        if request.questions != nil { return "a question is not a permission" }
        if cwd.isEmpty { return "nobody knows which directory this ran in" }

        switch request.context {
        case .bash(let command):
            return refusalInCommand(command, cwd: cwd)
        case .diff, .write, .none:
            // Every other tool is judged by the file it names. A tool that names
            // nothing this code understands is not understood, and a rule does not
            // get to approve what it cannot read.
            guard let path = DecisionLedger.filePath(in: request.toolInputPretty) else {
                return "this tool names nothing a rule can check"
            }
            return refusalInPath(path, cwd: cwd)
        case .question, .plan:
            return "not an ordinary permission"
        }
    }

    /// Commands whose presence anywhere on the line ends the matter. Some are
    /// destructive, some reach off the machine, some can run anything at all —
    /// the common property is that no argument makes them routine.
    static let refusedCommands: Set<String> = [
        "sudo", "doas", "su", "pkexec", "run0",
        "shred", "mkfs", "dd", "truncate", "chown", "chgrp",
        "curl", "wget", "nc", "ncat", "netcat", "ngrok", "ssh", "scp", "rsync", "sftp",
        "codesign", "spctl", "xattr", "csrutil", "diskutil", "launchctl", "systemsetup",
        "security", "op", "gpg", "keychain", "defaults", "crontab", "at",
        "osascript", "open", "eval", "exec", "source",
        "kill", "killall", "pkill", "shutdown", "reboot", "halt",
    ]

    /// Flags and words that turn one of these tools into a different kind of act.
    /// Per command, not global: `-r` is a catastrophe for the remover and routine
    /// for `grep`.
    static let refusedArguments: [String: Set<String>] = [
        "rm": ["-r", "-rf", "-fr", "-R", "-f", "--recursive", "--force", "-drf"],
        "git": ["--force", "-f", "--force-with-lease", "--hard"],
        "chmod": ["777", "666", "+s", "-R", "--recursive", "a+w"],
        "mv": ["-f", "--force"],
        "cp": ["-f", "--force"],
        "npm": ["--force", "-f"],
        "brew": ["--force", "-f"],
    ]

    /// Subcommands that discard work, rewrite history, or hand out rights. A rule
    /// may still be written for `git status`; it may not cover these by accident.
    static let refusedSubcommands: [String: Set<String>] = [
        "git": ["clean", "reset", "checkout", "restore", "rm", "stash", "filter-branch",
                "update-ref", "reflog", "gc", "prune", "push", "remote", "config",
                "submodule", "worktree", "apply", "am", "rebase", "cherry-pick", "revert"],
        "gh": ["auth", "secret", "ssh-key", "repo", "release", "api"],
        "npm": ["publish", "login", "adduser", "token", "unpublish"],
        "docker": ["run", "exec", "rm", "rmi", "system", "login"],
        "kubectl": ["delete", "apply", "exec", "drain", "cordon"],
        "brew": ["uninstall", "remove", "services"],
    ]

    /// Places a rule may never reach, whatever the command. The first group is how
    /// permission itself is configured — a rule that could approve an edit to the
    /// rules, the hooks or an agent's settings would be a rule that can widen
    /// itself. The second is where credentials live.
    static let refusedPaths: [String] = [
        "/.agentbar/", "/.claude/", "/.claude-", "/.codex/", "/.copilot/", "/.cursor/",
        "/.gemini/", "/.qwen/", "/.config/opencode/", "/.git/hooks", "/.git/config",
        "/.ssh/", "/.aws/", "/.gnupg/", "/.netrc", "/.npmrc", "/.pypirc",
        "/etc/", "/dev/", "/System/", "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "authorized_keys", "id_rsa", "id_ed25519", ".pem", ".p12", ".keychain",
        "credentials", ".env",
    ]

    /// The reason a bash command may not be approved from a rule, or nil.
    static func refusalInCommand(_ command: String, cwd: String) -> String? {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return "an empty command" }

        // FIRST, and the reason the rest is safe to reason about as one command:
        // `DecisionLedger.verb` takes the shape from the FIRST command on the line,
        // so a chained line carries the shape of its head. A rule must never answer
        // for the tail it never saw.
        for marker in ["|", ";", "&", "\n", "$(", "`", ">", "<"] where line.contains(marker) {
            return "more than one command, a redirect or a substitution on one line"
        }

        var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { unquote(String($0)) }
            .filter { !$0.isEmpty }
        // A leading environment assignment is how the same command arrives wearing
        // a different hat, and an assignment in front of it is not the command the
        // rule was written for.
        if let first = words.first, first.contains("="), !first.hasPrefix("-") {
            return "an environment assignment in front of the command"
        }
        guard let head = words.first, !head.hasPrefix("-") else {
            return "a command that will not tokenise"
        }
        let name = (head as NSString).lastPathComponent
        if refusedCommands.contains(name) { return "`\(name)` is never approved by a rule" }

        words.removeFirst()
        if let bad = refusedArguments[name]?.intersection(Set(words)).sorted().first {
            return "`\(name) \(bad)` is never approved by a rule"
        }
        if let subs = refusedSubcommands[name],
           let sub = words.first(where: { !$0.hasPrefix("-") }), subs.contains(sub) {
            return "`\(name) \(sub)` is never approved by a rule"
        }
        for word in words where looksLikePath(word) {
            if let reason = refusalInPath(word, cwd: cwd) { return reason }
        }
        return nil
    }

    /// The reason a file this request names puts it out of a rule's reach, or nil.
    static func refusalInPath(_ path: String, cwd: String) -> String? {
        let full = absolute(path, in: cwd)
        for fragment in refusedPaths where full.contains(fragment) {
            return "`\(fragment)` is never approved by a rule"
        }
        guard full == cwd || full.hasPrefix(cwd + "/") else {
            return "a path outside the directory the rule names"
        }
        return nil
    }

    // MARK: - Small, dull helpers the table leans on

    /// A token worth checking as a path: anything with a separator in it, or a
    /// home-relative name. A bare word is an argument, not a place.
    static func looksLikePath(_ word: String) -> Bool {
        word.hasPrefix("/") || word.hasPrefix("~") || word.contains("/")
    }

    static func absolute(_ path: String, in cwd: String) -> String {
        var p = path
        if p.hasPrefix("~") {
            p = FileManager.default.homeDirectoryForCurrentUser.path + String(p.dropFirst())
        }
        if !p.hasPrefix("/") { p = cwd + "/" + p }
        return (p as NSString).standardizingPath
    }

    /// Quotes are how a dangerous flag arrives looking like a word. Strip them
    /// before anything is compared; a quoted flag is still that flag.
    static func unquote(_ s: String) -> String {
        String(s.filter { $0 != "\"" && $0 != "'" })
    }
}
