// Which machine owns a state row, for homes that several machines share.
//
// A home mounted on every node of a cluster means one `~/.agentbar/state.d` seen
// by all of them. The flat `<session>.json` layout cannot survive that: two nodes
// write the same name, a pid is only meaningful on the node that issued it, and a
// sweep on one node deletes another node's live row. So a home that says it is
// shared (`~/.agentbar/remote-cluster.json`, written by `agentbar
// configure-cluster --shared-home`) switches every writer to **state layout 2**:
//
//   - every row carries `ownerSourceId` and `ownerBootId`, opaque HMACs of this
//     node's machine and boot identity under a salt kept in the shared home — or
//     an explicit `AGENTBAR_SOURCE_ID` UUID, which wins;
//   - the file is named `<source-token>-<session-token>.json`, so two nodes can
//     never target the same final name;
//   - only the owning node, in the same boot, may probe the row's pid or delete it.
//
// A home that says nothing stays on layout 1 and nothing here changes a byte of
// what the writers produce. A shared home whose identity cannot be established
// (no machine id, a salt that will not read) resolves to null: the writer skips
// its status write rather than guess, and the host agent never notices.
//
// Raw machine and boot identifiers are read, hashed and dropped. They never reach
// a row, a file name, stdout or a log.
"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const cp = require("child_process");

const LAYOUT = 2;
const CLUSTER_FILE = "remote-cluster.json";
const SALT_FILE = "identity-salt";
const SOURCE_FILE = "source-id";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const readText = (file) => {
  try { return fs.readFileSync(file, "utf8").trim(); } catch { return ""; }
};

// Node-local identities. The *_FILE overrides exist for the test suite, which has
// to play two machines on one disk; nothing in normal use sets them.
function machineIdentity() {
  const override = process.env.AGENTBAR_MACHINE_ID_FILE;
  if (override) return readText(override);
  if (process.platform === "darwin") {
    try {
      const out = cp.execFileSync("/usr/sbin/ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"],
        { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 1000 });
      const m = /"IOPlatformUUID"\s*=\s*"([^"]+)"/.exec(out);
      return m ? m[1] : "";
    } catch { return ""; }
  }
  return readText("/etc/machine-id") || readText("/var/lib/dbus/machine-id");
}

function bootIdentity() {
  const override = process.env.AGENTBAR_BOOT_ID_FILE;
  if (override) return readText(override);
  if (process.platform === "darwin") {
    try {
      return cp.execFileSync("/usr/sbin/sysctl", ["-n", "kern.bootsessionuuid"],
        { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 1000 }).trim();
    } catch { return ""; }
  }
  return readText("/proc/sys/kernel/random/boot_id");
}

