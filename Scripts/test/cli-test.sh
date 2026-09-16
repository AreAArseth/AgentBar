#!/bin/bash
# Tests Scripts/cli/agentbar against a throwaway HOME: status/requests listing,
# approve/deny answers, pruning rules, waybar output, install-hooks safety.
set -uo pipefail
cd "$(dirname "$0")/../.."
CLI="Scripts/cli/agentbar"
NODE="${NODE:-node}"

# install-hooks honors CLAUDE_CONFIG_DIR — a value inherited from the runner's
# shell would make the test wire hooks into the runner's REAL Claude config,
# pointing at this suite's throwaway temp dir (learned the hard way).
unset CLAUDE_CONFIG_DIR AGENTBAR_FORCE_APP AGENTBAR_APPROVAL_TIMEOUT

pass=0; fail=0
check() {
  if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi
}

TESTROOT="$(mktemp -d)"
trap 'rm -rf "$TESTROOT"' EXIT

fresh_home() {
  export HOME="$TESTROOT/home.$$.$RANDOM"
  mkdir -p "$HOME/.agentbar/state.d" "$HOME/.agentbar/requests.d" "$HOME/.agentbar/answers.d"
}

seed_session() { # $1 id, $2 state, $3 pid
  printf '{"agent":"claude","state":"%s","label":"x","project":"proj","cwd":"","sessionId":"%s","pid":%s,"started":true,"ts":%s}' \
    "$2" "$1" "$3" "$(date +%s)" > "$HOME/.agentbar/state.d/$1.json"
}

seed_request() { # $1 name, $2 hookPid
  printf '{"sessionId":"s1","agent":"claude","toolName":"Bash","display":"Bash: ls","toolInputPretty":"{}","ruleSuggestion":{"type":"addRules"},"pid":%s,"hookPid":%s,"ts":%s}' \
    "$2" "$2" "$(date +%s)" > "$HOME/.agentbar/requests.d/$1.json"
}

# --- status: live session listed, dead pid pruned, started:false hidden
fresh_home
seed_session live tool $$
seed_session deadpid tool 999999
printf '{"agent":"claude","state":"idle","pid":%s,"started":false,"ts":%s}' $$ "$(date +%s)" > "$HOME/.agentbar/state.d/unstarted.json"
OUT="$("$CLI" status --json)"
check "status lists live session"      'echo "$OUT" | grep -q "\"id\": \"live\""'
check "status hides unstarted"         '! echo "$OUT" | grep -q unstarted'
check "status prunes dead pid"         '[ ! -f "$HOME/.agentbar/state.d/deadpid.json" ]'

# --- history: state.d is a live set, so an ended session has to be recorded
# somewhere or nothing can say when an agent last reported anything.
fresh_home
seed_session h1 tool $$
"$CLI" status >/dev/null 2>&1
check "history first run is a baseline" '[ ! -f "$HOME/.agentbar/history.jsonl" ]'
rm -f "$HOME/.agentbar/state.d/h1.json"
"$CLI" status >/dev/null 2>&1
check "vanished session recorded"      'grep -q "\"sessionId\":\"h1\"" "$HOME/.agentbar/history.jsonl"'
"$CLI" status >/dev/null 2>&1
check "vanished session not repeated"  '[ "$(wc -l < "$HOME/.agentbar/history.jsonl" | tr -d " ")" = 1 ]'
# A finished turn is recorded while the row is still readable; the row lingering
# in `done` for hours must not append a line per tick.
fresh_home
seed_session h2 tool $$
"$CLI" status >/dev/null 2>&1
seed_session h2 done $$
"$CLI" status >/dev/null 2>&1
"$CLI" status >/dev/null 2>&1
check "finished turn recorded once"    '[ "$(grep -c "\"sessionId\":\"h2\"" "$HOME/.agentbar/history.jsonl")" = 1 ]'
check "finished turn keeps its state"  'grep -q "\"state\":\"done\"" "$HOME/.agentbar/history.jsonl"'
# `idle` is where a session waits between turns — not an ending.
fresh_home
seed_session h3 tool $$
"$CLI" status >/dev/null 2>&1
seed_session h3 idle $$
"$CLI" status >/dev/null 2>&1
check "idle is not an ending"          '[ ! -f "$HOME/.agentbar/history.jsonl" ]'

