// Agents running on your own machines over SSH -> normalized runs.
//
// Not a vendor API: the remote machine runs AgentBar's own hooks (installed with
// `agentbar install-hooks`, the Linux CLI), which write the same state.d rows
// this Mac reads. So the whole adapter is "read that folder over ssh": one
// `ssh host sh -s` per host per poll, the script on stdin, printing every row whose
// agent process is still alive there, each preceded by an ASCII record separator.
//
// `sh -s` rather than the script as ssh's command: sshd hands a command to the
// user's LOGIN shell, and a fish or tcsh login shell cannot parse `for … do`. Every
// shell can parse `sh -s`. The separator goes BEFORE each row, so whatever a chatty
// rc file prints first lands in a chunk of its own and costs nothing.
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
const { epoch } = require("../lib/policy");

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
  '  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then printf \'\\036\\n\'; cat "$f"; printf \'\\n\'; fi',
  "done",
].join("\n");

const KNOWN_AGENTS = new Set(["claude", "codex", "copilot", "antigravity", "cursor",
  "gemini", "qwen", "opencode"]);

// user@host, host, host:port is NOT accepted (ssh takes -p for that; use an alias
// in ~/.ssh/config). Letters, digits, dot, dash, underscore, one @, no leading dash.
const validHost = (h) => typeof h === "string" && /^(?!-)[A-Za-z0-9._-]+(@[A-Za-z0-9._-]+)?$/.test(h);
const validName = (n) => typeof n === "string" && /^[A-Za-z0-9._-]{1,24}$/.test(n);

// A name derived from the host is cut to fit (a long FQDN is still a fine host);
// a name the person wrote that does not fit is theirs to fix, and is reported.
const deriveName = (host) =>
  String(host || "").split("@").pop().split(".")[0].replace(/[^A-Za-z0-9._-]/g, "").slice(0, 24);

const hostsOf = (cfg, dropped = []) =>
  (Array.isArray(cfg.hosts) ? cfg.hosts : [])
    .map((h) => (typeof h === "string" ? { host: h } : h || {}))
    .map((h) => ({ host: h.host, name: h.name || deriveName(h.host) }))
    .filter((h) => {
      const ok = validHost(h.host) && validName(h.name);
      if (!ok) dropped.push(`skipped host ${JSON.stringify(String(h.host)).slice(0, 60)}: not a plain host or name`);
      return ok;
    });

// How many polls in a row a host may miss before its rows go. One missed poll is
// a lid closing for a second or a slow handshake; without grace every hiccup ends
// the host's sessions in the history and brings them back fifteen seconds later.
const GRACE_POLLS = 4;
const misses = new Map();

const runOne = (cfg, h) =>
  new Promise((resolve) => {
    const child = execFile(cfg.bin || "ssh",
      ["-o", "BatchMode=yes", "-o", `ConnectTimeout=${cfg.connectTimeout || 5}`, "--", h.host, "sh", "-s"],
      { timeout: 20_000, maxBuffer: 2 * 1024 * 1024 },
      (err, stdout, stderr) => {
        if (err) {
          const n = (misses.get(h.host) || 0) + 1;
          misses.set(h.host, n);
          return resolve({ ...h, error: String(stderr || err.message).trim().slice(0, 160),
                           keep: n <= GRACE_POLLS });
        }
        misses.delete(h.host);
        resolve({ ...h, out: String(stdout) });
      });
    child.stdin.on("error", () => {});
    child.stdin.end(REMOTE + "\n");
  });

// Every host is asked; one that is down or asleep is a warning, not a failed
// poll — a laptop lid closing must not stale out the rows of the server beside it.
const fetchRaw = async (cfg) => {
  const dropped = [];
  const hosts = hostsOf(cfg, dropped);
  const results = await Promise.all(hosts.map((h) => runOne(cfg, h)));
  return dropped.map((warning) => ({ warning })).concat(results);
};

// A remote host writes these rows, so no field it sends may be trusted to be a
// sane number: `1e300` in `started_at` traps the Mac app's first `Int(_:)` of it.
// Times go through the same `epoch` the vendor adapters use and are clamped to
// the past; anything else becomes 0, which every reader treats as unknown.
const pastTime = (v, now) => {
  const t = epoch(v);
  return t > 0 && t <= now ? t : 0;
};

// Rows per host, at most. A compromised host must not be able to churn thousands
// of files through state.d every fifteen seconds.
const MAX_ROWS_PER_HOST = 50;

const STATES = new Set(["idle", "thinking", "tool", "permission", "question", "done", "error"]);

const normalize = (raw, cfg, now) => {
  const rows = [];
  const warnings = [];
  const keepPrefixes = [];
  for (const h of raw || []) {
    if (h.warning) { warnings.push(h.warning); continue; }
    if (h.error) {
      warnings.push(`${h.name}: ${h.error}`);
      if (h.keep) keepPrefixes.push(`${prefix}${h.name}-`);
      continue;
    }
    let count = 0;
    for (const chunk of String(h.out || "").split(SEP)) {
      if (count >= MAX_ROWS_PER_HOST) { warnings.push(`${h.name}: more than ${MAX_ROWS_PER_HOST} sessions, rest skipped`); break; }
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
      count++;
      rows.push({
        id: `${h.name}-${r.sessionId || "unknown"}`,
        agentId: KNOWN_AGENTS.has(r.agent) ? r.agent : agentId,
        state: state === "tool" ? "thinking" : state,
        label: waiting ? `Waiting on you on ${h.name}` : (r.label || ""),
        project: `${h.name}: ${r.project || "~"}`,
        prompt: r.prompt || "",
        recap: r.recap || "",
        url: `ssh://${h.host}`,
        started_at: pastTime(r.started_at, now),
        updated_at: pastTime(r.ts, now) || now,
        recentHours: cfg.recentHours,
      });
    }
  }
  return { rows, warnings, keepPrefixes };
};

module.exports = { vendor, agentId, prefix, fetchRaw, normalize, hostsOf, validHost, REMOTE };
