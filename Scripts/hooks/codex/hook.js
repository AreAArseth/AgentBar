#!/usr/bin/env node
// Codex CLI -> the shared claude/ hook scripts.
//
// Codex speaks Claude's hook dialect: the same event names, the same snake_case
// stdin payload, the same `hookSpecificOutput` envelope. So the scripts in
// ../claude serve it unchanged, the way they already serve Qwen Code and Copilot
// CLI. What Codex does NOT have is a way to set environment variables on a hook
// — its handler carries `command`, `timeout`, `async`, `statusMessage` and
// nothing else — and two variables are what tell those scripts who is asking.
//
// Hence this shim. It sets them and loads the real script **in this same
// process**, rather than spawning one, because `process.ppid` is the liveness
// handle the whole protocol prunes sessions by: a wrapper that spawned a child
// would make the child's parent this shim, which exits immediately, and every
// Codex row would vanish on the next refresh. Codex execs the command directly
// with no shell in between, so `process.ppid` here is the codex process itself.
//
// Wired as:  "<node>" "<hooks>/codex/hook.js" <script.js> [verb]
"use strict";

const path = require("path");

process.env.AGENTBAR_AGENT = "codex";
// Codex's own notify bridge has named these rows `codex-<thread-id>` since the
// integration existed, and `Weight.codex` finds the session's rollout by
// stripping that prefix back off. Agreeing with it is what keeps one session one
// row, and what keeps the token count from quietly disappearing.
process.env.AGENTBAR_ID_PREFIX = "codex-";

const [script, ...rest] = process.argv.slice(2);
if (!script || script.includes("/") || script.includes("\\") || !script.endsWith(".js")) {
  // A hook that cannot tell what to run must do nothing at all: for
  // PermissionRequest, silence is what falls through to Codex's own prompt.
  process.exit(0);
}

const target = path.join(__dirname, "..", "claude", script);
// The scripts read their verb from argv[2], the way their host passes it.
process.argv = [process.argv[0], target, ...rest];
try {
  require(target);
} catch (e) {
  try { process.stderr.write("[agentbar] codex hook " + script + ": " + e.message + "\n"); } catch {}
  process.exit(0);
}