# --- history: the day's account, read back out of history.jsonl
fresh_home
NOW="$(date +%s)"
{
  printf '{"agent":"claude","sessionId":"h1","project":"Alpha","state":"done","startedAt":%s,"endedAt":%s}\n' "$((NOW-3600))" "$((NOW-1800))"
  printf '{"agent":"codex","sessionId":"h2","project":"Beta","state":"error","startedAt":%s,"endedAt":%s}\n' "$((NOW-900))" "$((NOW-300))"
  # Yesterday: a digest called Today that counts backwards 24h from whenever you
  # look at it is not a day.
  printf '{"agent":"claude","sessionId":"h3","project":"Old","state":"done","startedAt":%s,"endedAt":%s}\n' "$((NOW-200000))" "$((NOW-190000))"
} > "$HOME/.agentbar/history.jsonl"
OUT="$("$CLI" history)"
check "history lists today"            'echo "$OUT" | grep -q Alpha && echo "$OUT" | grep -q Beta'
check "history excludes yesterday"     '! echo "$OUT" | grep -q Old'
check "history counts failures"        'echo "$OUT" | grep -q "1 failed"'
check "history totals the durations"   'echo "$OUT" | grep -q "40m"'
check "history --days reaches back"    '"$CLI" history --days 5 | grep -q Old'
check "history --json is machine-readable" '"$CLI" history --json | grep -q "\"sessionId\": \"h2\""'
# A duration is a LENGTH, not an age: passing one to the live-row helper renders
# decades, because that one subtracts its argument from now.
check "history duration is not an age" '! echo "$OUT" | grep -qE "[0-9]{4,}h"'
fresh_home
check "history with no record says so" '"$CLI" history | grep -qi "nothing"'

# --- history: what a session cost, and what moved in the repo. Both are optional
# in the protocol, and "absent" has to survive as absent — a zero would be quoted.
fresh_home
NOW="$(date +%s)"
{
  printf '{"agent":"claude","sessionId":"w1","project":"Alpha","state":"done","startedAt":%s,"endedAt":%s,"weight":{"in":1330,"out":622024,"cacheWrite":1453897,"cacheRead":220795232,"src":"claude-transcript"},"change":{"files":7,"added":210,"removed":80,"base":"3a30264"}}\n' "$((NOW-3600))" "$((NOW-1800))"
  printf '{"agent":"gemini","sessionId":"w2","project":"Beta","state":"done","startedAt":%s,"endedAt":%s}\n' "$((NOW-900))" "$((NOW-300))"
} > "$HOME/.agentbar/history.jsonl"
OUT="$("$CLI" history)"
# 1330 + 622024 + 1453897 = 2_077_251. Cache reads are stored and never shown:
# including them would make the same session read as 222.9M.
check "history shows the token total"  'echo "$OUT" | grep -q "2.1M"'
check "history hides cache reads"      '! echo "$OUT" | grep -q "222"'
check "history shows what changed"     'echo "$OUT" | grep -q "7 files +210"'
# Seven of the ten agents publish nothing to measure, so a partial total is the
# normal case — presenting it as the day's spend would be wrong most days.
check "partial token total says so"    'echo "$OUT" | grep -q "tokens across 1"'
check "an unmeasured row stays blank"  '! echo "$OUT" | grep -E "Beta.*[0-9]+(k|M)"'

# An agent that keeps a readable number gets one written for it. Claude Code's
# session id IS its transcript's file name, which is what makes the lookup exact.
fresh_home
PROJ="$HOME/.claude/projects/-tmp-cliweight"
mkdir -p "$PROJ"
{
  printf '{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":900}}}\n'
  # The same message again — one message spans several transcript lines, each
  # repeating the usage object. Counting lines would double the answer.
  printf '{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":900}}}\n'
} > "$PROJ/cw1.jsonl"
mkdir -p "$HOME/.agentbar/state.d"
printf '{"agent":"claude","state":"tool","started":true,"ts":%s,"pid":%s,"cwd":"/tmp/cliweight","project":"CliWeight","sessionId":"cw1"}' "$(date +%s)" "$$" \
  > "$HOME/.agentbar/state.d/cw1.json"
