# Codex CLI — hooks, and the approval path

Codex CLI gained a hooks engine that is shaped like Claude Code's: the same event
names, the same snake_case stdin payload, the same `hookSpecificOutput` envelope.
So there are no Codex hook scripts here beyond one shim — the `claude/` scripts
serve it unchanged, the same reuse Qwen Code and Copilot CLI already get.

Everything below was measured against **codex-cli 0.155.0** on 18 Sep 2026, in a
throwaway `CODEX_HOME`, not taken from documentation. `codex features list` reports
`hooks  stable  true`.

## What is wired

| Event | Script | Timeout |
|---|---|---|
| `SessionStart` | `claude/lifecycle.js start` | 5 |
| `SessionEnd` | `claude/lifecycle.js end` | 3 |
| `UserPromptSubmit` | `claude/update.js prompt` | 5 |
| `PreToolUse` | `claude/update.js pre` | 5 |
| `PostToolUse` | `claude/update.js post` | 5 |
| `Stop` | `claude/update.js stop` | 5 |
| **`PermissionRequest`** | `claude/permission.js` | **630** |

Written into `~/.codex/config.toml` between `# >>> agentbar >>>` and
`# <<< agentbar <<<`, by `HookInstaller.installCodex` and the Linux CLI's
`install-hooks`. Array-of-tables rather than dotted keys, because Codex writes its
own `[hooks.state]` section and a `hooks.X = […]` dotted key would make that a
redefinition TOML refuses. Appended at the end of the file, because a bare
`key = value` written after a `[[table]]` header belongs to that table.

**Timeouts are clamped per event.** `SessionEnd`'s ceiling is 3 s — asking for 5
earns a `clamping … hook timeout` warning on every session. `PermissionRequest`
keeps 630, which is what matters: it sits above `permission.js`'s own 600 s wait,
so the hook is the thing that gives up first and exits silently into Codex's own
prompt rather than being killed mid-wait. Verified by reading the effective config
back out of Codex itself (`hooks/list` over the app server reports post-clamp
values: `sessionEnd` came back as 3 where 5 was written, `permissionRequest` as 630).

## hook.js, and why it exists

Codex's handler carries `command`, `commandWindows`, `timeout`, `async`,
`statusMessage` and `additionalContextLimit` — and **no `env`**. Two environment
variables are what tell the shared scripts who is asking, so the shim sets them and
loads the real script in the same process.

In the same process on purpose: `pid: process.ppid` is the liveness handle the
protocol prunes sessions by, and a wrapper that *spawned* the script would make its
parent this shim, which exits at once. Codex execs the command directly, with no
shell in between — measured, not assumed: a hook that printed its parent reported
`parent=codex`. Quoting is honoured too, so a path with a space in it survives
(`command = "\"/x/probe with space.sh\" alpha beta"` arrived as two arguments).

The row prefix is the second variable. Codex's `notify` bridge has named these rows
`codex-<thread-id>` since the integration existed, and `Weight.codex` finds the
session's rollout by stripping that prefix straight back off. The hooks agree with
it, which is what keeps one session one row and the token count from quietly
disappearing. `session_id` from a hook, the `thread-id` from `notify`, and the
rollout's file name are all the same uuid — checked against a live session.

## The payload

Claude's, field for field. A real `PermissionRequest`, recorded:

```json
{
  "hook_event_name": "PermissionRequest",
  "session_id": "01a0b510-01b4-7e62-a265-c26d8a314358",
  "turn_id": "01a0b510-021e-7b52-8468-845e5eb0eebc",
  "cwd": "/private/tmp/probe-repo",
  "model": "gpt-6-astra",
  "permission_mode": "default",
  "tool_name": "Bash",
  "tool_input": { "command": "printf %s ahoj > probe.txt",
                  "description": "…" },
  "transcript_path": "…/sessions/2026/09/18/rollout-….jsonl"
}
```

`tool_name` is **Claude's vocabulary, not Codex's** — `Bash`, not the `exec` the
rollout records for the same call. That is what makes `buildContext`,
`displaySummary` and `DecisionLedger.shape` work unchanged, and it is why a rule
somebody wrote for `bash:git push` covers Codex as well as Claude.

Two differences from Claude that the hook has to know about:

- **No `prompt_id`.** The request is named `<session>-<turn_id>` instead. `turn_id`
  repeats across the tools of one turn exactly the way Claude's prompt id does,
  which is what the successor guard in `permission.js` is built on.
- **No `permission_suggestions`.** There is no channel for a rule and none back, so
  `ruleSuggestion` is always `null` and every **Always** degrades to a one-shot
  allow — the Copilot rule, already normative in `docs/protocol.md`.

Output is byte-identical to Claude's, and `updatedPermissions`, `updatedInput`,
`interrupt: true`, `continue: false`, `stopReason` and `suppressOutput` all **fail
closed** on this event, which is exactly the contract `permission.js` needs:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest",
                       "decision":{"behavior":"allow","message":"…"}}}
```

## The trust gate

**Codex runs no hook until a human has accepted it.** Writing the config is not
enough: an unaccepted hook is skipped in silence, with nothing in any log. Codex
asks at the start of the next session and records the answer in the same file:

```toml
[hooks.state."/Users/me/.codex/config.toml:session_start:0:0"]
trusted_hash = "sha256:…"
```

The key is `<source path>:<event>:<group>:<index>` and the hash covers the handler,
so changing the command — a node upgrade, an AgentBar update — invalidates it and
Codex asks again.

**AgentBar never writes that entry.** It could: `hooks/list` over the app server
returns `currentHash` and `trustStatus` for every hook, which is all it would take.
An installer that signs its own blocking hook is precisely what rule 3 in
`CLAUDE.md` exists to prevent, so instead the `codex.hooks` diagnostic says the hook
is written and waiting, and the older `notify` bridge keeps reporting sessions until
the answer comes.

## What is not verified yet

Two paths could not be exercised before the account hit its usage limit, and they
are the ones that matter most, so they are named rather than assumed:

- a `deny` decision arriving back at Codex and stopping the command;
- **silence as fall-through** — a hook that writes nothing must leave Codex asking
  at its own prompt. Every one of `permission.js`'s fourteen failure paths depends
  on it.

Until both are checked against a live session, treat the approval half of this
integration as unproven.
