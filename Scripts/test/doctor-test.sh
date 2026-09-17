#!/bin/bash
# Tests `agentbar doctor` against throwaway HOMEs. Everything an integration can
# fail at fails *silently* in real life — a hook that is not wired is an absence,
# not an error — so these assert that each silent failure comes back named, under
# the check id the macOS app uses for the same thing (docs/diagnostics.md).
set -uo pipefail
cd "$(dirname "$0")/../.."
CLI="Scripts/cli/agentbar"
NODE="${NODE:-node}"

# install-hooks honors CLAUDE_CONFIG_DIR; an inherited value would point the
# assertions at the runner's real Claude config.
unset CLAUDE_CONFIG_DIR AGENTBAR_FORCE_APP AGENTBAR_APPROVAL_TIMEOUT

pass=0; fail=0
check() {
  if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi
}

TESTROOT="$(mktemp -d)"
cleanup() { chmod -R u+w "$TESTROOT" 2>/dev/null; /bin/rm -rf "$TESTROOT"; }
trap cleanup EXIT

# A counter, not $RANDOM: two draws out of 32768 collide about once in three
# hundred runs, and a "fresh" home that is really a previous one still holds its
# files — which fails exactly the checks that assert a directory is empty, on a
# machine nobody is watching. (Caught in CI: "codex non-complete event ignored".)
HOME_SEQ=0
fresh_home() {
  HOME_SEQ=$((HOME_SEQ + 1))
  export HOME="$TESTROOT/home.$$.$HOME_SEQ"
  mkdir -p "$HOME/.agentbar/state.d" "$HOME/.agentbar/requests.d" "$HOME/.agentbar/answers.d"
}

# The status of one check id, read out of --json so the wording stays free to change.
status_of() { # $1 id
  "$CLI" doctor --json | "$NODE" -e '
let s = "";
process.stdin.on("data", (d) => s += d).on("end", () => {
  const c = JSON.parse(s).find((x) => x.id === process.argv[1]);
  process.stdout.write(c ? c.status : "absent");
});' "$1"
}

# --- a clean install reports clean
fresh_home
mkdir -p "$HOME/.codex"
"$CLI" install-hooks >/dev/null 2>&1
check "wired agent passes"              '[ "$(status_of agent.codex.wired)" = ok ]'
check "directories pass"                '[ "$(status_of dirs.state.d)" = ok ]'
check "hook scripts pass"               '[ "$(status_of hooks.copied)" = ok ]'
# Neither Cursor nor Antigravity is here, and the installer only pins a script when
# it wires that agent — so an unpinned copy of cursor.js is not a problem to solve.
check "shebang skipped without cursor"  '[ "$(status_of hooks.shebang)" = skipped ]'
# An agent you don't have is not a problem to solve.
check "absent agent is skipped"         '[ "$(status_of agent.qwen)" = skipped ]'
check "absent agent has no wired row"   '[ "$(status_of agent.qwen.wired)" = absent ]'

# --- the headline: an interpreter that moved
# Every hook is a node script, so a node that is gone means every hook silently
# never runs. Nothing reports that today except this.
sed -i.bak "s|notify = \[\"[^\"]*\"|notify = [\"$HOME/.nvm/versions/node/v0.0.0/bin/node\"|" \
  "$HOME/.codex/config.toml"
check "dead interpreter is a failure"   '[ "$(status_of agent.codex.interpreter)" = fail ]'
check "dead interpreter names the path" '"$CLI" doctor | grep -q "v0.0.0"'
check "dead interpreter offers a fix"   '"$CLI" doctor | grep -q "install-hooks"'

# --- an agent installed but not wired
fresh_home
mkdir -p "$HOME/.cursor"
echo '{"version":1}' > "$HOME/.cursor/hooks.json"
check "unwired agent is a failure"      '[ "$(status_of agent.cursor.wired)" = fail ]'

# --- with Cursor present, its shebang has to name a real node: a GUI-launched
# Cursor inherits the launchd PATH, which usually has no node on it, so
# `#!/usr/bin/env node` is a hook that silently never fires.
"$CLI" install-hooks >/dev/null 2>&1
check "pinned shebang passes"           '[ "$(status_of hooks.shebang)" = ok ]'
printf '#!/usr/bin/env node\n' > "$HOME/.agentbar/hooks/cursor/cursor.js"
check "unpinned shebang is a warning"   '[ "$(status_of hooks.shebang)" = warn ]'

# --- the escaped-slash trap
# JSONSerialization escapes forward slashes, so every config the macOS app writes
# reads "\/.agentbar\/hooks\/..." on disk. Searching the raw text for the plain
# marker reported a perfectly wired Mac as entirely unwired.
fresh_home
mkdir -p "$HOME/.cursor"
printf '{"hooks":{"stop":[{"command":"\\/Users\\/x\\/.agentbar\\/hooks\\/cursor\\/cursor.js"}]}}' \
  > "$HOME/.cursor/hooks.json"
check "escaped slashes still count"     '[ "$(status_of agent.cursor.wired)" = ok ]'

# --- a config the installer refuses to touch
fresh_home
mkdir -p "$HOME/.gemini"
printf '{"theme": "dark" // mine\n}' > "$HOME/.gemini/settings.json"
check "unparseable config is named"     '[ "$(status_of agent.gemini.parseable)" = fail ]'

# --- directories that exist but cannot be written to
# The failure hooks hit most often, and the one they have nowhere to report.
fresh_home
chmod a-w "$HOME/.agentbar/state.d"
check "unwritable dir is a failure"     '[ "$(status_of dirs.state.d)" = fail ]'
chmod u+w "$HOME/.agentbar/state.d"
rmdir "$HOME/.agentbar/answers.d"
check "missing dir is a failure"        '[ "$(status_of dirs.answers.d)" = fail ]'

# --- last seen comes from history.jsonl, because state.d forgets
fresh_home
mkdir -p "$HOME/.codex"
"$CLI" install-hooks >/dev/null 2>&1
# History only starts when a frontend starts keeping it, so a freshly updated
# machine is blank everywhere — and nothing is wrong.
check "no record yet is not a problem"  '[ "$(status_of agent.codex.lastSeen)" = ok ]'
printf '{"agent":"codex","sessionId":"a","state":"done","endedAt":%s}\n' \
  "$(( $(date +%s) - 259200 ))" > "$HOME/.agentbar/history.jsonl"
check "last seen reads the history"     '[ "$(status_of agent.codex.lastSeen)" = ok ]'
check "last seen counts the days"       '"$CLI" doctor | grep -q "3 days ago"'
# Wired and silent for a fortnight is the shape of a broken integration that passes
# every other check: the hooks are in place and simply never fire.
printf '{"agent":"codex","sessionId":"a","state":"done","endedAt":%s}\n' "$(( $(date +%s) - 1500000 ))" \
  > "$HOME/.agentbar/history.jsonl"
check "long silence is a warning"       '[ "$(status_of agent.codex.lastSeen)" = warn ]'

# --- --json is what goes into a bug report
check "json carries id and status"      '"$CLI" doctor --json | grep -q "\"id\": \"hooks.copied\"" && "$CLI" doctor --json | grep -q "\"status\""'
# A diagnostic that changes what it diagnoses is worse than none.
check "doctor leaves state.d alone"     '[ -z "$(ls -A "$HOME/.agentbar/state.d")" ]'
check "doctor leaves no probe behind"   '[ -z "$(ls -A "$HOME/.agentbar/requests.d")" ]'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
