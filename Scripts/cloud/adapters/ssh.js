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
//
// Two ways to read a host, chosen on the host. When AgentBar's collector is
// installed there (`agentbar install-hooks` puts it at ~/.agentbar/bin/
// agentbar-remote), the script runs it once: one hello and one snapshot of the
// rows THAT machine owns, already projected and capped (docs/remote-protocol.md).
// That is the only correct read of a home several machines share — the rows of
// every node sit in one state.d, and a pid is only meaningful on the node that
// issued it (state layout 2, docs/protocol.md). Without the collector, the plain
// sh script below reads the folder itself, and it cannot compute which node it is
// on, so a shared home answers with a notice and no rows rather than every node's
// rows checked against the wrong machine's pids.

const { execFile } = require("child_process");
const { epoch } = require("../lib/policy");

const vendor = "ssh";
const agentId = "claude"; // fallback only: every remote row names its own agent
const prefix = "ssh-";

const SEP = "\x1e";
// What the script prints, after a separator, to say which read it did.
const COLLECTOR = "agentbar-collector";
const SHARED_WITHOUT_COLLECTOR = "agentbar-shared-home-needs-collector";

// The collector when it is installed; otherwise each live row's JSON preceded by
// a record separator. The pid check runs remotely, because a pid means nothing on
// this machine: a row whose agent died without its end hook firing would
// otherwise sit in the bar for a day. A shared home without the collector prints
// only its notice, and a standalone home skips any row a cluster node wrote
// (`ownerSourceId`), so a rolled-back cluster's files are never read as its own.
const REMOTE = [
  'c="$HOME/.agentbar/bin/agentbar-remote"',
  'if [ -x "$c" ]; then',
  `  printf '\\036${COLLECTOR}\\n'`,
  '  "$c" --protocol 2 --once </dev/null',
  "  exit 0",
  "fi",
  'k="$HOME/.agentbar/remote-cluster.json"',
  'if [ -f "$k" ] && ! grep -q \'"sharedHome": *false\' "$k"; then',
  `  printf '\\036${SHARED_WITHOUT_COLLECTOR}\\n'`,
  "  exit 0",
  "fi",
  'd="$HOME/.agentbar/state.d"',
  'for f in "$d"/*.json; do',
  '  [ -f "$f" ] || continue',
  "  grep -q '\"ownerSourceId\"' \"$f\" && continue",
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

const toRun = (h, cfg, now, r) => {
  const state = STATES.has(r.state) ? r.state : "idle";
  const waiting = state === "permission" || state === "question";
  return {
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
  };
};

// The collector's frames: one hello, then one snapshot. Believed only when the
// snapshot is the hello's own stream and every row is owned by the machine that
// sent it — a collector may not speak for another node, or another boot of
// itself. Lines that are not JSON (an rc file's banner) are skipped. Rows come
// back in the shape the sh read produces, so everything after is shared; the
// collector keeps prompts and recaps on the machine that has them.
const fromCollector = (text) => {
  let hello = null, snap = null;
  for (const line of text.split("\n")) {
    let f;
    try { f = JSON.parse(line); } catch { continue; }
    if (!f || typeof f !== "object" || f.v !== 2) continue;
    if (f.type === "hello" && !hello) hello = f;
    else if (f.type === "snapshot" && hello && !snap) snap = f;
  }
  if (!hello || !snap) return { error: "the collector sent no snapshot" };
  const same = snap.sourceId === hello.sourceId && snap.bootId === hello.bootId && snap.streamId === hello.streamId;
  const sessions = Array.isArray(snap.sessions) ? snap.sessions : [];
  const owned = sessions.every((s) => s && s.ownerSourceId === hello.sourceId && s.ownerBootId === hello.bootId);
  if (!same || !owned) return { error: "the collector reported rows that are not its own" };
  return { rows: sessions.map((s) => ({ agent: s.agent, state: s.state, label: s.label, project: s.project,
                                        sessionId: s.id, started: true, started_at: s.startedAt, ts: s.updatedAt })) };
};

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
    let candidates = [];
    for (const chunk of String(h.out || "").split(SEP)) {
      const text = chunk.trim();
      if (!text) continue;
      if (text.startsWith(COLLECTOR)) {
        const c = fromCollector(text.slice(COLLECTOR.length));
        if (c.error) warnings.push(`${h.name}: ${c.error}`);
        candidates = c.rows || [];
        break;
      }
      if (text.startsWith(SHARED_WITHOUT_COLLECTOR)) {
        warnings.push(`${h.name}: its home is shared by several machines — run \`agentbar install-hooks\` there so it can say which sessions are its own`);
        candidates = [];
        break;
      }
      let r;
      try { r = JSON.parse(text); } catch { continue; }
      candidates.push(r);
    }
    for (const r of candidates) {
      if (count >= MAX_ROWS_PER_HOST) { warnings.push(`${h.name}: more than ${MAX_ROWS_PER_HOST} sessions, rest skipped`); break; }
      if (!r || typeof r !== "object" || r.started === false) continue;
      // A row that is itself a mirror (the remote runs this poller too) stays
      // there: mirroring a mirror turns one session into a chain of them.
      if (r.entrypoint === "cloud") continue;
      count++;
      rows.push(toRun(h, cfg, now, r));
    }
  }
  return { rows, warnings, keepPrefixes };
};

module.exports = { vendor, agentId, prefix, fetchRaw, normalize, hostsOf, validHost, REMOTE,
                   COLLECTOR, SHARED_WITHOUT_COLLECTOR };
