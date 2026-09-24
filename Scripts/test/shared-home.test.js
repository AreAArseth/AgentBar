// Shared homes (state layout 2, docs/protocol.md): one home mounted on several
// machines, so every row must name the machine that owns it, and only that
// machine may probe its pid, prune it or delete it. Driven the way the hosts
// drive it — real hook scripts with a payload on stdin, one temp HOME per test.
// Two "machines" sharing a home are two machine-id files handed to the same
// scripts through AGENTBAR_MACHINE_ID_FILE / AGENTBAR_BOOT_ID_FILE.
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const ROOT = path.join(__dirname, "..");
const HOOKS = path.join(ROOT, "hooks");
const CLI = path.join(ROOT, "cli", "agentbar");
const OWNER = path.join(HOOKS, "shared", "owner.js");
const owner = require(OWNER);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const LAYOUT2_NAME = /^[0-9a-f]{16}-[0-9a-f]{32}\.json$/;

// A fake `open` first in PATH, as every suite has: a hook told that no frontend
// is up launches AgentBar by bundle id on macOS, and a test must never start the
// real app — let alone one that then quits the copy somebody is using.
const FAKEBIN = fs.mkdtempSync(path.join(os.tmpdir(), "agentbar-fakebin-"));
fs.writeFileSync(path.join(FAKEBIN, "open"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });

function home() {
  const h = fs.mkdtempSync(path.join(os.tmpdir(), "agentbar-shared-"));
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
function cli(h, args, extra) {
  return cp.spawnSync(process.execPath, [CLI, ...args], { env: env(h, extra), encoding: "utf8" });
}
function shareHome(h) {
  const r = cli(h, ["configure-cluster", "--shared-home"]);
  assert.equal(r.status, 0, r.stderr);
}
// Who a machine is, as the hooks see it — asked in a child, since the identity
// files are read from the environment.
function whoami(h, extra) {
  const r = cp.spawnSync(process.execPath, ["-e",
    `process.stdout.write(JSON.stringify(require(${JSON.stringify(OWNER)}).resolve(${JSON.stringify(path.join(h, ".agentbar"))})))`],
    { env: env(h, extra), encoding: "utf8" });
  return JSON.parse(r.stdout);
}
const start = (h, id, extra, cwd = "/work/project-a") =>
  hook(h, "claude/lifecycle.js", ["start"], { session_id: id, cwd, source: "startup" }, extra);
const pre = (h, id, extra, tool = "Edit") =>
  hook(h, "claude/update.js", ["pre"], { session_id: id, cwd: "/work/project-a", tool_name: tool }, extra);

// MARK: - Declaring a shared home

test("configure-cluster writes the declaration and a private salt, once", () => {
  const h = home();
  shareHome(h);
  shareHome(h);
  const base = path.join(h, ".agentbar");
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(base, owner.CLUSTER_FILE), "utf8")), { v: 1, sharedHome: true });
  assert.match(fs.readFileSync(path.join(base, owner.SALT_FILE), "utf8").trim(), /^[0-9a-f]{64}$/);
  assert.equal(fs.statSync(path.join(base, owner.SALT_FILE)).mode & 0o777, 0o600);
  assert.equal(owner.clusterMode(base), "shared");
  cli(h, ["configure-cluster", "--standalone"]);
  assert.equal(owner.clusterMode(base), "standalone");
});

test("concurrent first runs commit exactly one salt", async () => {
  const h = home();
  const code = `process.stdout.write(require(${JSON.stringify(OWNER)})` +
    `.ensureSalt(${JSON.stringify(path.join(h, ".agentbar"))}))`;
  const outs = await Promise.all(Array.from({ length: 12 }, () => new Promise((resolve) => {
    const c = cp.spawn(process.execPath, ["-e", code], { env: env(h) });
    let s = ""; c.stdout.on("data", (d) => (s += d)); c.on("close", () => resolve(s));
  })));
  assert.equal(new Set(outs).size, 1);
  assert.match(outs[0], /^[0-9a-f]{64}$/);
  assert.equal(fs.readdirSync(path.join(h, ".agentbar")).filter((f) => f.endsWith(".tmp")).length, 0);
});

