# What each agent will let somebody else decide

AgentBar's whole claim is that it sits in the blocking permission path across
vendors. That claim is only as good as what each vendor's hook actually lets a
third party do — so this file is the measured answer, per agent, with the version
it was measured against and how.

It exists because the question has three answers, not two, and the middle one is
easy to miss: a hook that is *called* before a tool runs is not necessarily a hook
that can *approve* it. Several can only refuse.

| | What the hook may return | Who can answer for you |
|---|---|---|
| **Approve** | allow **and** deny | AgentBar, from the card |
| **Veto** | deny only — allow is ignored or absent | nobody; you can only be stopped |
| **Observe** | nothing that changes the outcome | nobody |

## The table

| Agent | Measured against | Surface | Tier | Wired in AgentBar |
|---|---|---|---|---|
| Claude Code | 2.1.277 | `PermissionRequest` | **Approve** | `permission.js`, the full card |
| Codex CLI | 0.155.0 | `PermissionRequest` | **Approve** | `permission.js`, since 1.28.0 |
| Copilot CLI | 1.0.85 | `permissionRequest` | **Approve** | `permission.js` |
| Antigravity (`agy` CLI) | 2.0 | `PreToolUse` | **Approve** | status only — see below |
| Antigravity (desktop) | 2.0 | `PreToolUse` | Observe | status + keystroke approval |
| Cursor | 2026.01.23 | `beforeShellExecution`, `preToolUse`, `beforeMCPExecution`, `beforeReadFile` | **Veto** | status only |
| Gemini CLI | 0.50.0 | `BeforeTool` | **Veto** | status only |
| Qwen Code | — | `PermissionRequest`, unverified | unknown | status only |
| OpenCode | plugin API | event bus | Observe | status only |
| Cursor cloud, Devin, Codex cloud | — | no local hook at all | Observe | the cloud poller |

## The measurements

**Claude Code, Copilot CLI, Codex CLI — the queue.** All three take
`{"behavior":"allow"|"deny"}` from a blocking hook, and all three treat silence as
"nobody decided" and fall back to their own prompt. That is the contract the whole
product rests on; it is written out clause by clause in `SECURITY.md`. Copilot's
payload was logged off a real 1.0.85 session, Codex's off a real 0.155.0 session —
both are in the READMEs beside their hooks, with the deny and the fall-through
each demonstrated rather than inferred.

**Cursor — veto only.** `cursor-agent` validates a hook's answer against
`["allow","deny","ask"]` and then, at every call site that consumes one, compares
against `"deny"` and nothing else:

```js
const a = await s.executeHookForStep(beforeShellExecution, {…});
if ("deny" === a?.permission) { throw new _(w("Command execution", a.user_message)); }
```

`preToolUse`, `beforeMCPExecution` and `beforeReadFile` are the same shape.
`"allow"` passes the validator and changes nothing: the call proceeds into Cursor's
own confirmation exactly as if the hook had said nothing. So a hook can stop
Cursor. It cannot answer for you.

*Read from `index.js` of 2026.01.23-916f423, not run.*

**Gemini CLI — veto only, and it is explicit about it.** `BeforeTool` gets Claude's
payload almost field for field (`session_id`, `cwd`, `hook_event_name`,
`tool_name`, `tool_input`, `transcript_path`) — there is even a
`gemini hooks migrate` that ports Claude Code's hooks across. The decision it
accepts is `block`, `deny` or `ask`:

```js
isBlockingDecision() { return this.decision === "block" || this.decision === "deny"; }
isAskDecision()      { return this.decision === "ask"; }
```

`ask` forces `PolicyDecision.ASK_USER` — it can *escalate* to asking you, which is
the opposite of approving. There is no `allow`. And a hook that writes nothing
returns `{status:"continue"}`, so silence falls through to Gemini's own policy and
prompt, the same invariant every other agent honours.

*Read from the 0.50.0 bundle, not run: this machine's account gets
`IneligibleTierError: This client is no longer supported for Gemini Code Assist for
individuals` before a session can start, which is its own finding.*

**Antigravity — approve-capable in the CLI, and fail-closed.** `agy` treats a
non-zero exit, a crash **and** any stdout that is not a valid decision as *deny*,
so the status bridge has to answer `{"decision":"allow"}` before it does anything
else. That is the opposite of every other agent here, and it is why the bridge
writes its allow with `fs.writeSync` before its own work — see
`Scripts/hooks/antigravity/README.md` and the three upstream issues it cites. The
desktop app ignores stdout entirely, which is why that half gets keystroke
approval instead. Wiring the CLI's `PreToolUse` to the card is
[issue #8](https://github.com/michalstrnadel/AgentBar/issues/8), and it is a real
piece of work rather than a config line: a hook that fails closed must never be
allowed to time out.

**Qwen Code — unverified, deliberately.** Its `PermissionRequest` looks Claude-
shaped and has never been logged off a real session, so it is not wired. The house
rule is in `HookInstaller.swift`: *a blocking hook must never be wired on faith.*
Same standard Codex had to meet before 1.28.0 wired it.

## Why a veto is not wired to the card

A veto-only agent could be given a blocking hook that shows the AgentBar card and
refuses what the card refuses. It is not wired, and the reason is worth stating
because it will come up again: **Allow would be a lie.** You would press it, the
hook would answer `allow`, the agent would discard that answer and ask you again in
its own terminal. One of the two prompts would be theatre, and there is no way to
tell from the card which one.

What a veto *could* honestly carry is the deny half of the rules you wrote —
"never `git push --force`, in any repository, from any agent" enforced on Cursor
and Gemini too, with no card and no waiting. That is a real feature and a different
one: it needs the rules engine to answer without the app being the thing that
answers, and `DecisionLedger.shape` lives in Swift while the hook is JavaScript.
It is written down here rather than built, because building it means a second
implementation of the shape vocabulary, and a second one is a second thing to keep
in sync.

## Keeping this file honest

Every row names a version because all of this moves: Codex went 0.153 → 0.155
during one working session, and its hooks engine is stable-flagged but young.
A row measured by reading a bundle says so; a row measured by running a session
says that too. When an agent's tier changes — Gemini's did, mid-probe — the row
records what happened rather than what the documentation says should have.
