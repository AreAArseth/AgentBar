#!/usr/bin/env node
// AgentBar bridge for Cursor CLI hooks. Maps Cursor's hook events (read from the
// stdin payload's hook_event_name) to a per-session state file in
// ~/.agentbar/state.d/, the same "folder is the protocol" the app already watches.
// Observe-only: writes state, emits nothing, exits fast — never affects the agent.
const fs = require("fs"), os = require("os"), path = require("path"), cp = require("child_process");

const AGENT = "cursor";
const BUNDLE_ID = "com.michalstrnadel.agentbar";
const EXEC = "AgentBar";
const base = path.join(os.homedir(), ".agentbar");
const stateDir = path.join(base, "state.d");

// Cursor event name -> AgentBar state. Exactly the events HookInstaller registers;
// the permission-gating before* hooks are deliberately not used by this bridge.
const STATE = {
  sessionStart: "idle", sessionEnd: "end",
  preToolUse: "tool", postToolUse: "thinking",
  stop: "done", afterAgentResponse: "done",
};

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64);
// A lone surrogate anywhere in a value — not only one a cut created — makes Swift's
// JSONSerialization reject the whole file, and an unreadable state file hides the
// session from every frontend until the next clean write. It cannot be caught after
// stringify, which escapes it into six harmless-looking characters, so it is caught
// on the values on the way out.
const paired = (k, v) => (typeof v === "string"
  ? v.replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, "")
  : v);
// Never end a cut on a lone high surrogate: JSON.stringify escapes one happily,
// but Swift's JSONSerialization rejects the whole file — and an unreadable state
// file hides the session from every frontend until the next clean write.
const sliceSafe = (s, n) => {
  const cut = s.slice(0, n);
  const last = cut.charCodeAt(cut.length - 1);
  return last >= 0xd800 && last <= 0xdbff ? cut.slice(0, -1) : cut;
};
// The macOS app, or the CLI's watch/waybar heartbeat (any platform).
// AGENTBAR_FORCE_APP=1|0 overrides for tests, same knob the claude hooks honor.
const running = () => {
  if (process.env.AGENTBAR_FORCE_APP === "1") return true;
  if (process.env.AGENTBAR_FORCE_APP === "0") return false;
  if (process.platform === "darwin") {
    try { cp.execSync(`pgrep -x ${EXEC}`, { stdio: "ignore" }); return true; } catch {}
  }
  try {
    const w = JSON.parse(fs.readFileSync(path.join(stateDir, "..", "watcher.json"), "utf8"));
    return Date.now() / 1000 - w.ts < 60;
  } catch { return false; }
};
const writeAtomic = (f, o) => { const t = f + "." + process.pid + ".tmp"; fs.writeFileSync(t, JSON.stringify(o, paired)); fs.renameSync(t, f); };

