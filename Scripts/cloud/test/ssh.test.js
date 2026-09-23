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

const out = (...rows) => rows.map((r) => JSON.stringify(r) + "\n\x1e\n").join("");

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
  const fake = path.join(home, "fake-ssh");
  fs.writeFileSync(fake, `#!/bin/sh\nwhile [ "$1" != "--" ]; do shift; done; shift; shift\nHOME="${home}" exec sh -c "$1"\n`);
  fs.chmodSync(fake, 0o755);
  try {
    const raw = await ssh.fetchRaw({ bin: fake, hosts: ["devbox"] });
    const { rows } = ssh.normalize(raw, DEFAULTS.ssh, NOW);
    assert.deepEqual(rows.map((r) => r.id), ["devbox-live"]);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});
