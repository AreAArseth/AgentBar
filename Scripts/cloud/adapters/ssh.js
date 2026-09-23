// Agents running on your own machines over SSH -> normalized runs.
//
// Not a vendor API: the remote machine runs AgentBar's own hooks (installed with
// `agentbar install-hooks`, the Linux CLI), which write the same state.d rows
// this Mac reads. So the whole adapter is "read that folder over ssh": one
// `ssh host sh -c …` per host per poll, printing every row whose agent process is
// still alive there, separated by an ASCII record separator.
//
// Read-only by design. A remote row that waits on permission arrives as
// `question` — the cloud boundary in lib/policy.js — because there is no hook on
// THIS machine blocked behind it, and an Allow here would answer nothing (or, for
// an agent with approveKeys, type into whatever terminal is in front). A click
// opens `ssh://<host>` instead, which is where the prompt actually is.
//
// Hosts come only from ~/.agentbar/cloud.json, and are checked before they reach
// ssh's argv: a "host" starting with "-" would be read as an option.

const { execFile } = require("child_process");

const vendor = "ssh";
const agentId = "claude"; // fallback only: every remote row names its own agent
const prefix = "ssh-";

const SEP = "\x1e";

// Prints each live row's JSON followed by a record separator. The pid check
// runs remotely, because a pid means nothing on this machine: a row whose agent
// died without its end hook firing would otherwise sit in the bar for a day.
const REMOTE = [
  'd="$HOME/.agentbar/state.d"',
  'for f in "$d"/*.json; do',
  '  [ -f "$f" ] || continue',
  "  pid=$(sed -n 's/.*\"pid\": *\\([0-9][0-9]*\\).*/\\1/p' \"$f\" | head -n 1)",
  '  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then cat "$f"; printf \'\\n\\036\\n\'; fi',
  "done",
].join("\n");

const KNOWN_AGENTS = new Set(["claude", "codex", "copilot", "antigravity", "cursor",
  "gemini", "qwen", "opencode"]);

// user@host, host, host:port is NOT accepted (ssh takes -p for that; use an alias
// in ~/.ssh/config). Letters, digits, dot, dash, underscore, one @, no leading dash.
const validHost = (h) => typeof h === "string" && /^(?!-)[A-Za-z0-9._-]+(@[A-Za-z0-9._-]+)?$/.test(h);
const validName = (n) => typeof n === "string" && /^[A-Za-z0-9._-]{1,24}$/.test(n);

const hostsOf = (cfg) =>
  (Array.isArray(cfg.hosts) ? cfg.hosts : [])
    .map((h) => (typeof h === "string" ? { host: h } : h || {}))
    .map((h) => ({ host: h.host, name: h.name || String(h.host || "").split("@").pop() }))
    .filter((h) => validHost(h.host) && validName(h.name));

const runOne = (cfg, h) =>
  new Promise((resolve) => {
    execFile(cfg.bin || "ssh",
      ["-o", "BatchMode=yes", "-o", `ConnectTimeout=${cfg.connectTimeout || 5}`, "--", h.host, REMOTE],
      { timeout: 20_000, maxBuffer: 2 * 1024 * 1024 },
      (err, stdout, stderr) => {
        if (err) return resolve({ ...h, error: String(stderr || err.message).trim().slice(0, 160) });
        resolve({ ...h, out: String(stdout) });
      });
  });

// Every host is asked; one that is down or asleep is a warning, not a failed
// poll — a laptop lid closing must not stale out the rows of the server beside it.
const fetchRaw = async (cfg) => {
  const hosts = hostsOf(cfg);
  if (!hosts.length) throw new Error("ssh: no valid hosts in cloud.json");
  return Promise.all(hosts.map((h) => runOne(cfg, h)));
};

const STATES = new Set(["idle", "thinking", "tool", "permission", "question", "done", "error"]);

const normalize = (raw, cfg, now) => {
  const rows = [];
  const warnings = [];
  for (const h of raw || []) {
    if (h.error) { warnings.push(`${h.name}: ${h.error}`); continue; }
    for (const chunk of String(h.out || "").split(SEP)) {
      const text = chunk.trim();
      if (!text) continue;
      let r;
      try { r = JSON.parse(text); } catch { continue; }
      if (!r || typeof r !== "object" || r.started === false) continue;
      // A row that is itself a mirror (the remote runs this poller too) stays
      // there: mirroring a mirror turns one session into a chain of them.
      if (r.entrypoint === "cloud") continue;
      const state = STATES.has(r.state) ? r.state : "idle";
      const waiting = state === "permission" || state === "question";
      rows.push({
        id: `${h.name}-${r.sessionId || "unknown"}`,
        agentId: KNOWN_AGENTS.has(r.agent) ? r.agent : agentId,
        state: state === "tool" ? "thinking" : state,
        label: waiting ? `Waiting on you on ${h.name}` : (r.label || ""),
        project: `${h.name}: ${r.project || "~"}`,
        prompt: r.prompt || "",
        recap: r.recap || "",
        url: `ssh://${h.host}`,
        started_at: Number(r.started_at) || 0,
        updated_at: Math.min(Number(r.ts) || now, now),
        recentHours: cfg.recentHours,
      });
    }
  }
  return { rows, warnings };
};

module.exports = { vendor, agentId, prefix, fetchRaw, normalize, hostsOf, validHost, REMOTE };
