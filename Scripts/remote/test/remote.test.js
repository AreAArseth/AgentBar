// The remote collector (docs/remote-protocol.md), driven the way its host drives
// it: real hook scripts write rows, the real collector reads them as a child
// process, one temp HOME per test. Two "machines" sharing a home are two
// machine-id files handed to the same scripts. The writers' side of shared homes
// is Scripts/test/shared-home.test.js.
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const ROOT = path.join(__dirname, "..", "..");
const HOOKS = path.join(ROOT, "hooks");
const STREAM = path.join(ROOT, "remote", "stream.js");
const CLI = path.join(ROOT, "cli", "agentbar");
const owner = require(path.join(HOOKS, "shared", "owner.js"));
const P = require(path.join(ROOT, "remote", "protocol.js"));
const { collect } = require(STREAM);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function home() {
  const h = fs.mkdtempSync(path.join(os.tmpdir(), "agentbar-remote-"));
  fs.mkdirSync(path.join(h, ".agentbar", "state.d"), { recursive: true });
  return h;
}
const stateDir = (h) => path.join(h, ".agentbar", "state.d");
const files = (h) => fs.readdirSync(stateDir(h)).filter((f) => f.endsWith(".json")).sort();
const rows = (h) => files(h).map((f) => JSON.parse(fs.readFileSync(path.join(stateDir(h), f), "utf8")));

// A machine is its identity files. The raw values are deliberately recognisable
// so a test can prove they never leak.
function machine(h, name, boot = "boot-1") {
  const dir = path.join(h, "machines", name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "machine-id"), `raw-machine-${name}\n`);
  fs.writeFileSync(path.join(dir, "boot-id"), `raw-boot-${name}-${boot}\n`);
  return { AGENTBAR_MACHINE_ID_FILE: path.join(dir, "machine-id"),
           AGENTBAR_BOOT_ID_FILE: path.join(dir, "boot-id") };
}
const reboot = (h, name, boot) => machine(h, name, boot);

// A fake `open` first in PATH, as every suite has: a hook told that no frontend
// is up launches AgentBar by bundle id on macOS, and a test must never start the
// real app — let alone one that then quits the copy somebody is using.
const FAKEBIN = fs.mkdtempSync(path.join(os.tmpdir(), "agentbar-fakebin-"));
fs.writeFileSync(path.join(FAKEBIN, "open"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });

