// The ssh adapter: host checks, row mapping, and the remote script itself — run
// for real against a throwaway HOME through a stand-in `ssh` that executes the
// command locally, so what is tested is the same text a real host would run.
const { test } = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

const ssh = require("../adapters/ssh");
const { toProtocolRow } = require("../lib/policy");
const { DEFAULTS } = require("../lib/config");

const NOW = 1_787_600_000;

test("ssh: a host that could be read as an option never reaches argv", () => {
  assert.equal(ssh.validHost("-oProxyCommand=evil"), false);
  assert.equal(ssh.validHost("me@devbox"), true);
  assert.equal(ssh.validHost("devbox.local"), true);
  assert.equal(ssh.validHost("host;reboot"), false);
  assert.equal(ssh.validHost("a@b@c"), false);
  const hosts = ssh.hostsOf({ hosts: ["devbox", { host: "me@gpu", name: "gpu" }, "-bad", { host: "x", name: "has space" }] });
  assert.deepEqual(hosts, [{ host: "devbox", name: "devbox" }, { host: "me@gpu", name: "gpu" }]);
});

test("ssh: off by default", () => {
  assert.equal(DEFAULTS.ssh.enabled, false);
});

const out = (...rows) => rows.map((r) => "\x1e\n" + JSON.stringify(r) + "\n").join("");

test("ssh: rows keep their agent, name their host, and a wait is never a permission", () => {
  const raw = [{ host: "me@devbox", name: "devbox", out: out(
    { agent: "codex", state: "permission", label: "Bash: make clean", project: "api",
      sessionId: "s1", pid: 10, started: true, ts: NOW - 5, prompt: "clean up" },
    { agent: "claude", state: "tool", label: "Editing", project: "web", sessionId: "s2",
      pid: 11, started: true, ts: NOW },
    { agent: "claude", state: "thinking", sessionId: "s3", pid: 12, started: false, ts: NOW },
    { agent: "codex", state: "thinking", sessionId: "cloud-x", entrypoint: "cloud", pid: 1, started: true, ts: NOW },
  ) }];
  const { rows } = ssh.normalize(raw, DEFAULTS.ssh, NOW);
  assert.equal(rows.length, 2, "unstarted and mirrored rows are skipped");
  const row = toProtocolRow(rows[0], ssh, NOW, 999);
  assert.equal(row.agent, "codex");
  assert.equal(row.state, "question", "a remote permission has no hook here to answer");
  assert.equal(row.label, "Waiting on you on devbox");
  assert.equal(row.project, "devbox: api");
  assert.equal(row.url, "ssh://me@devbox");
  assert.equal(row.entrypoint, "cloud");
  assert.equal(row.cwd, "");
  assert.equal(row.sessionId, "ssh-devbox-s1");
  assert.equal(toProtocolRow(rows[1], ssh, NOW, 999).state, "thinking");
});

test("ssh: a host that is down is a warning, not a failure of the others", () => {
  const { rows, warnings } = ssh.normalize([
    { host: "a", name: "a", error: "Connection timed out" },
    { host: "b", name: "b", out: out({ agent: "claude", state: "done", sessionId: "z", pid: 1, started: true, ts: NOW }) },
  ], DEFAULTS.ssh, NOW);
  assert.equal(rows.length, 1);
  assert.match(warnings[0], /^a: Connection timed out/);
});