// MARK: - Identity

test("machines get distinct, stable, opaque identities from one salt", () => {
  const h = home();
  shareHome(h);
  const a = machine(h, "a"), b = machine(h, "b");
  const ia = whoami(h, a), ia2 = whoami(h, a), ib = whoami(h, b);
  assert.equal(ia.shared, true);
  assert.deepEqual(ia, ia2);
  assert.notEqual(ia.sourceId, ib.sourceId);
  assert.match(ia.sourceId, UUID);
  assert.match(ia.bootId, UUID);
  const out = JSON.stringify([ia, ib]);
  assert.ok(!out.includes("raw-machine") && !out.includes("raw-boot"), "raw identifiers never leave");
});

test("a reboot keeps the source and changes the boot", () => {
  const h = home();
  shareHome(h);
  const before = whoami(h, machine(h, "a", "boot-1"));
  const after = whoami(h, machine(h, "a", "boot-2"));
  assert.equal(before.sourceId, after.sourceId);
  assert.notEqual(before.bootId, after.bootId);
});

test("an explicit AGENTBAR_SOURCE_ID wins, and a malformed one is ignored", () => {
  const h = home();
  shareHome(h);
  const a = machine(h, "a");
  const explicit = "00000000-0000-4000-8000-000000000004";
  assert.equal(whoami(h, { ...a, AGENTBAR_SOURCE_ID: explicit }).sourceId, explicit);
  assert.notEqual(whoami(h, { ...a, AGENTBAR_SOURCE_ID: "host-a" }).sourceId, "host-a");
});

test("a standalone home asks nothing of the machine", () => {
  assert.deepEqual(whoami(home()), { shared: false });
});

test("a shared home with no machine identity writes nothing, silently", () => {
  const h = home();
  shareHome(h);
  const none = { AGENTBAR_MACHINE_ID_FILE: path.join(h, "missing"), AGENTBAR_BOOT_ID_FILE: path.join(h, "missing") };
  const r = start(h, "session-a", none);
  assert.equal(r.status, 0);
  assert.equal(r.stderr, "");
  pre(h, "session-a", none);
  assert.deepEqual(files(h), []);
  const doc = JSON.parse(cli(h, ["doctor", "--json"], none).stdout);
  assert.equal(doc.find((c) => c.id === "remote.cluster").status, "fail");
});

test("a cluster file nobody understands fails closed", () => {
  const h = home();
  fs.writeFileSync(path.join(h, ".agentbar", owner.CLUSTER_FILE), "{ not json");
  assert.equal(start(h, "session-a", machine(h, "a")).status, 0);
  assert.deepEqual(files(h), [], "no flat file on a disk that may be shared");
});

// MARK: - Writers

test("standalone writers keep the exact layout-1 file", () => {
  const h = home();
  start(h, "session-a");
  pre(h, "session-a");
  assert.deepEqual(files(h), ["session-a.json"]);
  const r = rows(h)[0];
  assert.equal(r.ownerSourceId, undefined);
  assert.equal(r.stateLayout, undefined);
});

test("two machines, one home, the same session id and pid: two rows, each correctly owned", () => {
  const h = home();
  shareHome(h);
  const a = machine(h, "a"), b = machine(h, "b");
  // Both hooks run as children of this process, so both see the same ppid.
  start(h, "session-a", a); pre(h, "session-a", a, "Edit");
  start(h, "session-a", b); pre(h, "session-a", b, "Bash");
  assert.equal(files(h).length, 2);
  for (const f of files(h)) assert.match(f, LAYOUT2_NAME);
  const [r1, r2] = rows(h);
  assert.notEqual(r1.ownerSourceId, r2.ownerSourceId);
  assert.equal(r1.ownerPid, r2.ownerPid, "the same numeric pid on both machines");
  assert.deepEqual(new Set([r1.label, r2.label]), new Set(["Editing", "Running command"]));
  for (const r of [r1, r2]) {
    assert.equal(r.stateLayout, 2);
    assert.equal(r.sessionId, "session-a");
    assert.match(r.writeId, UUID);
  }
});

