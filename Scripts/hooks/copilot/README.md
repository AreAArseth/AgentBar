# GitHub Copilot CLI — live status bridge

Copilot CLI has had hooks since 0.0.396 (Jan 2026), and personal ones —
`~/.copilot/hooks/*.json`, or `$COPILOT_HOME/hooks` — since 0.0.422. Every event
AgentBar needs is there, so there is no bridge script in this directory: Copilot's
hooks are deliberately Claude-shaped, and the `claude/` scripts serve it unchanged.

Two spellings of each event exist and they select two payload dialects. The
PascalCase names (`SessionStart`, `PreToolUse`, `Stop`) deliver the VS Code/Claude
payload — `session_id`, `tool_name`, `tool_input`, and Copilot's tool ids remapped
to Claude's (`bash`→`Bash`, `view`→`Read`, `edit`→`Edit`) — which is exactly what
`claude/update.js` already reads, `TOOL_LABELS` included. `AGENTBAR_AGENT=copilot`
names the rows, the same reuse Qwen Code gets.

`HookInstaller` writes `~/.copilot/hooks/agentbar.json` and owns that whole file;
Copilot loads every `*.json` in the directory, so the user's own hooks live in
theirs and are never touched. Hook config is read once at CLI startup — a fresh
`copilot` session is needed after install.

Entries use `exec` + `args` rather than a `bash` line, and that is not cosmetic: a
shell wrapper would make the hook's parent a shell that exits immediately, and
`pid: process.ppid` is the liveness handle the app prunes dead sessions by. Every
row would disappear on the next refresh.

Wired events: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`,
`PostToolUse`, `PostToolUseFailure`, `Stop`, `ErrorOccurred`. `ErrorOccurred` is
the only one no other agent has: `update.js` reads its `recoverable` field so a
retry the CLI intends to make does not end the turn early.

## Not wired yet: remote approval

`permissionRequest` can block and answer (`{"behavior":"allow"|"deny"}`), and
Copilot's timeouts fail open since 1.0.67 — exactly the contract `permission.js`
needs. GitHub documents that output contract but not the *input* payload, so it
was logged from a real 1.0.85 session instead:

```jsonc
{
  "hookName": "permissionRequest",
  "sessionId": "3df34f6a-…",          // camelCase here, unlike every other event
  "timestamp": 1789563619837,          // ms, not the ISO string the others carry
  "cwd": "/private/tmp/…",
  "toolName": "bash",                  // the RAW id — not remapped to "Bash"
  "toolInput": { "command": "echo hello-agentbar" },
  "permissionSuggestions": []
}
```

Two things that were expected to be missing turn out not to be. There **is** a
`permissionSuggestions` field, so "Always allow" has something to pin rather than
degrading to a one-shot allow. And the id to key an answer on is `sessionId`;
there is still no `prompt_id`, so the hook's own pid stays the separator, exactly
as `permission.js` already does it.

Two traps for whoever wires it. This event alone speaks camelCase and raw tool
ids, so a handler that assumes the `snake_case` dialect of the other events will
read `undefined` throughout. And prefer `permissionRequest` over `preToolUse` for
blocking: `preToolUse` command hooks are fail-*closed* on a crash, so a single
unhandled exception would silently deny a user's tool call.

## Versions and the VS Code overlap

Minimum useful: **1.0.67** (hook timeouts fail open). Hard floor **1.0.22**, below
which `SessionStart`/`SessionEnd` fire per prompt rather than per session and the
lifecycle logic is simply wrong.

VS Code's own agent hooks (Preview) also read `~/.copilot/hooks`, convert camelCase
to PascalCase, and support neither `SessionEnd` nor `matcher`. So our file may fire
inside VS Code too, leaving rows with no end event — pid liveness pruning is what
clears those.

Docs: https://docs.github.com/en/copilot/reference/hooks-reference ·
https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