test("ssh: the remote script prints live rows and drops dead ones", async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "agentbar-ssh-"));
  const d = path.join(home, ".agentbar", "state.d");
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, "live.json"), JSON.stringify({ agent: "claude", state: "thinking", sessionId: "live", pid: process.pid, started: true, ts: NOW }));
  fs.writeFileSync(path.join(d, "dead.json"), JSON.stringify({ agent: "claude", state: "thinking", sessionId: "dead", pid: 999999, started: true, ts: NOW }));
  // Stand-in ssh: drop the options and the host, run the command with HOME set.
  // Its login shell is tcsh, and its rc prints a banner — the two things a real
  // host does that a plain `sh -c` stand-in would hide.
  // tcsh where there is one (macOS ships it; a CI Linux image does not), plain sh
  // otherwise — the banner still proves the separator handling either way.
  const login = fs.existsSync("/bin/tcsh") ? "/bin/tcsh" : "/bin/sh";
  const fake = path.join(home, "fake-ssh");
  fs.writeFileSync(fake, `#!/bin/sh\nwhile [ "$1" != "--" ]; do shift; done; shift; shift\necho "Welcome to devbox"\nHOME="${home}" exec ${login} -c "$*"\n`);
  fs.chmodSync(fake, 0o755);
  try {
    const raw = await ssh.fetchRaw({ bin: fake, hosts: ["devbox"] });
    const { rows } = ssh.normalize(raw, DEFAULTS.ssh, NOW);
    assert.deepEqual(rows.map((r) => r.id), ["devbox-live"]);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});

test("ssh: a remote host cannot hand this Mac an absurd time", () => {
  const { rows } = ssh.normalize([{ host: "h", name: "h", out: out(
    { agent: "claude", state: "error", sessionId: "a", pid: 1, started: true, ts: -1e300, started_at: 1e300 },
    { agent: "claude", state: "done", sessionId: "b", pid: 1, started: true, ts: NOW + 99999, started_at: NOW - 60 },
  ) }], DEFAULTS.ssh, NOW);
  const a = toProtocolRow(rows[0], ssh, NOW, 1);
  assert.equal(a.started_at, undefined);
  assert.ok(a.ts > 0 && a.ts <= NOW);
  const b = toProtocolRow(rows[1], ssh, NOW, 1);
  assert.equal(b.started_at, NOW - 60);
  assert.ok(b.ts <= NOW, "a time in the future is not taken");
});

test("ssh: a long host name is shortened, a bad one is reported", () => {
  const dropped = [];
  const hosts = ssh.hostsOf({ hosts: ["build-server-01.eu-west.internal.example.com", "-x"] }, dropped);
  assert.deepEqual(hosts, [{ host: "build-server-01.eu-west.internal.example.com", name: "build-server-01" }]);
  assert.equal(dropped.length, 1);
});

test("ssh: a host that missed a poll keeps its rows for a while", () => {
  const { rows, keepPrefixes } = ssh.normalize([{ host: "a", name: "a", error: "timeout", keep: true }],
                                               DEFAULTS.ssh, NOW);
  assert.equal(rows.length, 0);
  assert.deepEqual(keepPrefixes, ["ssh-a-"]);
  const gone = ssh.normalize([{ host: "a", name: "a", error: "timeout", keep: false }], DEFAULTS.ssh, NOW);
  assert.deepEqual(gone.keepPrefixes, []);
});

test("ssh: rows per host are capped", () => {
  const many = Array.from({ length: 80 }, (_, i) =>
    ({ agent: "claude", state: "thinking", sessionId: "s" + i, pid: 1, started: true, ts: NOW }));
  const { rows, warnings } = ssh.normalize([{ host: "h", name: "h", out: out(...many) }], DEFAULTS.ssh, NOW);
  assert.equal(rows.length, 50);
  assert.match(warnings[0], /more than 50/);
});

// MARK: - Owner-aware reads (state layout 2, docs/remote-protocol.md)

const cp = require("child_process");
const REPO = path.join(__dirname, "..", "..");

const frames = (hello, snapshot) => `\x1e${ssh.COLLECTOR}\nWelcome to devbox\n${JSON.stringify(hello)}\n${JSON.stringify(snapshot)}\n`;
const SRC = "00000000-0000-4000-8000-00000000000a";
const BOOT = "00000000-0000-4000-8000-000000000b01";
const STREAM = "00000000-0000-4000-8000-000000000501";
const hdr = (type, seq) => ({ v: 2, type, sourceId: SRC, bootId: BOOT, streamId: STREAM, seq, sentAt: NOW });
const hello = { ...hdr("hello", 0), heartbeatSeconds: 10, stateLayout: 2, sharedHome: true };
const session = (id, extra = {}) => ({ id, ownerSourceId: SRC, ownerBootId: BOOT, agent: "claude", state: "tool",
  label: "Editing", project: "web", started: true, startedAt: NOW - 60, updatedAt: NOW - 1, ...extra });