"$CLI" status >/dev/null 2>&1
printf '{"agent":"claude","state":"done","started":true,"ts":%s,"pid":%s,"cwd":"/tmp/cliweight","project":"CliWeight","sessionId":"cw1"}' "$(date +%s)" "$$" \
  > "$HOME/.agentbar/state.d/cw1.json"
"$CLI" status >/dev/null 2>&1
check "weight is recorded for claude"  'grep -q "\"src\":\"claude-transcript\"" "$HOME/.agentbar/history.jsonl"'
check "duplicate lines counted once"   'grep -q "\"out\":20" "$HOME/.agentbar/history.jsonl"'

# An agent with nothing on disk must leave the field out entirely rather than
# writing zeroes somebody then reads as "it cost nothing".
fresh_home
seed_session nw tool $$
"$CLI" status >/dev/null 2>&1
rm -f "$HOME/.agentbar/state.d/nw.json"
"$CLI" status >/dev/null 2>&1
check "no source means no weight key"  '! grep -q "weight" "$HOME/.agentbar/history.jsonl"'
check "no repo means no change key"    '! grep -q "change" "$HOME/.agentbar/history.jsonl"'

# --- requests + approve/deny
fresh_home
seed_request r1 $$
OUT="$("$CLI" requests --json)"
check "requests lists pending"         'echo "$OUT" | grep -q "Bash: ls"'
"$CLI" approve >/dev/null
check "approve writes allow answer"    'grep -q "\"behavior\":\"allow\"" "$HOME/.agentbar/answers.d/r1.json"'
# Answers name the hook they are for — request names repeat within a turn, and
# the hook discards answers aimed at a predecessor (docs/protocol.md).
check "approve stamps hookPid"         'grep -q "\"hookPid\":'"$$"'" "$HOME/.agentbar/answers.d/r1.json"'
rm -f "$HOME/.agentbar/answers.d/r1.json"
"$CLI" approve --always >/dev/null
check "approve --always carries rule"  'grep -q "\"behavior\":\"always\"" "$HOME/.agentbar/answers.d/r1.json" && grep -q addRules "$HOME/.agentbar/answers.d/r1.json"'
rm -f "$HOME/.agentbar/answers.d/r1.json"
"$CLI" deny >/dev/null
check "deny writes deny answer"        'grep -q "\"behavior\":\"deny\"" "$HOME/.agentbar/answers.d/r1.json"'
check "dead-hook request pruned"       'seed_request dead 999999; "$CLI" requests >/dev/null; [ ! -f "$HOME/.agentbar/requests.d/dead.json" ]'

# --- questions: rendering, queue priority, the answer command
seed_question() { # $1 name, $2 ts, $3 multiSelect
  printf '{"sessionId":"s2","agent":"claude","toolName":"AskUserQuestion","display":"Question: Which color?","toolInputPretty":"{}","context":{"kind":"question","questions":[{"question":"Which color?","header":"Color","multiSelect":%s,"options":[{"label":"Red","description":"warm"},{"label":"Blue","description":"cool"}]}]},"pid":%s,"hookPid":%s,"ts":%s}' \
    "$3" $$ $$ "$2" > "$HOME/.agentbar/requests.d/$1.json"
}
fresh_home
NOW=$(date +%s)
seed_request perm $$; python3 - "$HOME/.agentbar/requests.d/perm.json" $((NOW-5)) <<'PY'
import json, sys
f, ts = sys.argv[1], int(sys.argv[2])
j = json.load(open(f)); j["ts"] = ts; json.dump(j, open(f, "w"))
PY
seed_question quest "$NOW" false
check "requests renders question options" '"$CLI" requests | grep -q "1) Red"'
"$CLI" approve >/dev/null 2>&1
check "bare approve skips the question"   'grep -q "\"behavior\":\"allow\"" "$HOME/.agentbar/answers.d/perm.json" && [ ! -f "$HOME/.agentbar/answers.d/quest.json" ]'
rm -f "$HOME/.agentbar/answers.d/perm.json"
check "explicit index on question errors" '! "$CLI" approve 1 >/dev/null 2>&1'
"$CLI" answer Blue >/dev/null
check "answer by label"                   'grep -q "\"answers\":\[\[\"Blue\"\]\]" "$HOME/.agentbar/answers.d/quest.json"'
check "answer stamps hookPid"             'grep -q "\"hookPid\":'"$$"'" "$HOME/.agentbar/answers.d/quest.json"'
rm -f "$HOME/.agentbar/answers.d/quest.json"
"$CLI" answer 1 Red >/dev/null   # explicit request index 1 (the question), option by name
check "answer with explicit index"        'grep -q "\"answers\":\[\[\"Red\"\]\]" "$HOME/.agentbar/answers.d/quest.json"'
rm -f "$HOME/.agentbar/answers.d/quest.json"
check "answer rejects unknown label"      '! "$CLI" answer Green >/dev/null 2>&1'
check "answer rejects two on single-select" '! "$CLI" answer Red Blue >/dev/null 2>&1'
seed_question multi "$((NOW+1))" true
"$CLI" answer Red Blue >/dev/null
check "multiSelect takes several labels"  'grep -q "\"answers\":\[\[\"Red\",\"Blue\"\]\]" "$HOME/.agentbar/answers.d/multi.json"'