test("every state.d writer names its owner on a shared home", () => {
  const h = home();
  shareHome(h);
  const a = machine(h, "a");
  const now = Math.floor(Date.now() / 1000);
  hook(h, "cursor/cursor.js", [], { hook_event_name: "preToolUse", conversation_id: "c1", tool_name: "Shell" }, a);
  hook(h, "gemini/gemini.js", [], { hook_event_name: "BeforeTool", session_id: "g1", tool_name: "shell" }, a);
  hook(h, "antigravity/antigravity.js", ["PreToolUse"], { conversationId: "ag1" }, a);
  cp.spawnSync(process.execPath, [path.join(HOOKS, "codex/notify.js"),
    JSON.stringify({ type: "agent-turn-complete", "thread-id": "t1" })], { env: env(h, a) });
  hook(h, "codex/hook.js", ["update.js", "pre"], { session_id: "x1", tool_name: "Bash" }, a);
  hook(h, "claude/update.js", ["pre"], { session_id: "q1", tool_name: "Bash" }, { ...a, AGENTBAR_AGENT: "qwen" });
  const all = rows(h);
  assert.deepEqual(all.map((r) => r.agent).sort(), ["antigravity", "codex", "codex", "cursor", "gemini", "qwen"]);
  const me = whoami(h, a).sourceId;
  for (const r of all) {
    assert.equal(r.stateLayout, 2, r.agent);
    assert.equal(r.ownerSourceId, me, r.agent);
    assert.ok(r.ts >= now - 5);
  }
  for (const f of files(h)) assert.match(f, LAYOUT2_NAME);
});

