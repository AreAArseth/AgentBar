# agentbar-cloud

External poller that mirrors **cloud** coding-agent runs into the AgentBar menu
bar: Cursor cloud agents, Devin sessions, and Codex cloud tasks become protocol
rows in `~/.agentbar/state.d/` (`entrypoint: "cloud"`, a `url`, this poller's
pid). Clicking a row opens the run where it lives — cursor.com / app.devin.ai /
chatgpt.com. No changes to the app beyond the protocol's optional `url` field.

## Setup

```bash
./Scripts/cloud/install.sh        # writes a starter ~/.agentbar/cloud.json + launchd agent
./Scripts/cloud/install.sh uninstall
```

Config `~/.agentbar/cloud.json` (chmod 600 — it holds API keys):

```jsonc
{
  "pollSeconds": 30,
  "retentionMinutes": { "done": 60, "error": 240 }, // how long finished/failed rows linger
  "syntheticErrorRow": true,   // one clickable "<vendor>: auth failed" row on persistent failure
  "cursor": { "enabled": true, "apiKey": "…",  // cursor.com/dashboard -> API Keys
              "openIn": "app",                 // cursor:// run deep link; "web" = cursor.com/agents/<id>
              "apiVersion": "v1" },            // "v0" = legacy status-on-agent endpoint
  "devin":  { "enabled": true, "apiKey": "…",  // app.devin.ai Settings -> API Keys
              "orgId": "…",                    // REQUIRED for cog_ keys (service users / PATs):
                                               // they authorize only the org-scoped v3 API. Find it
                                               // under Settings -> Service Users. Legacy apk_ keys
                                               // use v1 and need no orgId — omit it there.
              "openIn": "app",                 // devin://acp/session deep link — opens the exact
                                               // thread in Devin Desktop, falling back to the web
                                               // thread when the session isn't synced into the
                                               // Agent Command Center. "web" = app.devin.ai/sessions/<id>
              "recentHours": 48, "showSuspended": false },
  "codex":  { "enabled": true },               // rides `codex login`, no key needed
  "ssh":    { "enabled": true,                 // OFF by default — your own machines
              "hosts": ["devbox", { "host": "me@gpu-box", "name": "gpu" }] }
}
```

### SSH hosts

Agents running on your own machines — a devbox, a GPU server, a Linux laptop —
show up next to the local ones. Each host needs AgentBar's hooks installed there
(`agentbar install-hooks`, the Linux CLI); the poller then reads that host's
`~/.agentbar/state.d` over `ssh` every 15 s, keeping only rows whose agent process
is still alive **there**. Rows read `gpu: my-repo`; a click opens `ssh://<host>`.

- Uses your `ssh` and `~/.ssh/config` with `BatchMode=yes`: keys or an agent, never a
  password prompt. Ports, users and jump hosts belong in `~/.ssh/config`.
- **Read-only.** A remote session waiting on permission shows *Waiting on you on
  gpu* and is answered where it runs — there is no hook on this Mac blocked behind
  it, and an Allow here would answer nothing.
- A host that is down or asleep is logged and simply shows no rows; the others
  keep working.
- Host strings are checked before they reach `ssh`'s argv — letters, digits, `.`,
  `_`, `-`, one `@`, never a leading dash.
- **Read by owner when it can be.** When the host has AgentBar's collector
  (installed by the same `agentbar install-hooks`), the poller reads that: only
  the sessions that machine owns, prompts and recaps left on it
  ([docs/remote-protocol.md](../../docs/remote-protocol.md)). A home mounted on
  several machines *needs* it — declare it with `agentbar configure-cluster
  --shared-home` and add each node as its own host; without the collector such a
  host shows nothing and the log says why.

Keys may also come from `CURSOR_API_KEY` / `DEVIN_API_KEY` in the launchd
environment instead of the file.

## Behavior

- Poll every 30 s (codex 60 s — it shells out to `codex cloud list --json`; ssh 15 s).
- After each **successful** vendor poll the vendor's rows are reconciled to the
  fresh set; a vendor that keeps failing (~5 min) gets its rows replaced by one
  clickable error row. Vendors never affect each other's rows.
- Actively working runs always show; finished/failed runs age out per
  `retentionMinutes`; blocked/suspended ones per `recentHours`.
- Rows carry the poller's pid: stop the poller and the app prunes them.

## Dev

```bash
node Scripts/cloud/index.js --once   # single poll, then exit
node --test Scripts/cloud/test/*.test.js   # pure-function tests, no network
```