// A UUID-shaped HMAC: the same value everywhere a UUID is expected, and nothing
// about the input recoverable from it.
function hmacUuid(salt, label, value) {
  const b = crypto.createHmac("sha256", salt).update(label + "\0" + value).digest().subarray(0, 16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

// Create-once, race-safe: write a private temp file, then hard-link it into
// place. link() fails when the name exists, so exactly one candidate is ever
// committed and every loser reads the winner. Returns the committed content.
function createOnce(file, content) {
  const existing = readText(file);
  if (existing) return existing;
  const tmp = `${file}.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`;
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(tmp, content + "\n", { mode: 0o600 });
    try { fs.linkSync(tmp, file); } catch (e) { if (e.code !== "EEXIST") throw e; }
  } finally {
    try { fs.unlinkSync(tmp); } catch {}
  }
  return readText(file);
}

const validSalt = (s) => /^[0-9a-f]{64}$/.test(s);
const salt = (base) => {
  const s = readText(path.join(base, SALT_FILE));
  return validSalt(s) ? s : "";
};
const ensureSalt = (base) => {
  const s = createOnce(path.join(base, SALT_FILE), crypto.randomBytes(32).toString("hex"));
  return validSalt(s) ? s : "";
};

// "standalone" | "shared" | "invalid". Missing file = standalone, the default
// every existing install is in. Anything present but not understood is invalid,
// and invalid never falls back to standalone: that would put flat files back
// onto a disk other machines share.
function clusterMode(base) {
  const file = path.join(base, CLUSTER_FILE);
  let raw;
  try { raw = fs.readFileSync(file, "utf8"); } catch (e) {
    return e.code === "ENOENT" ? "standalone" : "invalid";
  }
  try {
    const j = JSON.parse(raw);
    if (j && j.v === 1 && j.sharedHome === true) return "shared";
    if (j && j.v === 1 && j.sharedHome === false) return "standalone";
  } catch {}
  return "invalid";
}

const explicitSource = () => {
  const s = String(process.env.AGENTBAR_SOURCE_ID || "").trim().toLowerCase();
  return UUID.test(s) ? s : "";
};

// Hook writers ask this. { shared: false } keeps layout 1 exactly as it was;
// { shared: true, sourceId, bootId } is layout 2; null means "shared, but who
// this node is cannot be established" and the writer must skip the write.
function resolve(base) {
  const mode = clusterMode(base);
  if (mode === "standalone") return { shared: false };
  if (mode === "invalid") return null;
  const s = salt(base);
  if (!s) return null;
  const machine = machineIdentity();
  const sourceId = explicitSource() || (machine ? hmacUuid(s, "agentbar-source", machine) : "");
  const boot = bootIdentity();
  if (!sourceId || !boot) return null;
  return { shared: true, sourceId, bootId: hmacUuid(s, "agentbar-boot", boot) };
}

// The collector's identity. Shared mode is the same answer the hooks get, or a
// refusal with a reason; standalone mode names this home with a random id kept
// in it, since there is only one machine to name.
function collectorIdentity(base) {
  const mode = clusterMode(base);
  if (mode === "invalid") return { error: "cluster-config-invalid" };
  if (mode === "shared") {
    const own = resolve(base);
    return own ? { ...own, stateLayout: LAYOUT } : { error: "cluster-identity-unavailable" };
  }
  const s = ensureSalt(base);
  const sourceId = explicitSource()
    || createOnce(path.join(base, SOURCE_FILE), crypto.randomUUID()).toLowerCase();
  if (!s || !UUID.test(sourceId)) return { error: "standalone-identity-unavailable" };
  return { shared: false, sourceId, bootId: hmacUuid(s, "agentbar-boot", bootIdentity() || "unknown"),
           stateLayout: 1 };
}

const token = (value, n) => crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, n);

// Layout 2 names a file by who owns it and which session it is, both hashed to
// fixed widths (49 characters in all, inside the 64 every reader already caps
// at). Every writer of one session on one node derives the same name.
function stateFile(stateDir, rowId, own) {
  if (!own || !own.shared) return path.join(stateDir, rowId + ".json");
  return path.join(stateDir, `${token(own.sourceId, 16)}-${token(rowId, 32)}.json`);
}

// The owner fields on a row about to be written. A layout-1 row is returned as
// it came, so standalone files keep their exact shape.
function stamp(row, own) {
  if (!own || !own.shared) return row;
  return { ...row, ownerSourceId: own.sourceId, ownerBootId: own.bootId,
           ownerPid: Number(row.pid) || 0, stateLayout: LAYOUT, writeId: crypto.randomUUID() };
}

// Whether a sweep on this node may consider a row at all. Standalone never
// touches layout-2 rows (a rolled-back cluster must not have its rows
// reinterpreted); shared touches only its own.
function mayManage(row, own) {
  if (!row || typeof row !== "object") return !own || !own.shared;
  const layout2 = row.stateLayout === LAYOUT || typeof row.ownerSourceId === "string";
  if (!own || !own.shared) return !layout2;
  return layout2 && row.ownerSourceId === own.sourceId;
}

// Whether a row this node manages is from an earlier boot of it: dead whatever
// its pid says, because that pid now names some other process or none.
const fromEarlierBoot = (row, own) => !!(own && own.shared && row && row.ownerBootId !== own.bootId);

module.exports = {
  LAYOUT, CLUSTER_FILE, SALT_FILE, UUID,
  clusterMode, resolve, collectorIdentity, stateFile, stamp, mayManage, fromEarlierBoot,
  ensureSalt, createOnce, hmacUuid,
};