function env(h, extra = {}) {
  const e = { ...process.env };
  delete e.AGENTBAR_SOURCE_ID;
  delete e.CLAUDE_CONFIG_DIR;
  return { ...e, HOME: h, AGENTBAR_FORCE_APP: "1", PATH: FAKEBIN + path.delimiter + (e.PATH || ""), ...extra };
}
function hook(h, script, args, payload, extra) {
  return cp.spawnSync(process.execPath, [path.join(HOOKS, script), ...args],
    { input: JSON.stringify(payload), env: env(h, extra), encoding: "utf8" });
}
function shareHome(h) {
  const r = cp.spawnSync(process.execPath, [CLI, "configure-cluster", "--shared-home"],
    { env: env(h), encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
}
function once(h, extra) {
  const r = cp.spawnSync(process.execPath, [STREAM, "--once"], { env: env(h, extra), encoding: "utf8" });
  return { status: r.status, stderr: r.stderr,
           frames: r.stdout.split("\n").filter(Boolean).map((l) => JSON.parse(l)) };
}
const start = (h, id, extra, cwd = "/work/project-a") =>
  hook(h, "claude/lifecycle.js", ["start"], { session_id: id, cwd, source: "startup" }, extra);
const pre = (h, id, extra, tool = "Edit") =>
  hook(h, "claude/update.js", ["pre"], { session_id: id, cwd: "/work/project-a", tool_name: tool }, extra);

// MARK: - Projection

test("a remote row carries status and nothing that only means something on the host", () => {
  const ident = { shared: false, sourceId: "00000000-0000-4000-8000-000000000001",
                  bootId: "00000000-0000-4000-8000-000000000002" };
  const r = P.project({
    agent: "claude", state: "tool", label: "Editing", project: "/work/project-a", cwd: "/work/project-a",
    pid: 4242, hookPid: 4243, prompt: "the user's words", recap: "what the agent said",
    url: "https://remote-host.example/x", entrypoint: "cli", term_program: "iTerm.app",
    started: true, started_at: 1784844700, ts: 1784844796, model: "model-a",
    activity: ["Reading", "Editing"], somethingElse: { nested: true },
  }, "session-a", ident);
  assert.deepEqual(Object.keys(r).sort(), ["activity", "agent", "id", "label", "model", "ownerBootId",
    "ownerSourceId", "project", "started", "startedAt", "state", "updatedAt"]);
  assert.equal(r.project, "project-a");
  assert.equal(r.id, "session-a");
});

test("every string is one bounded line with no control or direction characters", () => {
  const ident = { shared: false, sourceId: "s", bootId: "b" };
  const r = P.project({ agent: "claude", state: "thinking", label: "a\u0007b\nc\u202Ed" + "x".repeat(200),
                        project: "p\u0000q", model: "m".repeat(100),
                        activity: ["1", "2", "3", "4", "5", "6", "7".repeat(99)] }, "s", ident);
  assert.ok(!/[\u0000-\u001f\u202e]/.test(r.label + r.project));
  assert.equal(Array.from(r.label).length, P.LIMITS.label);
  assert.equal(r.model.length, P.LIMITS.model);
  assert.equal(r.activity.length, 5);
  assert.equal(r.activity[4].length, P.LIMITS.activityItem);
});

test("a cut never splits a surrogate pair", () => {
  const r = P.clean("😀".repeat(100), 80);
  assert.equal(Array.from(r).length, 80);
  assert.doesNotThrow(() => Buffer.from(r, "utf8").toString("utf8"));
  assert.ok(!/[\uD800-\uDBFF](?![\uDC00-\uDFFF])/.test(r));
});

test("an unknown agent, a bad state and an unusable id are not projected as something else", () => {
  const ident = { shared: false, sourceId: "s", bootId: "b" };
  assert.equal(P.project({ agent: "not-an-agent" }, "a", ident), null);
  assert.equal(P.project({ agent: "claude", state: "exploded" }, "a", ident).state, "idle");
  assert.equal(P.project({ agent: "claude" }, "///", ident), null);
});

test("a source keeps its 128 most relevant sessions, in id order", () => {
  const many = Array.from({ length: 200 }, (_, i) => ({ id: `s${String(i).padStart(3, "0")}`,
    state: i === 199 ? "permission" : "done", updatedAt: i }));
  const kept = P.select(many);
  assert.equal(kept.length, P.MAX_SESSIONS);
  assert.ok(kept.some((s) => s.id === "s199"), "the waiting session survives the cap");
  assert.deepEqual(kept.map((s) => s.id), kept.map((s) => s.id).slice().sort());
});

test("a snapshot over the frame cap is cut down and says so", () => {
  const ident = { sourceId: "s", bootId: "b" };
  const fat = Array.from({ length: 128 }, (_, i) => ({ id: `s${i}`, label: "x".repeat(4000) }));
  const line = P.snapshotLine(ident, "stream", 1, { sessions: fat, counts: {}, truncated: false });
  assert.ok(Buffer.byteLength(line) < P.MAX_FRAME_BYTES);
  const f = JSON.parse(line);
  assert.equal(f.truncated, true);
  assert.ok(f.sessions.length > 0 && f.sessions.length < 128);
});

// MARK: - Identity

test("standalone: one random source id per home, created once and kept", () => {
  const h = home();
  const a = once(h).frames[0];
  const b = once(h).frames[0];
  assert.match(a.sourceId, UUID);
  assert.equal(a.sourceId, b.sourceId);
  assert.notEqual(a.streamId, b.streamId, "every collector process is a new stream");
  assert.equal(a.stateLayout, 1);
  assert.equal(a.sharedHome, false);
  const mode = fs.statSync(path.join(h, ".agentbar", "source-id")).mode & 0o777;
  assert.equal(mode, 0o600);
});

test("an explicit AGENTBAR_SOURCE_ID wins, and a malformed one is ignored", () => {
  const h = home();
  const explicit = "00000000-0000-4000-8000-000000000004";
  assert.equal(once(h, { AGENTBAR_SOURCE_ID: explicit }).frames[0].sourceId, explicit);
  assert.notEqual(once(h, { AGENTBAR_SOURCE_ID: "host-a" }).frames[0].sourceId, "host-a");
});

test("shared: machines get distinct, stable, opaque identities from one salt", () => {
  const h = home();
  shareHome(h);
  const a = machine(h, "a"), b = machine(h, "b");
  const ha = once(h, a).frames[0], ha2 = once(h, a).frames[0], hb = once(h, b).frames[0];
  assert.equal(ha.sourceId, ha2.sourceId);
  assert.equal(ha.bootId, ha2.bootId);
  assert.notEqual(ha.sourceId, hb.sourceId);
  assert.equal(ha.stateLayout, 2);
  assert.equal(ha.sharedHome, true);
  assert.match(ha.sourceId, UUID);
  assert.match(ha.bootId, UUID);
  const out = JSON.stringify([ha, hb]);
  assert.ok(!out.includes("raw-machine") && !out.includes("raw-boot"), "raw identifiers never leave");
});

test("a reboot keeps the source and changes the boot", () => {
  const h = home();
  shareHome(h);
  const before = once(h, machine(h, "a", "boot-1")).frames[0];
  const after = once(h, reboot(h, "a", "boot-2")).frames[0];
  assert.equal(before.sourceId, after.sourceId);
  assert.notEqual(before.bootId, after.bootId);
});

test("a shared home with no machine identity writes nothing and streams nothing", () => {
  const h = home();
  shareHome(h);
  const none = { AGENTBAR_MACHINE_ID_FILE: path.join(h, "missing"), AGENTBAR_BOOT_ID_FILE: path.join(h, "missing") };
  const r = start(h, "session-a", none);
  assert.equal(r.status, 0);
  assert.equal(r.stderr, "");
  pre(h, "session-a", none);
  assert.deepEqual(files(h), []);
  const s = once(h, none);
  assert.equal(s.status, 3);
  assert.deepEqual(s.frames, []);
});

test("a cluster file nobody understands fails closed everywhere", () => {
  const h = home();
  fs.writeFileSync(path.join(h, ".agentbar", owner.CLUSTER_FILE), "{ not json");
  assert.equal(start(h, "session-a", machine(h, "a")).status, 0);
  assert.deepEqual(files(h), [], "no flat file on a disk that may be shared");
  assert.equal(once(h, machine(h, "a")).status, 4);
});

// MARK: - Shared homes

test("each collector sees both files and reports only its own", () => {
  const h = home();
  shareHome(h);
  const a = machine(h, "a"), b = machine(h, "b");
  pre(h, "session-a", a, "Edit");
  pre(h, "session-a", b, "Bash");
  const sa = once(h, a).frames, sb = once(h, b).frames;
  const [ha, snapA] = sa, [hb, snapB] = sb;
  assert.equal(snapA.sessions.length, 1);
  assert.equal(snapA.sessions[0].label, "Editing");
  assert.equal(snapA.sessions[0].ownerSourceId, ha.sourceId);
  assert.equal(snapB.sessions[0].label, "Running command");
  assert.equal(snapB.sessions[0].ownerSourceId, hb.sourceId);
  assert.deepEqual(snapA.counts, { owned: 1, foreign: 1, legacy: 0, oldBoot: 0 });
});

test("a rebooted machine cannot revive its previous boot's row, and may clear it", () => {
  const h = home();
  shareHome(h);
  pre(h, "session-a", machine(h, "a", "boot-1"));
  const after = reboot(h, "a", "boot-2");
  const snap = once(h, after).frames[1];
  assert.deepEqual(snap.sessions, []);
  assert.equal(snap.counts.oldBoot, 1);
  assert.equal(files(h).length, 1, "the collector deletes nothing");
  start(h, "session-new", { ...after, AGENTBAR_FORCE_APP: "0" });
  assert.equal(rows(h).filter((r) => r.sessionId === "session-a").length, 0,
    "the machine's own sweep takes its earlier boot's row even though the pid is alive");
});

test("legacy rows on a shared home are neither reported nor deleted", () => {
  const h = home();
  const legacy = path.join(stateDir(h), "session-old.json");
  fs.writeFileSync(legacy, JSON.stringify({ agent: "claude", state: "tool", pid: 999999, started: true,
                                            ts: Math.floor(Date.now() / 1000) }));
  shareHome(h);
  const a = machine(h, "a");
  const snap = once(h, a).frames[1];
  assert.deepEqual(snap.sessions, []);
  assert.equal(snap.counts.legacy, 1);
  start(h, "session-a", { ...a, AGENTBAR_FORCE_APP: "0" });
  cp.spawnSync(process.execPath, [CLI, "status"], { env: env(h, a), encoding: "utf8" });
  assert.ok(fs.existsSync(legacy));
  const doc = JSON.parse(cp.spawnSync(process.execPath, [CLI, "doctor", "--json"],
    { env: env(h, a), encoding: "utf8" }).stdout);
  assert.equal(doc.find((c) => c.id === "remote.cluster").status, "warn");
});

// MARK: - The stream

test("the collector reads and never writes", () => {
  const h = home();
  const dead = path.join(stateDir(h), "session-dead.json");
  fs.writeFileSync(dead, JSON.stringify({ agent: "claude", state: "tool", pid: 999999, started: true }));
  fs.writeFileSync(path.join(stateDir(h), "session-ancient.json"),
    JSON.stringify({ agent: "claude", state: "tool", started: true, ts: 1 }));
  const before = files(h).map((f) => [f, fs.statSync(path.join(stateDir(h), f)).mtimeMs]);
  const snap = once(h).frames[1];
  assert.deepEqual(snap.sessions, []);
  assert.deepEqual(files(h).map((f) => [f, fs.statSync(path.join(stateDir(h), f)).mtimeMs]), before);
});

test("snapshots are deterministic", () => {
  const h = home();
  start(h, "session-b"); pre(h, "session-b");
  start(h, "session-a"); pre(h, "session-a");
  const ident = owner.collectorIdentity(path.join(h, ".agentbar"));
  const now = Math.floor(Date.now() / 1000);
  const one = JSON.stringify(collect(stateDir(h), ident, now));
  assert.equal(one, JSON.stringify(collect(stateDir(h), ident, now)));
  assert.deepEqual(JSON.parse(one).sessions.map((s) => s.id), ["session-a", "session-b"]);
});

test("a not-yet-started session and a cloud row stay out of the stream", () => {
  const h = home();
  start(h, "session-a");
  fs.writeFileSync(path.join(stateDir(h), "cloud-cursor-1.json"), JSON.stringify({
    agent: "cursor", state: "thinking", entrypoint: "cloud", url: "https://remote-host.example",
    started: true, ts: Math.floor(Date.now() / 1000) }));
  assert.deepEqual(once(h).frames[1].sessions, []);
});

function streamProcess(h, extra = {}) {
  const c = cp.spawn(process.execPath, [STREAM, "--protocol", "2"],
    { env: env(h, { AGENTBAR_REMOTE_HEARTBEAT_MS: "300", AGENTBAR_REMOTE_RECONCILE_MS: "200", ...extra }),
      stdio: ["ignore", "pipe", "pipe"] });
  const frames = [];
  let buf = "";
  c.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) { frames.push(JSON.parse(buf.slice(0, i))); buf = buf.slice(i + 1); }
  });
  const until = async (pred, ms = 4000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) { if (pred(frames)) return true; await new Promise((r) => setTimeout(r, 20)); }
    return false;
  };
  return { c, frames, until };
}

