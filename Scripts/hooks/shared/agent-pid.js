// The pid a state row is pruned by: the agent that ran this hook.
//
// Claude Code runs a hook's command string through `/bin/sh -c`, and so may any
// host that takes a command line rather than an argv. bash and zsh exec a lone
// command, so the shell becomes node and `process.ppid` is the agent. dash —
// `/bin/sh` on Debian and Ubuntu — forks node instead, waits, and exits with it:
// `process.ppid` then names a process that is gone before any reader looks, and
// every row is pruned as dead the moment it is written.
//
// The installers put `exec` in front of the Claude commands, which fixes it at the
// source; this fixes it from the other end, for a command line nobody rewrote.
// Exactly one shell is stepped over, and only one that is running `-c`: a hook
// started by hand from an interactive shell keeps that shell as its parent.
//
// Linux only, because /proc makes it free. Elsewhere `/bin/sh` is bash or zsh,
// and finding out would cost a `ps` on every hook.
"use strict";

const fs = require("fs");
const path = require("path");

const SHELLS = new Set(["sh", "dash", "bash", "zsh", "ksh", "mksh", "ash", "busybox"]);

// Options before the first operand; `-c`, `-ec`, `-lc` and friends all count.
const runsCommandString = (argv) => {
  for (const a of argv.slice(1)) {
    if (!a.startsWith("-") || a === "--") return false;
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(a)) return true;
  }
  return false;
};

const parentOf = (pid) => {
  const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
  // comm sits in parentheses and may itself contain ") ", so cut at the last one.
  return Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1]) || 0;
};

module.exports = function agentPid() {
  const ppid = process.ppid;
  if (process.platform !== "linux" || !(ppid > 1)) return ppid;
  try {
    const argv = fs.readFileSync(`/proc/${ppid}/cmdline`, "utf8").split("\0");
    if (!SHELLS.has(path.basename(argv[0]).replace(/^-/, "")) || !runsCommandString(argv)) return ppid;
    const agent = parentOf(ppid);
    return agent > 1 ? agent : ppid;
  } catch {
    return ppid;
  }
};