# --- waybar: heartbeat + JSON shape
fresh_home
seed_session live permission $$
OUT="$("$CLI" waybar)"
check "waybar emits permission class"  'echo "$OUT" | grep -q "\"class\":\"permission\""'
check "waybar writes heartbeat"        'grep -q "\"ts\":" "$HOME/.agentbar/watcher.json"'
# A session waiting on an AskUserQuestion is waiting on the human like a
# permission is — it must not render as a quiet "idle".
fresh_home
seed_session ask question $$
OUT="$("$CLI" waybar)"
check "waybar surfaces question class" 'echo "$OUT" | grep -q "\"class\":\"question\""'

# --- heartbeat makes the permission hook block (watcher path, no app)
fresh_home
"$CLI" waybar >/dev/null   # fresh heartbeat
unset AGENTBAR_FORCE_APP
printf '{"session_id":"s1","prompt_id":"p1","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp"}' |
  AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" Scripts/hooks/claude/permission.js > "$TESTROOT/hookout" &
HOOKPID=$!
REQ=""
for _ in $(seq 50); do
  REQ="$(ls "$HOME/.agentbar/requests.d/" 2>/dev/null | head -1)"
  [ -n "$REQ" ] && break
  sleep 0.1
done
check "hook blocks on CLI heartbeat"   '[ -n "$REQ" ]'
"$CLI" approve >/dev/null 2>&1
wait "$HOOKPID"
check "CLI answer reaches the hook"    'grep -q "\"behavior\":\"allow\"" "$TESTROOT/hookout"'

# --- install-hooks: wiring, idempotence, unparseable config untouched
fresh_home
mkdir -p "$HOME/.gemini" "$HOME/.cursor" "$HOME/.claude" "$HOME/.qwen" "$HOME/.codex" "$HOME/.config/opencode" "$HOME/.copilot"
echo '{"theme":"dark"}' > "$HOME/.gemini/settings.json"
# A hooks file of the user's own, next to ours: Copilot loads every *.json in the
# dir, so ours must be a separate file and theirs must come back untouched.
mkdir -p "$HOME/.copilot/hooks"
echo '{"version":1,"hooks":{"SessionStart":[{"type":"command","bash":"true"}]}}' > "$HOME/.copilot/hooks/mine.json"
"$CLI" install-hooks >/dev/null 2>&1
check "gemini wired, existing kept"    'grep -q BeforeAgent "$HOME/.gemini/settings.json" && grep -q theme "$HOME/.gemini/settings.json"'
check "cursor wired with pinned node"  'grep -q afterAgentResponse "$HOME/.cursor/hooks.json" && head -1 "$HOME/.agentbar/hooks/cursor/cursor.js" | grep -qv "env node"'
check "claude wired"                   'grep -q PermissionRequest "$HOME/.claude/settings.json"'
check "qwen wired with its identity"   'grep -q StopFailure "$HOME/.qwen/settings.json" && grep -q AGENTBAR_AGENT "$HOME/.qwen/settings.json"'
check "codex notify wired"             'grep -q "/.agentbar/hooks/codex/" "$HOME/.codex/config.toml"'
check "opencode plugin installed"      '[ -f "$HOME/.config/opencode/plugins/agentbar.js" ]'
check "copilot wired with its identity" 'grep -q ErrorOccurred "$HOME/.copilot/hooks/agentbar.json" && grep -q "\"copilot\"" "$HOME/.copilot/hooks/agentbar.json"'
# exec+args, never a shell line: a bash wrapper would make the hook'"'"'s parent a
# shell that exits at once, and ppid is what prunes dead rows.
check "copilot runs node directly"     'grep -q "\"exec\"" "$HOME/.copilot/hooks/agentbar.json" && ! grep -q "\"bash\"" "$HOME/.copilot/hooks/agentbar.json"'
# Copilot's permissionRequest blocks and decides — that is remote Allow/Deny. Its
# timeout must sit ABOVE the hook's own 600s wait, or Copilot kills the hook
# mid-wait instead of letting it fall through to the terminal prompt.
check "copilot approval wired"        'grep -q "permissionRequest" "$HOME/.copilot/hooks/agentbar.json"'
APPROVAL_HOOK="$("$NODE" -e '
const fs=require("fs"),os=require("os"),path=require("path");
const h=JSON.parse(fs.readFileSync(path.join(os.homedir(),".copilot/hooks/agentbar.json"),"utf8"))
  .hooks.permissionRequest[0];