test("the OpenCode plugin names its owner too, via the installed helper", () => {
  const h = home();
  fs.cpSync(HOOKS, path.join(h, ".agentbar", "hooks"), { recursive: true });
  shareHome(h);
  const a = machine(h, "a");
  const script = `
    process.env.HOME = ${JSON.stringify(h)};
    Object.assign(process.env, ${JSON.stringify(a)});
    const { AgentBar } = await import(${JSON.stringify(path.join(HOOKS, "opencode", "agentbar.js"))});
    const p = await AgentBar({ directory: "/work/project-a" });
    await p.event({ event: { type: "session.created", properties: { info: { id: "o1" } } } });
    await p["tool.execute.before"]({ sessionID: "o1", tool: "bash" });
  `;
  const r = cp.spawnSync(process.execPath, ["--input-type=module", "-e", script], { env: env(h), encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  assert.ok(rows(h).length >= 1);
  for (const row of rows(h)) assert.equal(row.stateLayout, 2);
});

test("the permission hook stamps its row and still asks", async () => {
  const h = home();
  shareHome(h);
  const a = machine(h, "a");
  const c = cp.spawn(process.execPath, [path.join(HOOKS, "claude/permission.js")],
    { env: env(h, { ...a, AGENTBAR_APPROVAL_TIMEOUT: "3" }) });
  c.stdin.end(JSON.stringify({ session_id: "session-p", tool_name: "Bash", tool_input: { command: "ls" },
                               cwd: "/work/project-a" }));
  const reqDir = path.join(h, ".agentbar", "requests.d");
  for (let i = 0; i < 50 && !(fs.existsSync(reqDir) && fs.readdirSync(reqDir).length); i++)
    await new Promise((r) => setTimeout(r, 50));
  const row = rows(h)[0];
  assert.equal(row.state, "permission");
  assert.equal(row.stateLayout, 2);
  assert.equal(fs.readdirSync(reqDir).length, 1, "the request itself is unchanged");
  c.kill("SIGTERM");
  await new Promise((r) => c.on("close", r));
});

// MARK: - Sweeps and ends

test("a machine's sweep and CLI never prune another machine's row, whatever its pid", () => {
  const h = home();
  shareHome(h);
  const a = machine(h, "a"), b = machine(h, "b");
  pre(h, "session-b", b);
  // Make b's pid one that is certainly dead on a: exactly the row a naive sweep deletes.
  const [fb] = files(h);
  const pb = path.join(stateDir(h), fb);
  const row = JSON.parse(fs.readFileSync(pb, "utf8"));
  fs.writeFileSync(pb, JSON.stringify({ ...row, pid: 999999, ownerPid: 999999 }));
  start(h, "session-a", { ...a, AGENTBAR_FORCE_APP: "0" });
  const status = cli(h, ["status", "--json"], a);
  assert.ok(files(h).includes(fb), "b's row survives a's hook sweep and a's CLI");
  assert.ok(!JSON.parse(status.stdout).some((s) => s.sessionId === "session-b"), "and a does not show it");
  // b itself may clear it.
  start(h, "session-c", { ...b, AGENTBAR_FORCE_APP: "0" });
  assert.ok(!files(h).includes(fb));
});

test("a rebooted machine clears its earlier boot's row even though the pid is alive", () => {
  const h = home();
  shareHome(h);
  pre(h, "session-a", machine(h, "a", "boot-1"));
  const after = machine(h, "a", "boot-2");
  assert.ok(!JSON.parse(cli(h, ["status", "--json"], after).stdout).length, "not shown as live");
  start(h, "session-new", { ...after, AGENTBAR_FORCE_APP: "0" });
  assert.equal(rows(h).filter((r) => r.sessionId === "session-a").length, 0);
});

test("legacy rows on a shared home are neither shown nor deleted, and doctor counts them", () => {
  const h = home();
  const legacy = path.join(stateDir(h), "session-old.json");
  fs.writeFileSync(legacy, JSON.stringify({ agent: "claude", state: "tool", pid: 999999, started: true,
                                            ts: Math.floor(Date.now() / 1000) }));
  shareHome(h);
  const a = machine(h, "a");
  start(h, "session-a", { ...a, AGENTBAR_FORCE_APP: "0" });
  assert.ok(!JSON.parse(cli(h, ["status", "--json"], a).stdout).some((s) => s.id === "session-old"));
  assert.ok(fs.existsSync(legacy));
  const doc = JSON.parse(cli(h, ["doctor", "--json"], a).stdout);
  assert.equal(doc.find((c) => c.id === "remote.cluster").status, "warn");
});

test("a standalone home never touches a layout-2 row", () => {
  const h = home();
  shareHome(h);
  pre(h, "session-a", machine(h, "a"));
  cli(h, ["configure-cluster", "--standalone"]);
  const [f] = files(h);
  const p = path.join(stateDir(h), f);
  fs.writeFileSync(p, JSON.stringify({ ...JSON.parse(fs.readFileSync(p, "utf8")), pid: 999999, ownerPid: 999999 }));
  start(h, "session-b", { AGENTBAR_FORCE_APP: "0" });
  cli(h, ["status"]);
  assert.ok(files(h).includes(f), "a rolled-back cluster's rows are not reinterpreted as flat ones");
});

test("session end deletes only this machine's own row", () => {
  const h = home();
  shareHome(h);
  const a = machine(h, "a"), b = machine(h, "b");
  pre(h, "session-a", a); pre(h, "session-a", b);
  hook(h, "claude/lifecycle.js", ["end"], { session_id: "session-a" }, a);
  const left = rows(h);
  assert.equal(left.length, 1);
  assert.equal(left[0].ownerSourceId, whoami(h, b).sourceId);
});

test("file names are fixed-width hashes and contain nothing readable", () => {
  const own = { shared: true, sourceId: "00000000-0000-4000-8000-000000000001",
                bootId: "00000000-0000-4000-8000-000000000002" };
  const f = path.basename(owner.stateFile("/x", "project-a-session", own));
  assert.match(f, LAYOUT2_NAME);
  assert.ok(!f.includes("project"));
  assert.equal(f, path.basename(owner.stateFile("/y", "project-a-session", own)), "stable");
  assert.equal(path.basename(owner.stateFile("/x", "s", { shared: false })), "s.json");
});