test("ssh: the collector's snapshot becomes the same rows, without prompts", () => {
  const snap = { ...hdr("snapshot", 1), sessions: [session("s1"), session("s2", { state: "permission" })],
                 counts: { owned: 2, foreign: 3, legacy: 0, oldBoot: 0 }, truncated: false };
  const { rows, warnings } = ssh.normalize([{ host: "devbox", name: "devbox", out: frames(hello, snap) }], DEFAULTS.ssh, NOW);
  assert.deepEqual(warnings, []);
  assert.deepEqual(rows.map((r) => r.id), ["devbox-s1", "devbox-s2"]);
  assert.equal(rows[0].project, "devbox: web");
  assert.equal(rows[0].prompt, "");
  assert.equal(rows[0].started_at, NOW - 60);
  assert.equal(toProtocolRow(rows[1], ssh, NOW, 1).state, "question");
});

test("ssh: a collector that speaks for another machine is not believed", () => {
  const foreign = { ...hdr("snapshot", 1), sessions: [session("s1", { ownerSourceId: "00000000-0000-4000-8000-00000000000b" })],
                    counts: {}, truncated: false };
  const r1 = ssh.normalize([{ host: "h", name: "h", out: frames(hello, foreign) }], DEFAULTS.ssh, NOW);
  assert.equal(r1.rows.length, 0);
  assert.match(r1.warnings[0], /not its own/);
  const otherStream = { ...hdr("snapshot", 1), streamId: "00000000-0000-4000-8000-000000000502", sessions: [], counts: {} };
  assert.match(ssh.normalize([{ host: "h", name: "h", out: frames(hello, otherStream) }], DEFAULTS.ssh, NOW).warnings[0],
               /not its own/);
  const none = ssh.normalize([{ host: "h", name: "h", out: `\x1e${ssh.COLLECTOR}\n` }], DEFAULTS.ssh, NOW);
  assert.match(none.warnings[0], /no snapshot/);
});

test("ssh: a shared home without the collector says so and shows nothing", () => {
  const { rows, warnings } = ssh.normalize([{ host: "h", name: "h", out: `\x1e${ssh.SHARED_WITHOUT_COLLECTOR}\n` }],
                                           DEFAULTS.ssh, NOW);
  assert.equal(rows.length, 0);
  assert.match(warnings[0], /shared by several machines/);
});

// Two machines sharing one home, and the real remote script run through the same
// tcsh-with-a-banner stand-in as above — once through the collector, once
// through the plain sh read.
const withEnv = async (vars, fn) => {
  const saved = Object.fromEntries(Object.keys(vars).map((k) => [k, process.env[k]]));
  Object.assign(process.env, vars);
  try { return await fn(); } finally {
    for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  }
};
const sharedHome = () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "agentbar-ssh-shared-"));
  fs.mkdirSync(path.join(home, ".agentbar", "state.d"), { recursive: true });
  const env = { ...process.env, HOME: home, AGENTBAR_FORCE_APP: "1" };
  delete env.AGENTBAR_SOURCE_ID;
  cp.spawnSync(process.execPath, [path.join(REPO, "cli", "agentbar"), "configure-cluster", "--shared-home"], { env });
  const machine = (name) => {
    fs.writeFileSync(path.join(home, `machine-${name}`), `raw-machine-${name}\n`);
    fs.writeFileSync(path.join(home, `boot-${name}`), `raw-boot-${name}\n`);
    return { AGENTBAR_MACHINE_ID_FILE: path.join(home, `machine-${name}`),
             AGENTBAR_BOOT_ID_FILE: path.join(home, `boot-${name}`) };
  };
  const write = (m, id, tool) => cp.spawnSync(process.execPath, [path.join(REPO, "hooks", "claude", "update.js"), "pre"],
    { env: { ...env, ...m }, input: JSON.stringify({ session_id: id, cwd: "/work/web", tool_name: tool }) });
  const login = fs.existsSync("/bin/tcsh") ? "/bin/tcsh" : "/bin/sh";
  const fake = path.join(home, "fake-ssh");
  fs.writeFileSync(fake, `#!/bin/sh\nwhile [ "$1" != "--" ]; do shift; done; shift; shift\necho "Welcome to devbox"\nHOME="${home}" exec ${login} -c "$*"\n`);
  fs.chmodSync(fake, 0o755);
  const installCollector = () => {
    const bin = path.join(home, ".agentbar", "bin");
    fs.mkdirSync(bin, { recursive: true });
    fs.writeFileSync(path.join(bin, "agentbar-remote"),
      `#!/bin/sh\nexec '${process.execPath}' '${path.join(REPO, "remote", "stream.js")}' "$@"\n`, { mode: 0o755 });
  };
  return { home, machine, write, fake, installCollector };
};

