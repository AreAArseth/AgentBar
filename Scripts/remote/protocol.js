// The remote status stream, as data: what a frame may carry and how big it may
// get. The Mac decodes the same schema in `RemoteProtocol.swift`; the prose
// contract is `docs/remote-protocol.md`, and the three must agree.
//
// A remote row is a *projection* of a state.d row, never a copy. It keeps what a
// status line needs and drops everything that means something only on the
// machine that wrote it — pid, cwd, terminal, url — and everything that is the
// user's words rather than the agent's state: prompt and recap stay home.
"use strict";

const path = require("path");

const VERSION = 2;
const MAX_FRAME_BYTES = 256 * 1024;
const MAX_SESSIONS = 128;
const HEARTBEAT_SECONDS = 10;

// Mirrors Agent.all in Sources/AgentBar/Agents.swift. A row naming anything else
// is not projected: the Mac would refuse the frame for it anyway.
const AGENTS = new Set(["claude", "codex", "copilot", "antigravity", "cursor", "gemini",
                        "qwen", "opencode", "devin"]);
const STATES = new Set(["idle", "thinking", "tool", "permission", "question", "done", "error"]);
const PRIORITY = { permission: 4, question: 3, thinking: 2, tool: 2, error: 1, idle: 0, done: 0 };

const LIMITS = { id: 64, label: 80, project: 80, model: 64, activity: 5, activityItem: 40 };
// Years past 2100 are a writer's bug, not a time; the Mac applies the same ceiling.
const MAX_TIME = 4102444800;

// Control characters (C0, C1) and the bidirectional overrides are what would let
// a row rearrange how the line around it reads. They become spaces here and are
// refused outright on the Mac.
const UNSAFE = /[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g;
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g;

function clean(value, max) {
  if (typeof value !== "string") return "";
  let s = value.replace(LONE_SURROGATE, "").replace(UNSAFE, " ").replace(/\s+/g, " ").trim();
  // Count code points, not UTF-16 units, so a cut never splits a pair.
  const points = Array.from(s);
  if (points.length > max) s = points.slice(0, max).join("");
  return s;
}

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, LIMITS.id);

const time = (v) => (Number.isInteger(v) && v > 0 && v <= MAX_TIME ? v : undefined);

// One state.d row as the stream carries it, or null when it has nothing a
// remote status line could show. `fileId` is the file name without `.json`,
// which is the session's identity in layout 1; layout 2 hashes file names, so
// there the row's own sessionId is the identity.
function project(row, fileId, ident) {
  if (!row || typeof row !== "object") return null;
  const agent = typeof row.agent === "string" ? row.agent : "claude";
  if (!AGENTS.has(agent)) return null;
  const state = STATES.has(row.state) ? row.state : "idle";
  const id = safeId(ident.shared ? row.sessionId || "" : fileId);
  if (!id) return null;
  const out = {
    id,
    ownerSourceId: ident.sourceId,
    ownerBootId: ident.bootId,
    agent,
    state,
    label: clean(row.label, LIMITS.label),
    project: clean(path.basename(typeof row.project === "string" ? row.project : ""), LIMITS.project),
    started: true,
  };
  const startedAt = time(row.started_at);
  if (startedAt) out.startedAt = startedAt;
  const updatedAt = time(row.ts);
  if (updatedAt) out.updatedAt = updatedAt;
  const model = clean(row.model, LIMITS.model);
  if (model) out.model = model;
  if (Array.isArray(row.activity)) {
    const steps = row.activity.map((a) => clean(a, LIMITS.activityItem)).filter(Boolean)
      .slice(-LIMITS.activity);
    if (steps.length) out.activity = steps;
  }
  return out;
}

// The most relevant rows survive the cap — what is waiting, then what is
// working, then the newest — and the survivors go out in id order, so two
// snapshots of the same state are byte-identical.
function select(rows) {
  const kept = rows.slice().sort((a, b) =>
    (PRIORITY[b.state] - PRIORITY[a.state]) || ((b.updatedAt || 0) - (a.updatedAt || 0))
    || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)).slice(0, MAX_SESSIONS);
  return kept.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

const header = (type, ident, streamId, seq) => ({
  v: VERSION, type, sourceId: ident.sourceId, bootId: ident.bootId, streamId, seq,
  sentAt: Math.floor(Date.now() / 1000),
});

function hello(ident, streamId, heartbeatSeconds = HEARTBEAT_SECONDS) {
  return { ...header("hello", ident, streamId, 0), heartbeatSeconds,
           stateLayout: ident.stateLayout, sharedHome: !!ident.shared };
}

function heartbeat(ident, streamId, seq) {
  return header("heartbeat", ident, streamId, seq);
}

// A snapshot serialized to one line, shrunk until it fits the frame cap. Rows
// dropped to fit are admitted in `truncated`, so the Mac can say the list is
// partial instead of presenting it as everything.
function snapshotLine(ident, streamId, seq, body) {
  let sessions = body.sessions;
  let truncated = body.truncated === true;
  for (;;) {
    const frame = { ...header("snapshot", ident, streamId, seq), sessions, counts: body.counts, truncated };
    const line = JSON.stringify(frame);
    if (Buffer.byteLength(line) + 1 <= MAX_FRAME_BYTES || sessions.length === 0) return line;
    sessions = sessions.slice(0, Math.floor(sessions.length / 2));
    truncated = true;
  }
}

module.exports = {
  VERSION, MAX_FRAME_BYTES, MAX_SESSIONS, HEARTBEAT_SECONDS, AGENTS, STATES, LIMITS,
  clean, safeId, project, select, hello, heartbeat, snapshotLine,
};