process.stdout.write([h.timeoutSec, h.exec ? "exec" : "shell", path.basename(h.args[0])].join(" "));')"
check "copilot approval outlasts hook" '[ "$(echo "$APPROVAL_HOOK" | cut -d" " -f1)" -gt 600 ]'
check "copilot approval runs node directly" '[ "$APPROVAL_HOOK" = "630 exec permission.js" ]'
check "copilot leaves other hook files" 'grep -q "\"bash\":\"true\"" "$HOME/.copilot/hooks/mine.json"'
# The node path written into every config must name the SAME interpreter this CLI
# runs on, and must prefer a stable alias over the version-pinned path execPath
# resolves to — a hook config outlives the next node upgrade, and a hook whose
# interpreter has moved silently never fires.
WROTE_NODE="$("$NODE" -e '
const fs=require("fs"),os=require("os"),path=require("path");
const cfg=JSON.parse(fs.readFileSync(path.join(os.homedir(),".copilot/hooks/agentbar.json"),"utf8"));
process.stdout.write(cfg.hooks.SessionStart[0].exec);')"
check "node path is executable"        '[ -x "$WROTE_NODE" ]'
check "node path is the same binary"   '[ "$("$NODE" -e "console.log(require(\"fs\").realpathSync(process.argv[1]))" "$WROTE_NODE")" = "$("$NODE" -e "console.log(require(\"fs\").realpathSync(process.execPath))")" ]'
# When a stable alias for this node exists, it must have been chosen over execPath.
STABLE="$("$NODE" -e '
const fs=require("fs"),os=require("os"),path=require("path");
const real=(p)=>{try{return fs.realpathSync(p)}catch{return null}};
const self=real(process.execPath);
const c=["/usr/bin/node","/usr/local/bin/node","/opt/homebrew/bin/node",path.join(os.homedir(),".local/bin/node")]
  .find((x)=>x!==process.execPath&&real(x)===self);
