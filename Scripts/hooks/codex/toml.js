// Just enough TOML to read and write Codex's config safely; mirrors
// Sources/AgentBar/TOMLOutline.swift and the Codex parts of Diagnostics.swift.
//
// Shared by two readers that must give the same answer: the CLI (install-hooks and
// doctor load it from here) and notify.js next to it, which stands down only once
// AgentBar's own SessionStart hook is trusted — the same key doctor checks. It ships
// in hooks/codex/ because that folder is what both installers copy whole.
"use strict";

// Just enough of TOML's shape to put a top-level key where TOML reads it as one. A
// bare `key = value` after a table header is that table's, so appending Codex's
// `notify` to a config that has tables either breaks the file (under a string table
// Codex refuses to load it) or files the key where nothing reads it. Offsets are
// string indices. Comments, strings (all four kinds) and the inside of multi-line
// arrays and inline tables are skipped: a line there can start with `[` or
// `notify =` and be neither a header nor a key. Not a parser, and validates nothing.
function tomlOutline(t) {
  const n = t.length;
  let mode = "code", depth = 0, lineStart = 0, atLineStart = true, headerSeen = false, dirty = false, broken = false;
  const statements = [];
  // Where each comment with a line to itself starts (its #), outside every string,
  // array and inline table: a marker comment only counts as one of these.
  const comments = [];
  let topLevelEnd = null, firstHeader = null;
  const triple = (i, q) => t[i] === q && t[i + 1] === q && t[i + 2] === q;
  // An escape never swallows a line ending: the line bookkeeping has to see it.
  const escaped = (i) => (i + 1 < n && t[i + 1] !== "\n" ? 2 : 1);
  let i = 0;
  while (i < n) {
    const c = t[i];
    if (c === "\n") {
      if (!headerSeen && dirty) topLevelEnd = i + 1;
      dirty = false;
      if (mode === "basic" || mode === "literal") broken = true;
      if (mode === "comment" || mode === "header" || mode === "basic" || mode === "literal") mode = "code";
      i++;
      lineStart = i;
      atLineStart = mode === "code" && depth === 0;
      continue;
    }
    const blank = c === " " || c === "\t" || c === "\r";
    if (!headerSeen && !blank && mode !== "comment" && !(mode === "code" && c === "#")) dirty = true;
    if (mode === "comment") i++;
    else if (mode === "header") {
      if (c === "#") { mode = "comment"; i++; }
      else if (c === '"' || c === "'") {
        let j = i + 1;
        while (j < n && t[j] !== c && t[j] !== "\n") j += t[j] === "\\" && c === '"' ? escaped(j) : 1;
        i = j < n && t[j] === c ? j + 1 : j;
      } else i++;
    } else if (mode === "basic") {
      if (c === "\\") i += escaped(i);
      else { if (c === '"') mode = "code"; i++; }
    } else if (mode === "literal") {
      if (c === "'") mode = "code";
      i++;
    } else if (mode === "multiBasic" || mode === "multiLiteral") {
      const q = mode === "multiBasic" ? '"' : "'";
      if (mode === "multiBasic" && c === "\\") i += escaped(i);
      else if (triple(i, q)) {
        i += 3;
        for (let k = 0; k < 2 && t[i] === q; k++) i++;
        mode = "code";
      } else i++;
    } else {
      if (blank) { i++; continue; }
      if (c === "#") { if (atLineStart) comments.push(i); mode = "comment"; i++; continue; }
      if (atLineStart) {
        atLineStart = false;
        if (c === "[") {
          statements.push({ lineStart, start: i, header: true, top: false });
          if (firstHeader === null) firstHeader = lineStart;
          headerSeen = true;
          mode = "header";
          i++;
          continue;
        }
        statements.push({ lineStart, start: i, header: false, top: !headerSeen });
      }
      if (triple(i, '"')) { mode = "multiBasic"; i += 3; continue; }
      if (triple(i, "'")) { mode = "multiLiteral"; i += 3; continue; }
      if (c === '"') mode = "basic";
      else if (c === "'") mode = "literal";
      else if (c === "[" || c === "{") depth++;
      else if (c === "]" || c === "}") {
        if (depth === 0) broken = true;
        depth = Math.max(0, depth - 1);
      }
      i++;
    }
  }
  if (!headerSeen && dirty) topLevelEnd = n;
  // Back at the top level: no string, array or inline table left open. When not, the
  // rest describes a file TOML would not read either, and nothing may be written.
  const complete = !broken && depth === 0 && (mode === "code" || mode === "comment" || mode === "header");
  return { statements, topLevelEnd, firstHeader, complete, comments };
}