test("ssh: through the collector, each machine of a shared home reports only its own rows", async () => {
  const s = sharedHome();
  const a = s.machine("a"), b = s.machine("b");
  // Same session id on both machines, and the hooks' parent (this process) is
  // alive on both — exactly what the plain read cannot tell apart.
  s.write(a, "session-1", "Edit");
  s.write(b, "session-1", "Bash");
  s.installCollector();
  try {
    const read = (m) => withEnv(m, async () => ssh.normalize(await ssh.fetchRaw({ bin: s.fake, hosts: ["devbox"] }),
                                                              DEFAULTS.ssh, NOW));
    const fromA = await read(a), fromB = await read(b);
    assert.deepEqual(fromA.warnings, []);
    assert.deepEqual(fromA.rows.map((r) => [r.id, r.label]), [["devbox-session-1", "Editing"]]);
    assert.deepEqual(fromB.rows.map((r) => [r.id, r.label]), [["devbox-session-1", "Running command"]]);
    assert.ok(!JSON.stringify([fromA, fromB]).includes("raw-machine"));
  } finally {
    fs.rmSync(s.home, { recursive: true, force: true });
  }
});

test("ssh: without the collector, a shared home answers with a notice and no rows", async () => {
  const s = sharedHome();
  const a = s.machine("a");
  s.write(a, "session-1", "Edit");
  try {
    const out = await withEnv(a, async () => ssh.normalize(await ssh.fetchRaw({ bin: s.fake, hosts: ["devbox"] }),
                                                           DEFAULTS.ssh, NOW));
    assert.equal(out.rows.length, 0);
    assert.match(out.warnings[0], /shared by several machines/);
  } finally {
    fs.rmSync(s.home, { recursive: true, force: true });
  }
});

test("ssh: the plain read never takes a cluster node's row as a standalone machine's", async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "agentbar-ssh-"));
  const d = path.join(home, ".agentbar", "state.d");
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, "mine.json"), JSON.stringify({ agent: "claude", state: "thinking", sessionId: "mine",
    pid: process.pid, started: true, ts: NOW }));
  fs.writeFileSync(path.join(d, "0123456789abcdef-0123456789abcdef0123456789abcdef.json"), JSON.stringify({
    agent: "claude", state: "thinking", sessionId: "node", pid: process.pid, ownerPid: process.pid,
    ownerSourceId: SRC, ownerBootId: BOOT, stateLayout: 2, started: true, ts: NOW }));
  const login = fs.existsSync("/bin/tcsh") ? "/bin/tcsh" : "/bin/sh";
  const fake = path.join(home, "fake-ssh");
  fs.writeFileSync(fake, `#!/bin/sh\nwhile [ "$1" != "--" ]; do shift; done; shift; shift\necho "Welcome to devbox"\nHOME="${home}" exec ${login} -c "$*"\n`);
  fs.chmodSync(fake, 0o755);
  try {
    const { rows } = ssh.normalize(await ssh.fetchRaw({ bin: fake, hosts: ["devbox"] }), DEFAULTS.ssh, NOW);
    assert.deepEqual(rows.map((r) => r.id), ["devbox-mine"]);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});