process.stdout.write(c||"");')"
check "stable node alias preferred"    '[ -z "$STABLE" ] || [ "$WROTE_NODE" = "$STABLE" ]'
SNAP="$(cat "$HOME/.gemini/settings.json")"
QWEN_SNAP="$(cat "$HOME/.qwen/settings.json")"
COPILOT_SNAP="$(cat "$HOME/.copilot/hooks/agentbar.json")"
CODEX_SNAP="$(cat "$HOME/.codex/config.toml")"
"$CLI" install-hooks >/dev/null 2>&1
check "install-hooks idempotent"       '[ "$SNAP" = "$(cat "$HOME/.gemini/settings.json")" ] && [ "$QWEN_SNAP" = "$(cat "$HOME/.qwen/settings.json")" ] && [ "$COPILOT_SNAP" = "$(cat "$HOME/.copilot/hooks/agentbar.json")" ] && [ "$CODEX_SNAP" = "$(cat "$HOME/.codex/config.toml")" ]'
# A node that has moved (nvm upgrade, Cellar bump) must be repaired on the next run.
# Codex is the one config that used to stop at the marker and never re-check, so a
# stale interpreter there was permanent: every other agent healed on the next run
# and Codex stayed broken until someone hand-edited the TOML.
sed -i.bak "s|^notify = \[\"[^\"]*\"|notify = [\"$HOME/.nvm/versions/node/v0.0.0/bin/node\"|" "$HOME/.codex/config.toml"
check "codex dead node path seeded"    'grep -q "v0.0.0" "$HOME/.codex/config.toml"'
"$CLI" install-hooks >/dev/null 2>&1
check "codex dead node path repaired"  '! grep -q "v0.0.0" "$HOME/.codex/config.toml" && grep -q "/.agentbar/hooks/codex/" "$HOME/.codex/config.toml"'
check "codex repair keeps one notify"  '[ "$(grep -c "^notify = " "$HOME/.codex/config.toml")" = 1 ]'
echo '{broken' > "$HOME/.gemini/settings.json"
"$CLI" install-hooks >/dev/null 2>&1
check "unparseable config untouched"   '[ "$(cat "$HOME/.gemini/settings.json")" = "{broken" ]'
CLAUDE_CONFIG_DIR="$HOME/.claude-custom" "$CLI" install-hooks >/dev/null 2>&1
check "CLAUDE_CONFIG_DIR wired (contained)" 'grep -q PermissionRequest "$HOME/.claude-custom/settings.json"'


# --- plan requests: the hook can't carry a plan approval, so the CLI must say so
seed_plan() { # $1 name
  printf '{"sessionId":"s3","agent":"claude","toolName":"ExitPlanMode","display":"Plan ready for review","toolInputPretty":"{}","context":{"kind":"plan","plan":"## Plan\\n1. Edit auth.ts\\n2. Run tests"},"pid":%s,"hookPid":%s,"ts":%s}' \
    $$ $$ "$(date +%s)" > "$HOME/.agentbar/requests.d/$1.json"
}
fresh_home
seed_plan plan1
check "requests renders the plan"          '"$CLI" requests | grep -q "Edit auth.ts"'
check "requests explains plan semantics"   '"$CLI" requests | grep -q "keep planning"'
check "approve on a plan refuses"          '! "$CLI" approve >/dev/null 2>&1 && [ ! -f "$HOME/.agentbar/answers.d/plan1.json" ]'
"$CLI" deny >/dev/null
check "deny on a plan = keep planning"     'grep -q "\"behavior\":\"deny\"" "$HOME/.agentbar/answers.d/plan1.json"'

# --- answer: multi-question calls can't be answered from a one-liner
fresh_home
printf '{"sessionId":"s4","agent":"claude","toolName":"AskUserQuestion","display":"Question: Which?","toolInputPretty":"{}","context":{"kind":"question","questions":[{"question":"Which layers?","header":"Layers","multiSelect":true,"options":[{"label":"API"},{"label":"UI"}]},{"question":"Ship?","header":"","multiSelect":false,"options":[{"label":"Yes"},{"label":"No"}]}]},"pid":%s,"hookPid":%s,"ts":%s}' \
  $$ $$ "$(date +%s)" > "$HOME/.agentbar/requests.d/multiq.json"
check "answer refuses multi-question calls" '! "$CLI" answer API >/dev/null 2>&1 && [ ! -f "$HOME/.agentbar/answers.d/multiq.json" ]'

# --- waybar: the remaining classes
fresh_home
OUT="$("$CLI" waybar)"
check "waybar empty class with no sessions" 'echo "$OUT" | grep -q "\"class\":\"empty\""'
seed_session busy tool $$
OUT="$("$CLI" waybar)"
check "waybar working class"                'echo "$OUT" | grep -q "\"class\":\"working\"" && echo "$OUT" | grep -q "● 1"'
seed_session waiting permission $$
OUT="$("$CLI" waybar)"
check "waybar permission outranks working"  'echo "$OUT" | grep -q "\"class\":\"permission\""'

# --- status text: a failed turn reads as failed, a question as waiting
fresh_home
printf '{"agent":"claude","state":"error","label":"provider returned 429","project":"proj","pid":%s,"started":true,"ts":%s}' $$ "$(date +%s)" > "$HOME/.agentbar/state.d/err.json"
check "status shows failed + reason"        '"$CLI" status | grep -q "failed" && "$CLI" status | grep -q "provider returned 429"'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