test("hello, a full snapshot, a new snapshot on change, heartbeats when quiet", async () => {
  const h = home();
  const s = streamProcess(h);
  try {
    assert.ok(await s.until((f) => f.length >= 2));
    assert.equal(s.frames[0].type, "hello");
    assert.equal(s.frames[0].seq, 0);
    assert.equal(s.frames[1].type, "snapshot");
    assert.deepEqual(s.frames[1].sessions, []);
    pre(h, "session-a");
    assert.ok(await s.until((f) => f.some((x) => x.type === "snapshot" && x.sessions.length === 1)));
    const n = s.frames.length;
    assert.ok(await s.until((f) => f.slice(n).some((x) => x.type === "heartbeat")));
    const seqs = s.frames.map((f) => f.seq);
    assert.deepEqual(seqs, seqs.slice().sort((a, b) => a - b));
    assert.equal(new Set(seqs).size, seqs.length, "seq strictly increases");
    assert.ok(s.frames.every((f) => f.streamId === s.frames[0].streamId));
    const snaps = s.frames.filter((f) => f.type === "snapshot");
    assert.equal(snaps.length, 2, "an unchanged directory produces heartbeats, not snapshots");
  } finally { s.c.kill(); }
});

test("the collector exits when the reader goes away", async () => {
  const h = home();
  const s = streamProcess(h);
  assert.ok(await s.until((f) => f.length >= 2));
  s.c.stdout.destroy();
  const code = await new Promise((resolve) => {
    const t = setTimeout(() => resolve("still running"), 3000);
    s.c.on("exit", (c) => { clearTimeout(t); resolve(c); });
  });
  if (code === "still running") s.c.kill("SIGKILL");
  assert.equal(code, 0);
});

