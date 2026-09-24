#!/usr/bin/env node
// agentbar remote-stream — this machine's sessions, as a stream a Mac reads over SSH.
//
// The Mac runs `ssh <alias> <fixed command>` and reads stdout. This process reads
// `~/.agentbar/state.d/`, keeps the rows this machine owns, and writes one JSON
// frame per line: a hello naming who it is, a full snapshot, then a new full
// snapshot whenever what a status line would show changes and a heartbeat when
// nothing does. It never writes to state.d, never reads requests, answers, rules,
// history or transcripts, and has no input: nothing the Mac sends could reach it.
//
// Contract: docs/remote-protocol.md. Schema and caps: ./protocol.js.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const owner = require("../hooks/shared/owner.js");
const P = require("./protocol.js");

// Exit codes the Mac maps to a category without reading stderr.
const EXIT = { usage: 2, identity: 3, config: 4, stalled: 5 };

const alive = (pid) => {
  if (!(pid > 0)) return true; // no liveness handle: the 24h cut still applies
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; }
};

const envMs = (name, fallback) => {
  const n = Number(process.env[name]);
  return Number.isFinite(n) && n > 0 ? n : fallback;
};

// Which rows are this machine's to report, and the count of every kind it was
// not — so "the Mac shows nothing" has an answer that is not a guess.
function collect(stateDir, ident, nowSec = Math.floor(Date.now() / 1000)) {
  const counts = { owned: 0, foreign: 0, legacy: 0, oldBoot: 0 };
  const rows = [];
  let names = [];
  try { names = fs.readdirSync(stateDir); } catch {}
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    let row;
    try { row = JSON.parse(fs.readFileSync(path.join(stateDir, name), "utf8")); } catch { continue; }
    if (!row || typeof row !== "object") continue;
    const layout2 = row.stateLayout === owner.LAYOUT || typeof row.ownerSourceId === "string";
    let pid;
    if (ident.shared) {
      // Ownership first, liveness second: a pid means nothing until it is known
      // to be one this machine issued, in this boot.
      if (!layout2) { counts.legacy++; continue; }
      if (row.ownerSourceId !== ident.sourceId) { counts.foreign++; continue; }
      if (row.ownerBootId !== ident.bootId) { counts.oldBoot++; continue; }
      pid = Number(row.ownerPid) || 0;
    } else {
      // A standalone home still refuses rows some cluster node wrote: rolling a
      // cluster back must never turn its files into this machine's sessions.
      if (layout2) { counts.foreign++; continue; }
      pid = Number(row.pid) || 0;
    }
    if (!alive(pid)) continue;
    if (Number(row.ts) > 0 && nowSec - Number(row.ts) > 86400) continue;
    counts.owned++;
    if (row.started === false || row.entrypoint === "cloud") continue;
    // Same watchdog as the app and the CLI: Antigravity has no terminal event.
    if (row.agent === "antigravity" && (row.state === "thinking" || row.state === "tool")
        && Number(row.ts) > 0 && nowSec - Number(row.ts) > 90) row = { ...row, state: "done" };
    const r = P.project(row, name.slice(0, -".json".length), ident);
    if (r) rows.push(r);
  }
  const sessions = P.select(rows);
  return { sessions, counts, truncated: sessions.length < rows.length };
}

function parseArgs(argv) {
  const out = { protocol: P.VERSION, once: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--once") out.once = true;
    else if (argv[i] === "--protocol") out.protocol = Number(argv[++i]);
    else return null;
  }
  return out;
}

function main(argv, base = path.join(os.homedir(), ".agentbar")) {
  const args = parseArgs(argv);
  const fail = (code, what) => {
    try { process.stderr.write(`agentbar-remote: ${what}\n`); } catch {}
    process.exit(code);
  };
  if (!args) return fail(EXIT.usage, "usage");
  if (args.protocol !== P.VERSION) return fail(EXIT.usage, "protocol-version");
  const ident = owner.collectorIdentity(base);
  if (ident.error) return fail(ident.error === "cluster-config-invalid" ? EXIT.config : EXIT.identity,
                              ident.error);

  const stateDir = path.join(base, "state.d");
  const streamId = crypto.randomUUID();
  const heartbeatMs = envMs("AGENTBAR_REMOTE_HEARTBEAT_MS", P.HEARTBEAT_SECONDS * 1000);
  const reconcileMs = envMs("AGENTBAR_REMOTE_RECONCILE_MS", 2000);
  const stallMs = envMs("AGENTBAR_REMOTE_STALL_MS", 30000);
  let seq = 0;
  let lastBody = null;     // what the last snapshot said, seq and clock aside
  let lastSentAt = 0;
  let blockedSince = 0;
  let pending = null;      // the newest snapshot body waiting for stdout to drain

  const quit = (code = 0) => process.exit(code);
  process.stdout.on("error", () => quit(0));
  for (const sig of ["SIGHUP", "SIGINT", "SIGTERM", "SIGPIPE"]) process.on(sig, () => quit(0));

  const send = (line) => {
    lastSentAt = Date.now();
    if (!process.stdout.write(line + "\n")) {
      blockedSince = Date.now();
      process.stdout.once("drain", () => {
        blockedSince = 0;
        if (pending) { const body = pending; pending = null; sendSnapshot(body); }
      });
    }
  };
  // Status is a latest-value problem: while stdout is blocked only the newest
  // snapshot is kept, and heartbeats are simply not sent.
  const sendSnapshot = (body) => {
    if (blockedSince) { pending = body; return; }
    send(P.snapshotLine(ident, streamId, ++seq, body));
  };

  send(JSON.stringify(P.hello(ident, streamId, Math.round(heartbeatMs / 1000) || 1)));
  const first = collect(stateDir, ident);
  lastBody = JSON.stringify(first);
  sendSnapshot(first);
  if (args.once) {
    // Flush before leaving: exit() can drop a write still queued on a pipe.
    process.stdout.write("", () => quit(0));
    return;
  }

  let debounce = null;
  const reconcile = () => {
    debounce = null;
    const body = collect(stateDir, ident);
    const text = JSON.stringify(body);
    if (text === lastBody) return;
    lastBody = text;
    sendSnapshot(body);
  };
  const schedule = () => { if (!debounce) debounce = setTimeout(reconcile, 100); };

  try { fs.mkdirSync(stateDir, { recursive: true }); } catch {}
  let watcher = null;
  const watch = () => {
    try {
      watcher = fs.watch(stateDir, schedule);
      watcher.on("error", () => { try { watcher.close(); } catch {} watcher = null; });
    } catch { watcher = null; }
  };
  watch();
  // A watch misses events on network filesystems — the shared homes this exists
  // for — so the directory is also read on a clock, and the watch re-armed.
  setInterval(() => {
    if (!watcher) watch();
    schedule();
    // Orphaned: the SSH session that started us is gone.
    if (process.ppid === 1) quit(0);
    if (blockedSince && Date.now() - blockedSince > stallMs) quit(EXIT.stalled);
  }, reconcileMs);
  setInterval(() => {
    if (!blockedSince && Date.now() - lastSentAt >= heartbeatMs - 50)
      send(JSON.stringify(P.heartbeat(ident, streamId, ++seq)));
  }, Math.max(50, Math.floor(heartbeatMs / 2)));
}

module.exports = { collect, main, EXIT };

if (require.main === module) main(process.argv.slice(2));
