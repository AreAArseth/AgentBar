# The remote collector

What another machine tells this Mac about its sessions. The cloud poller's `ssh`
adapter (`Scripts/cloud/adapters/ssh.js`) reads each configured host over the
user's own SSH; on a host with AgentBar's collector installed, what it reads is
this: one hello and one snapshot of the sessions **that machine owns**, already
projected down to what a status line shows. The file protocol on each machine is
`docs/protocol.md`; this is the format between them.

## Why a collector

Reading `~/.agentbar/state.d` directly works for a home one machine owns. It
cannot work for a home several machines share (state layout 2 in
`docs/protocol.md`): every node's rows sit in the same folder, a pid is only
meaningful on the node that issued it, and a plain script cannot compute which
node it is running on. The collector can — it uses the same identity the hooks
stamp into each row — so it reports only its own rows and probes a pid only after
the owner matches.

## Installing and running

`agentbar install-hooks` copies the collector to `~/.agentbar/remote/` and writes
`~/.agentbar/bin/agentbar-remote`, which execs the node that ran the installer.
`agentbar remote-stream [--once]` runs the same code from a checkout, and `agentbar
doctor` reports the launcher as `remote.stream`.

The ssh adapter sends one script to `sh -s` per host per poll:

- the collector is executable → it prints a marker line and runs
  `"$HOME/.agentbar/bin/agentbar-remote" --protocol 2 --once` (stdin `/dev/null`);
- no collector, and the home declares itself shared → it prints a notice and **no
  rows** — every node's rows checked against the wrong machine's pids would be
  worse than none — and the poller logs *run `agentbar install-hooks` there*;
- no collector, standalone home → the original read: each row whose `pid` is
  alive there, skipping any row a cluster node wrote (`ownerSourceId`), so a
  rolled-back cluster's files are never read as this machine's.

The adapter believes a collector's snapshot only when it belongs to the hello's
stream and every row is owned by the machine that sent it. Everything after that
— the question-not-permission boundary, the `ssh://` click, per-host caps and the
grace for a missed poll — is the adapter's, unchanged.

## Frames

Newline-delimited JSON, UTF-8, one object per line, **at most 256 KiB per line**.
Every frame carries:

| Field | Meaning |
|---|---|
| `v` | protocol version — `2` |
| `type` | `hello`, `snapshot` or `heartbeat` |
| `sourceId` | the machine: a stable opaque UUID (see *Identity*) |
| `bootId` | the machine's current boot: an opaque UUID that changes on reboot |
| `streamId` | this collector process: a random UUID |
| `seq` | strictly increasing within one `streamId`; hello is `0` |
| `sentAt` | informational Unix seconds |

`hello` adds `heartbeatSeconds`, `stateLayout` (`1` standalone, `2` shared home)
and `sharedHome`. `snapshot` adds `sessions` (≤ 128 rows), `counts` (`owned`,
`foreign`, `legacy`, `oldBoot` — how many rows this machine reported and how many
it left alone, and why) and `truncated`. `heartbeat` adds nothing.

A session row carries exactly these keys:

| Key | Rule |
|---|---|
| `id` | `[A-Za-z0-9_.-]`, 1–64 chars — the session's id on its own machine |
| `ownerSourceId`, `ownerBootId` | equal to the frame's `sourceId` / `bootId` |
| `agent` | a known agent id (`docs/protocol.md`) |
| `state` | `idle` `thinking` `tool` `permission` `question` `done` `error` |
| `label` | ≤ 80 characters, one line |
| `project` | a basename, ≤ 80 characters |
| `started` | `true` |
| `startedAt`, `updatedAt` | optional Unix seconds |
| `model` | optional, ≤ 64 characters |
| `activity` | optional, ≤ 5 labels of ≤ 40 characters |

Strings carry no control characters and no bidirectional overrides. `pid`, `cwd`,
`url`, the terminal, **`prompt` and `recap` never leave the machine**: they mean
nothing elsewhere, or they are the user's words.

With `--once` the collector prints the hello and one snapshot and exits. Without
it, it keeps streaming: a new snapshot within ~100 ms of any change a status line
would show (a directory watch, plus a read every 2 s because watches miss events
on network filesystems) and a heartbeat every `heartbeatSeconds` otherwise; while
stdout is blocked only the newest snapshot waits. It exits when stdout closes, on
SIGHUP/SIGTERM, when orphaned, or after 30 s of a blocked pipe. Exit codes: `2`
usage or protocol version, `3` identity unavailable, `4` shared-home declaration
not understood, `5` stalled. It never writes to `state.d` and never reads requests,
answers, rules, history or transcripts.

## Identity

- **Standalone home.** `sourceId` is a random UUID created once in
  `~/.agentbar/source-id`; `bootId` is an HMAC of the kernel boot id.
- **Shared home.** `sourceId` is `AGENTBAR_SOURCE_ID` when set to a UUID,
  otherwise an HMAC of the node-local machine id (`/etc/machine-id`;
  `IOPlatformUUID` on macOS) under `~/.agentbar/identity-salt` — the same value
  the hooks stamp as `ownerSourceId`. A node with neither refuses to run (exit 3).
- Hostnames, addresses, usernames, paths and pids are never an identity, and raw
  machine or boot identifiers never leave the machine.
