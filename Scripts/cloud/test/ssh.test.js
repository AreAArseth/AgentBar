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