// One escape in a basic string, the backslash at t[i]: TOML 1.0's set plus 1.1's
// \e and \xHH. Returns [decoded, next index], or null when unreadable.
function tomlEscape(t, i) {
  const simple = { b: "\b", t: "\t", n: "\n", f: "\f", r: "\r", e: "\x1b", '"': '"', "\\": "\\" };
  const c = t[i + 1];
  if (c in simple) return [simple[c], i + 2];
  const len = { x: 2, u: 4, U: 8 }[c];
  if (!len) return null;
  const hex = t.slice(i + 2, i + 2 + len);
  if (!new RegExp(`^[0-9A-Fa-f]{${len}}$`).test(hex)) return null;
  const cp = parseInt(hex, 16);
  if (cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return null;
  return [String.fromCodePoint(cp), i + 2 + len];
}

// A one-line basic or literal string at t[i], decoded: { value, i } past its closing
// quote, or null when it is not one.
function tomlString(t, i) {
  const q = t[i];
  if (q !== '"' && q !== "'") return null;
  i++;
  let value = "";
  while (t[i] !== q) {
    if (i >= t.length || t[i] === "\n" || t[i] === "\r") return null;
    if (q === '"' && t[i] === "\\") {
      const e = tomlEscape(t, i);
      if (!e) return null;
      value += e[0]; i = e[1];
    } else value += t[i++];
  }
  return { value, i: i + 1 };
}

// A dotted key at t[i] up to `end`, which is left unread: { parts, i } or null.
function tomlKey(t, i, end) {
  const skip = () => { while (t[i] === " " || t[i] === "\t") i++; };
  const parts = [];
  for (;;) {
    skip();
    if (t[i] === '"' || t[i] === "'") {
      const r = tomlString(t, i);
      if (!r) return null;
      parts.push(r.value); i = r.i;
    } else {
      let part = "";
      while (i < t.length && /[A-Za-z0-9_-]/.test(t[i])) part += t[i++];
      if (!part) return null;
      parts.push(part);
    }
    skip();
    if (t[i] === ".") { i++; continue; }
    return t[i] === end ? { parts, i } : null;
  }
}

// The dotted key a statement assigns, or the one its header names, each part decoded
// (`"\u006eotify"` is `notify`). Null when it cannot be read; mirrors TOMLOutline.keyPath.
function tomlKeyPath(t, s) {
  if (!s.header) { const r = tomlKey(t, s.start, "="); return r && r.parts; }
  let i = s.start + 1;
  if (t[i] === "[") i++;
  const r = tomlKey(t, i, "]");
  return r && r.parts;
}

// The strings of an array a statement assigns to `key`, and the index just past the
// array: { values, end } or null. Read with the same quoting rules as everything else,
// so a `]` inside a quoted path is part of the path. Mirrors TOMLOutline.stringArray.
function tomlStringArray(t, s, key) {
  if (s.header) return null;
  const k = tomlKey(t, s.start, "=");
  if (!k || k.parts.length !== 1 || k.parts[0] !== key) return null;
  let i = k.i + 1;
  while (t[i] === " " || t[i] === "\t") i++;
  if (t[i] !== "[") return null;
  i++;
  const space = () => {
    for (;;) {
      if (t[i] === " " || t[i] === "\t" || t[i] === "\r" || t[i] === "\n") i++;
      else if (t[i] === "#") { while (i < t.length && t[i] !== "\n") i++; }
      else return;
    }
  };
  const values = [];
  for (;;) {
    space();
    if (t[i] === "]") return { values, end: i + 1 };
    const r = tomlString(t, i);
    if (!r) return null;
    values.push(r.value); i = r.i;
    space();
    if (t[i] === ",") { i++; continue; }
    return t[i] === "]" ? { values, end: i + 1 } : null;
  }
}

// `v` as a TOML basic string, quotes included.
function tomlBasicString(v) {
  let out = '"';
  for (const ch of v) {
    const cp = ch.codePointAt(0);
    if (ch === '"') out += '\\"';
    else if (ch === "\\") out += "\\\\";
    else if (ch === "\n") out += "\\n";
    else if (ch === "\r") out += "\\r";
    else if (ch === "\t") out += "\\t";
    else if (cp < 0x20 || cp === 0x7f) out += "\\u" + cp.toString(16).toUpperCase().padStart(4, "0");
    else out += ch;
  }
  return out + '"';
}

// Whether a top-level `key = …` would collide with something already there: the key
// itself, a dotted key or header under it (`key.x = 1`, `[key]`), or a key that
// cannot be read at all. Mirrors TOMLOutline.claims.
function tomlClaims(t, outline, key) {
  return outline.statements.some((s) => {
    if (!s.header && !s.top) return false;
    const p = tomlKeyPath(t, s);
    return p === null || p[0] === key;
  });
}

const codexEventLabel = (e) => e.replace(/(?!^)([A-Z])/g, "_$1").toLowerCase();
const tomlLineFrom = (t, i) => { const nl = t.indexOf("\n", i); return t.slice(i, nl < 0 ? t.length : nl); };

// A key statement's decoded dotted key and where its value starts, or null; mirrors
// TOMLOutline.assignment.
function tomlAssignment(t, s) {
  if (s.header) return null;
  const k = tomlKey(t, s.start, "=");
  if (!k) return null;
  let i = k.i + 1;
  while (t[i] === " " || t[i] === "\t") i++;
  return { key: k.parts, value: i };
}

// The pairs of an inline table at t[i] ({ a = "x", b = false }): each dotted key
// decoded, each value its decoded string or bare token, `quoted` telling them apart.
// Null when it cannot be read, including a nested array or table; mirrors
// TOMLOutline.inlineTable.
function tomlInlineTable(t, i) {
  if (t[i] !== "{") return null;
  i++;
  const blanks = () => { while (t[i] === " " || t[i] === "\t") i++; };
  blanks();
  const out = [];
  if (t[i] === "}") return out;
  for (;;) {
    const k = tomlKey(t, i, "=");
    if (!k) return null;
    i = k.i + 1;
    blanks();
    if (t[i] === '"' || t[i] === "'") {
      const r = tomlString(t, i);
      if (!r) return null;
      out.push({ key: k.parts, value: r.value, quoted: true });
      i = r.i;
    } else {
      let token = "";
      while (i < t.length && !/[,}\s\[{#]/.test(t[i])) token += t[i++];
      if (!token) return null;
      out.push({ key: k.parts, value: token, quoted: false });
    }
    blanks();
    if (t[i] === ",") { i++; blanks(); continue; }
    return t[i] === "}" ? out : null;
  }
}

// The first comment line reading exactly `first` and the next one after it reading
// exactly `last`: { from, to }, from the one's # to the other's end, or null. Only
// comments with a line to themselves count, so the same text inside a multi-line
// string is the string's; mirrors TOMLOutline.commentBlock.
function tomlCommentBlock(t, outline, first, last) {
  const line = (i) => tomlLineFrom(t, i).replace(/[ \t\r]+$/, "");
  const begin = outline.comments.find((i) => line(i) === first);
  if (begin === undefined) return null;
  const end = outline.comments.find((i) => i > begin && line(i) === last);
  return end === undefined ? null : { from: begin, to: end + line(end).length };
}

// AgentBar's handler for each event: { group, handler, tables }, positions counted
// the way Codex's discovery counts them and `tables` the text of its group and
// handler tables, which is what Codex's trust hash covers. A handler is AgentBar's when
// its decoded command runs codex/hook.js from AgentBar's hooks folder; a comment naming
// that path is not the command. Mirrors HookInstaller.codexAgentBarHandlers.
function codexAgentBarHandlers(t, outline) {
  const out = {}, group = {}, handler = {}, groupTable = {};
  let open = null, groupOpen = null;
  const close = (end) => {
    if (groupOpen) { groupTable[groupOpen.ev] = [groupOpen.start, end]; groupOpen = null; }
    const h = open;
    open = null;
    if (!h || !h.ours || h.ev in out) return;
    const g = groupTable[h.ev];
    const body = (g ? t.slice(g[0], g[1]) : "") + t.slice(h.start, end);
    const tables = body.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith("#")).join("\n");
    out[h.ev] = { group: group[h.ev], handler: handler[h.ev], tables };
  };
  for (const s of outline.statements) {
    if (s.header) {
      close(s.lineStart);
      if (!t.startsWith("[[", s.start)) continue;
      const p = tomlKeyPath(t, s);
      if (!p || p[0] !== "hooks" || p.length < 2) continue;
      const ev = p[1];
      if (p.length === 2) {
        group[ev] = (group[ev] ?? -1) + 1; handler[ev] = -1;
        delete groupTable[ev];
        groupOpen = { ev, start: s.lineStart };
      } else if (p.length === 3 && p[2] === "hooks" && group[ev] !== undefined) {
        handler[ev] += 1;
        open = { ev, start: s.lineStart, ours: false };
      }
    } else if (open && !open.ours) {
      const a = tomlAssignment(t, s);
      if (a && a.key.length === 1 && a.key[0] === "command" &&
          (tomlString(t, a.value)?.value ?? "").includes("/.agentbar/hooks/codex/hook.js")) open.ours = true;
    }
  }
  close(t.length);
  return out;
}

// Event -> the state key of AgentBar's own handler; mirrors Diagnostics.codexHookKeys.
function codexHookKeys(t, outline, cfgPath) {
  const out = {};
  for (const [ev, h] of Object.entries(codexAgentBarHandlers(t, outline))) {
    out[ev] = `${cfgPath}:${codexEventLabel(ev)}:${h.group}:${h.handler}`;
  }
  return out;
}

// `t` without Codex's [hooks.state] entries for `keys` (a Set), in any spelling: the
// [hooks.state."k"] table with its keys, or a "k".… / "k" = { … } line under
// [hooks.state]; mirrors HookInstaller.removingCodexTrust.
function codexRemoveTrust(t, keys) {
  const outline = tomlOutline(t);
  if (!outline.complete) return t;
  const cut = [];
  let table = [], dropping = null;
  for (const s of outline.statements) {
    if (s.header) {
      if (dropping !== null) { cut.push([dropping, s.lineStart]); dropping = null; }
      table = t.startsWith("[[", s.start) ? null : tomlKeyPath(t, s);
      if (table && table.length === 3 && table[0] === "hooks" && table[1] === "state" && keys.has(table[2])) dropping = s.lineStart;
      continue;
    }
    const a = dropping === null && table && tomlAssignment(t, s);
    if (!a) continue;
    const full = table.concat(a.key);
    if (full.length >= 3 && full[0] === "hooks" && full[1] === "state" && keys.has(full[2])) {
      const nl = t.indexOf("\n", a.value);
      cut.push([s.lineStart, nl < 0 ? t.length : nl + 1]);
    }
  }
  if (dropping !== null) cut.push([dropping, t.length]);
  let out = "", from = 0;
  for (const [x, y] of cut) { out += t.slice(from, x); from = y; }
  return out + t.slice(from);
}

// State key -> { trusted, disabled }, in any of TOML's spellings: [hooks.state."k"]
// tables, "k".trusted_hash dotted keys under [hooks.state], or "k" = { ... } inline
// tables; mirrors Diagnostics.codexHookStates.
function codexHookStates(t, outline) {
  const out = {};
  let table = [];
  for (const s of outline.statements) {
    if (s.header) { table = t.startsWith("[[", s.start) ? null : tomlKeyPath(t, s); continue; }
    const a = table && tomlAssignment(t, s);
    if (!a) continue;
    const full = table.concat(a.key);
    if (full.length < 3 || full[0] !== "hooks" || full[1] !== "state") continue;
    const value = tomlLineFrom(t, a.value);
    const st = out[full[2]] || { trusted: false, disabled: false };
    if (full.length === 4 && full[3] === "trusted_hash") st.trusted = true;
    else if (full.length === 4 && full[3] === "enabled") st.disabled = value.startsWith("false");
    else if (full.length === 3 && value.startsWith("{")) {
      // Read as a table, so a comment after it counts for nothing.
      const pairs = tomlInlineTable(t, a.value);
      if (!pairs) continue;
      for (const p of pairs) {
        if (p.key.length !== 1) continue;
        if (p.key[0] === "trusted_hash") st.trusted = true;
        if (p.key[0] === "enabled" && !p.quoted && p.value === "false") st.disabled = true;
      }
    } else continue;
    out[full[2]] = st;
  }
  return out;
}

// Whether AgentBar's own hook for `event` is trusted and enabled in this config: the
// key doctor checks, resolved the same way. False for a file that cannot be read to
// the end, so a caller deciding whether to stay quiet keeps reporting instead.
function codexHookTrusted(t, cfgPath, event) {
  const outline = tomlOutline(t);
  if (!outline.complete) return false;
  const key = codexHookKeys(t, outline, cfgPath)[event];
  const st = key && codexHookStates(t, outline)[key];
  return Boolean(st && st.trusted && !st.disabled);
}

// Whether AgentBar's own notify line is live: a top-level notify array naming its
// hooks path, in a file that reads to the end. A stray copy under a table is not
// live, and neither is a commented-out one; mirrors Diagnostics.codexNotifyWired.
function codexNotifyWired(t) {
  const outline = tomlOutline(t);
  if (!outline.complete) return false;
  return outline.statements.some((s) => {
    if (!s.top) return false;
    const a = tomlStringArray(t, s, "notify");
    return Boolean(a && a.values.some((v) => v.includes("/.agentbar/hooks/codex/")));
  });
}

module.exports = {
  tomlOutline, tomlStringArray, tomlBasicString, tomlClaims,
  codexHookKeys, codexHookStates, codexHookTrusted, codexNotifyWired,
  codexAgentBarHandlers, codexRemoveTrust, tomlCommentBlock, codexEventLabel,
};