// Claims still open on a run. One whose worker is gone, or older than any row may
// live, was left by a crash: it holds nothing open and is cleared on the way past.
const openClaims = (dir) => {
  let names = []; try { names = fs.readdirSync(dir); } catch { return 0; }
  let open = 0;
  for (const f of names) {
    if (f.endsWith(".tmp")) continue;
    const p = path.join(dir, f);
    let c = {}; try { c = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
    let live = Date.now() / 1000 - (Number(c.ts) || 0) < 86400;
    if (live && Number(c.pid) > 0) {
      try { process.kill(Number(c.pid), 0); } catch (e) { live = e.code === "EPERM"; }
    }
    if (live) open++;
    else try { fs.rmSync(p, { force: true }); } catch {}
  }
  return open;
};

// One diagnostic per process, never more: this bridge fires on every event, so an
// unconditional log would flood the host agent's stderr. Self-swallowing and
// stderr-only — it can neither throw nor delay the exit.
let warned = false;
const warn = (what, err) => {
  if (warned) return;
  warned = true;
  try { console.error("[agentbar] " + what + " failed: " + ((err && err.message) || err)); } catch {}
};

let input = "", done = false;
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", run);
process.stdin.on("error", run);
setTimeout(run, 1000); // never hang the host

function run() {
  if (done) return; done = true;
  let j = {}; try { j = JSON.parse(input); } catch {}
  const event = j.hook_event_name || "";
  const state = STATE[event];
  if (!state) return process.exit(0);

  // The session is the conversation. generation_id names one turn, not a session.
  const id = j.conversation_id || j.session_id || "";
  // Cursor's cloud-agent worker sends its tool events with every id empty. Nothing
  // in them says whose they are, and one shared file would fold every run in that
  // process into a single row, so an event no session can be named for writes nothing.
  if (!safeId(id)) return process.exit(0);
  // The same worker's sessionStart/sessionEnd open and close a *claim* on the run
  // ("<conversation>:<epoch>" in session_id). A run holds several at once (a subagent
  // takes its own on the parent) and renews them while it works, so one claim
  // closing is not the session ending.
  const claim = j.session_id && j.session_id !== id ? safeId(String(j.session_id).replace(/:/g, "_")) : "";
  const claims = path.join(base, "claims.d", safeId(id));
  const cwd = j.cwd || (Array.isArray(j.workspace_roots) && j.workspace_roots[0]) || "";
  const statePath = path.join(stateDir, safeId(id) + ".json");

  try { fs.mkdirSync(stateDir, { recursive: true }); } catch (e) { warn("mkdir " + stateDir, e); }
  if (state === "end") {
    if (claim) {
      try { fs.rmSync(path.join(claims, claim), { force: true }); } catch (e) { warn("claim remove " + claim, e); }
      if (openClaims(claims) > 0) return process.exit(0);
    }
    try { fs.rmdirSync(claims); } catch {} // only when empty: a claim opening right now keeps it
    try { fs.rmSync(statePath, { force: true }); } catch (e) { warn("state remove " + statePath, e); }
    return process.exit(0);
  }
  if (state === "idle" && claim) {
    try {
      fs.mkdirSync(claims, { recursive: true });
      writeAtomic(path.join(claims, claim), { pid: process.ppid, ts: Math.floor(Date.now() / 1000) });
    } catch (e) { warn("claim write " + claim, e); }
    // Another claim on a run already shown says nothing about what it is doing.
    if (fs.existsSync(statePath)) return process.exit(0);
  }
  // App/watcher down on session start -> sweep leftovers from a prior crash, but
  // only files whose agent process is actually gone: other agents' sessions
  // outlive an AgentBar restart, and wiping the folder made live work disappear
  // (same rule as lifecycle.js and gemini.js).
  const appUp = state === "idle" ? running() : true;
  if (state === "idle" && !appUp) {
    try {
      let cleared = 0;
      for (const f of fs.readdirSync(stateDir)) {
        const p = path.join(stateDir, f);
        let owner = 0;
        try { owner = Number(JSON.parse(fs.readFileSync(p, "utf8")).pid) || 0; } catch {}
        if (owner > 0) {
          try { process.kill(owner, 0); continue; } catch (e) {
            if (e.code === "EPERM") continue; // exists, just not ours to signal
          }
        }
        fs.rmSync(p, { force: true });
        cleared++;
      }
      // Leave a trail: "my sessions vanished" must be explainable after the fact.
      if (cleared)
        console.error("[agentbar] AgentBar not running: cleared " + cleared +
                      " dead state file(s) from " + stateDir);
    } catch (e) { warn("stale state cleanup", e); }
  }

  let prev = {}; try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
  const ts = Math.floor(Date.now() / 1000);
  const oneLine = (s) => sliceSafe(String(s).replace(/\s+/g, " ").trim(), 120);
  try {
    writeAtomic(statePath, {
      ...prev, agent: AGENT, state,
      label: j.tool_name ? String(j.tool_name) : (state === "done" ? "Done" : ""),
      // An event without cwd must not erase the project an earlier one knew.
      project: (cwd || prev.cwd) ? path.basename(cwd || prev.cwd) : (prev.project || ""),
      cwd: cwd || prev.cwd || "", sessionId: id,
      entrypoint: "cli", term_program: process.env.TERM_PROGRAM || "",
      // Cursor execs the script directly, so ppid is the agent process (liveness handle).
      pid: process.ppid, started: state !== "idle" ? true : (prev.started || false),
      started_at: prev.started_at || ts, // set once; elapsed depends on it never moving
      ...(typeof j.prompt === "string" && j.prompt.trim() ? { prompt: oneLine(j.prompt) } : {}),
      ts,
    });
  } catch (e) { warn("state write " + statePath, e); }
  // Launch ONLY when nothing is running: with two copies on disk LaunchServices
  // may resolve the bundle ID to the OTHER copy and start a second instance —
  // which then terminates the one already running (see lifecycle.js).
  if (state === "idle" && process.platform === "darwin" && !appUp)
    cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
  process.exit(0);
}