test("the collector exits on hangup, the way an SSH session ends", async () => {
  const h = home();
  const s = streamProcess(h);
  assert.ok(await s.until((f) => f.length >= 1));
  s.c.kill("SIGHUP");
  const code = await new Promise((resolve) => s.c.on("exit", (c, sig) => resolve(c ?? sig)));
  assert.equal(code, 0);
});

test("while the reader is stalled only the newest snapshot waits", async () => {
  const h = home();
  // Big rows, so a stalled pipe fills after a few snapshots rather than hundreds.
  const now = Math.floor(Date.now() / 1000);
  const write = (round) => {
    for (let i = 0; i < 128; i++) {
      fs.writeFileSync(path.join(stateDir(h), `s${String(i).padStart(3, "0")}.json`), JSON.stringify({
        agent: "claude", state: "tool", started: true, ts: now, pid: process.pid,
        label: `round ${round} `.padEnd(80, "x"), project: "p".repeat(80), model: "m".repeat(64),
        activity: Array.from({ length: 5 }, () => "a".repeat(40)) }));
    }
  };
  write(0);
  const c = cp.spawn(process.execPath, [STREAM], {
    env: env(h, { AGENTBAR_REMOTE_HEARTBEAT_MS: "100000", AGENTBAR_REMOTE_RECONCILE_MS: "50" }),
    stdio: ["ignore", "pipe", "pipe"] });
  c.stdout.pause();
  for (let round = 1; round <= 40; round++) {
    write(round);
    await new Promise((r) => setTimeout(r, 60));
  }
  let buf = "";
  c.stdout.on("data", (d) => (buf += d));
  c.stdout.resume();
  await new Promise((r) => setTimeout(r, 1500));
  c.kill();
  const snaps = buf.split("\n").filter(Boolean).map((l) => JSON.parse(l)).filter((f) => f.type === "snapshot");
  assert.ok(snaps.length < 41, `latest-wins coalesced ${snaps.length} snapshots`);
  assert.match(snaps[snaps.length - 1].sessions[0].label, /^round 40 /, "the newest state arrives");
});

test("an unknown protocol version is refused before anything is sent", () => {
  const r = cp.spawnSync(process.execPath, [STREAM, "--protocol", "1"], { env: env(home()), encoding: "utf8" });
  assert.equal(r.status, 2);
  assert.equal(r.stdout, "");
});
