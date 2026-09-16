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

## Remote approval, wired

`permissionRequest` blocks and decides, and Copilot's hook timeouts fail open
since 1.0.67 — exactly the contract `permission.js` needs, and exactly what rule 3
in `CLAUDE.md` demands of it. `HookInstaller` wires it to
`claude/permission.js` with `timeoutSec: 630`, above the hook's own 600 s wait, so
the hook is the thing that gives up first and exits silently into the terminal
prompt rather than being killed mid-wait.

GitHub documents the output contract but not the *input* payload, so it was logged
from a real 1.0.85 session instead:

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

`hookName` is the only field that tells the dialects apart — Claude's payload has
no such key — so `permission.js` keys off it, normalises the payload into the
snake_case shape the rest of the file reads, and writes the decision **bare**
(`{"behavior":"allow"}`) instead of wrapped in Claude's `hookSpecificOutput`.
Everything in between — the request file, the wait, the successor guards, the
silent exit on every failure path — is shared code.

Round-tripped against a live CLI 1.0.85 on 2026-09-16: allow from AgentBar and the
command runs; deny and Copilot reports *"Permission denied by a PermissionRequest
hook"* and does not run it; with AgentBar not running no request file is written at
all and the hook exits at once, so the session falls through to Copilot's own
handling instead of waiting on a frontend that cannot answer.

### Two traps, and one correction

**camelCase and raw tool ids.** This event alone uses `sessionId`/`toolName`/
`toolInput` while every other Copilot event arrives in the snake_case Claude
dialect with tool ids already remapped. A handler that assumes one shape reads
`undefined` throughout.

Only `bash` is remapped to a Claude tool name, because it is the only one whose
*input* shape has been observed. Renaming `view` to `Read` would send the display
looking for a `file_path` that may not be there and render "Read: " with nothing
after it — worse than showing the id Copilot actually used. Unmapped ids keep
their own name and borrow the first string in the input for the display.

**Use `permissionRequest`, not `preToolUse`.** `preToolUse` command hooks are
fail-*closed* on a crash, so one unhandled exception in a status bridge would
silently deny a user's tool call.

**There is no "Always allow" for Copilot, and `permissionSuggestions` is not the
reason.** An earlier note here said the field gives Always something to pin. That
was the wrong conclusion from the right observation: the field exists, but the
*output* contract GitHub documents is `{behavior, message, interrupt}` — there is
no channel for a standing rule at all, so a rule has nowhere to go regardless of
what `permissionSuggestions` contains. `permission.js` therefore drops it, which
makes every "always" degrade to a one-shot allow, and both surfaces already hide
the Always button when a request carries no rule.

The id to key an answer on is `sessionId`; there is still no `prompt_id`, so the
hook's own pid stays the separator between two requests in one turn, exactly as
`permission.js` already does it.

Keystroke approval stays as the fallback (`Agents.swift`, `approveKeys: [16, 36]`):
a session started before the hook was installed, or one running inside VS Code,
produces no request file, and the menu falls back to keystrokes for those.

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
