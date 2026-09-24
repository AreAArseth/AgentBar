#!/bin/bash
# Tests that a hook run through `sh -c` records the agent's pid, not the shell's.
#
# Claude Code runs every hook command through /bin/sh -c. bash and zsh exec a
# lone command; dash — /bin/sh on Debian and Ubuntu — forks it and exits with it,
# so a hook that takes its ppid names a process that is already gone and every
# reader prunes the row as dead. Here a small node "agent" runs each hook the way
# the host does, under dash when it is installed and does not exec, or under a
# stand-in /bin/sh that forks the same way, and the row must name the agent.
set -uo pipefail
cd "$(dirname "$0")/../.."
CLI="Scripts/cli/agentbar"
NODE="${NODE:-node}"
unset CLAUDE_CONFIG_DIR AGENTBAR_FORCE_APP AGENTBAR_APPROVAL_TIMEOUT

pass=0; fail=0; skip=0
check() {
  if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi
}
# The script-side fix reads /proc; elsewhere only the installers' `exec` applies.
linux_check() {
  if [ "$(uname)" = "Linux" ]; then check "$@"; else echo "skip $1 (needs /proc)"; skip=$((skip+1)); fi
}

TESTROOT="$(mktemp -d)"
trap 'rm -rf "$TESTROOT"' EXIT
HOME_SEQ=0
fresh_home() {
  HOME_SEQ=$((HOME_SEQ + 1))
  export HOME="$TESTROOT/home.$$.$HOME_SEQ"
  mkdir -p "$HOME/.agentbar/state.d" "$HOME/.agentbar/requests.d" "$HOME/.agentbar/answers.d"
}

# The agent: runs `$SH -c <command>` with the payload on stdin, waits for it the
# way Claude Code does, and prints its own pid — the only pid a row may name.
AGENT="$TESTROOT/agent.js"
cat > "$AGENT" <<'EOF'
const cp = require("child_process");
const [sh, cmd, payload] = process.argv.slice(2);
cp.spawnSync(sh, ["-c", cmd], { input: payload || "", stdio: ["pipe", "ignore", "ignore"] });
process.stdout.write(String(process.pid));
EOF
# A /bin/sh that forks a lone command instead of becoming it, which is what dash
# does. `exec` in the command still replaces it, exactly as it replaces dash.
STANDIN="$TESTROOT/nonexec-sh"
cat > "$STANDIN" <<'EOF'
#!/bin/bash
[ "$1" = "-c" ] || exit 2
exec bash -c "$2"$'\n''exit $?'
EOF
chmod +x "$STANDIN"

# "<ppid of a lone command> <the pid that ran the shell>": equal means it exec'd.
lone_parent() {
  "$NODE" -e '
    const cp = require("child_process");
    cp.spawnSync(process.argv[1], ["-c", `"${process.execPath}" -e "process.stdout.write(String(process.ppid))"`],
                 { stdio: ["ignore", "inherit", "ignore"] });
    process.stdout.write(" " + process.pid);' "$1"
}
SH=""
if command -v dash >/dev/null 2>&1; then
  read -r P A <<<"$(lone_parent "$(command -v dash)")"
  [ "$P" != "$A" ] && SH="$(command -v dash)"
fi
[ -n "$SH" ] || SH="$STANDIN"
echo "# shell under test: $SH"
read -r P A <<<"$(lone_parent "$SH")"
check "the shell forks a lone command (else this suite proves nothing)" '[ -n "$P" ] && [ "$P" != "$A" ]'

row_pid() { "$NODE" -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).pid))' "$1" 2>/dev/null; }

# --- installed commands: what install-hooks writes, run the way Claude runs it
fresh_home
mkdir -p "$HOME/.claude"
"$CLI" install-hooks >/dev/null 2>&1
claude_cmd() {
  "$NODE" -e '
    const fs = require("fs"), os = require("os"), path = require("path");
    const h = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".claude/settings.json"), "utf8")).hooks;
    process.stdout.write(h[process.argv[1]].find((r) => r.hooks.some((x) => x.command.includes("/.agentbar/hooks/claude/"))).hooks[0].command);' "$1"
}
check "every Claude command execs node" '"$NODE" -e "
  const h = JSON.parse(require(\"fs\").readFileSync(process.env.HOME + \"/.claude/settings.json\", \"utf8\")).hooks;
  const ours = Object.values(h).flat().flatMap((r) => r.hooks).filter((x) => x.command.includes(\"/.agentbar/hooks/claude/\"));
  process.exit(ours.length === 8 && ours.every((x) => x.command.startsWith(\"exec \\\"\")) ? 0 : 1);"'

for ev in SessionStart UserPromptSubmit PreToolUse Stop; do
  CMD="$(claude_cmd "$ev")"
  AGENT_PID="$(AGENTBAR_FORCE_APP=1 "$NODE" "$AGENT" "$SH" "$CMD" '{"session_id":"inst-'"$ev"'","cwd":"/tmp/proj","prompt":"p","tool_name":"Read"}')"
  check "installed $ev names the agent" '[ "$(row_pid "$HOME/.agentbar/state.d/inst-$ev.json")" = "$AGENT_PID" ]'
done

# --- a command nobody rewrote: no exec, so the scripts have to step over the shell
fresh_home
legacy() { printf '"%s" "%s"' "$NODE" "$PWD/Scripts/hooks/$1"; }
AGENT_PID="$(AGENTBAR_FORCE_APP=1 "$NODE" "$AGENT" "$SH" "$(legacy claude/lifecycle.js) start" '{"session_id":"leg-start","cwd":"/tmp/proj"}')"
linux_check "lifecycle start names the agent" '[ "$(row_pid "$HOME/.agentbar/state.d/leg-start.json")" = "$AGENT_PID" ]'
AGENT_PID="$("$NODE" "$AGENT" "$SH" "$(legacy claude/update.js) prompt" '{"session_id":"leg-prompt","cwd":"/tmp/proj","prompt":"p"}')"
linux_check "update prompt names the agent" '[ "$(row_pid "$HOME/.agentbar/state.d/leg-prompt.json")" = "$AGENT_PID" ]'
AGENT_PID="$(AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=1 "$NODE" "$AGENT" "$SH" "$(legacy claude/permission.js)" \
  '{"session_id":"leg-perm","prompt_id":"p1","tool_name":"Bash","tool_input":{"command":"ls"}}')"
linux_check "permission names the agent" '[ "$(row_pid "$HOME/.agentbar/state.d/leg-perm.json")" = "$AGENT_PID" ]'
AGENT_PID="$(AGENTBAR_FORCE_APP=1 "$NODE" "$AGENT" "$SH" "$(legacy gemini/gemini.js)" '{"hook_event_name":"BeforeAgent","session_id":"leg-gem","cwd":"/tmp/proj"}')"
linux_check "gemini names the agent" '[ "$(row_pid "$HOME/.agentbar/state.d/leg-gem.json")" = "$AGENT_PID" ]'
AGENT_PID="$(AGENTBAR_FORCE_APP=1 "$NODE" "$AGENT" "$SH" "$(legacy cursor/cursor.js)" '{"hook_event_name":"preToolUse","conversation_id":"leg-cur","cwd":"/tmp/proj","tool_name":"Shell"}')"
linux_check "cursor names the agent" '[ "$(row_pid "$HOME/.agentbar/state.d/leg-cur.json")" = "$AGENT_PID" ]'
AGENT_PID="$(AGENTBAR_FORCE_APP=1 "$NODE" "$AGENT" "$SH" "$(legacy antigravity/antigravity.js) PreToolUse" '{"conversationId":"leg-anti","workspacePaths":["/tmp/proj"],"toolCall":{"name":"edit_file"}}')"
linux_check "antigravity names the agent" '[ "$(row_pid "$HOME/.agentbar/state.d/leg-anti.json")" = "$AGENT_PID" ]'

# Only a `-c` wrapper is stepped over: a shell running a script is the hook's
# real parent, and so is the codex shim's host, which runs node with no shell.
fresh_home
printf '#!/bin/bash\necho $$ > "$HOME/script-pid"\n%s prompt <<<%s\ntrue\n' \
  "$(legacy claude/update.js)" "'{\"session_id\":\"by-script\",\"prompt\":\"p\"}'" > "$HOME/run.sh"
bash "$HOME/run.sh"
check "a script's shell is kept" '[ "$(row_pid "$HOME/.agentbar/state.d/by-script.json")" = "$(cat "$HOME/script-pid")" ]'
printf '{"session_id":"direct","prompt":"p"}' | "$NODE" Scripts/hooks/claude/update.js prompt
check "a direct parent is kept" '[ "$(row_pid "$HOME/.agentbar/state.d/direct.json")" = "$$" ]'

# --- an older install is repaired in place, never duplicated
fresh_home
mkdir -p "$HOME/.claude"
OLD="$HOME/.agentbar/hooks/claude"
cat > "$HOME/.claude/settings.json" <<EOF
{"hooks":{
  "SessionStart":[{"hooks":[{"type":"command","command":"\"/usr/bin/node\" \"$OLD/lifecycle.js\" start"}]},
                  {"hooks":[{"type":"command","command":"echo mine"}]}],
  "Stop":[{"hooks":[{"type":"command","command":"\"/usr/bin/node\" \"$OLD/update.js\" stop"}]}],
  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\"/usr/bin/node\" \"$OLD/update.js\" pre"},
                                          {"type":"command","command":"echo sibling"}]}],
  "Notification":[{"hooks":[{"type":"command","command":"\"/usr/bin/node\" \"$OLD/update.js\" notify"}]}]
},"theme":"dark"}
EOF
"$CLI" install-hooks >/dev/null 2>&1
SNAP="$(cat "$HOME/.claude/settings.json")"
"$CLI" install-hooks >/dev/null 2>&1
shape() {
  "$NODE" -e '
    const h = JSON.parse(require("fs").readFileSync(process.env.HOME + "/.claude/settings.json", "utf8")).hooks;
    const ours = (r) => r.hooks.some((x) => x.command.includes("/.agentbar/hooks/claude/"));
    const out = [];
    for (const [ev, rules] of Object.entries(h)) {
      const mine = rules.filter(ours);
      out.push(`${ev}:${mine.length}:${mine.every((r) => r.hooks[0].command.startsWith("exec ")) ? "exec" : "bare"}`);
    }
    process.stdout.write(out.sort().join(" "));'
}
check "one exec entry per event, none left bare" '[ "$(shape)" = "PermissionRequest:1:exec PostToolUse:1:exec PreCompact:1:exec PreToolUse:1:exec SessionEnd:1:exec SessionStart:1:exec Stop:1:exec UserPromptSubmit:1:exec" ]'
check "the user's own hook survives"   'grep -q "echo mine" "$HOME/.claude/settings.json" && grep -q "\"theme\": \"dark\"" "$HOME/.claude/settings.json"'
check "a user hook sharing AgentBar's rule survives in it" '"$NODE" -e "
  const r = JSON.parse(require(\"fs\").readFileSync(process.env.HOME + \"/.claude/settings.json\", \"utf8\")).hooks.PreToolUse;
  const mine = r.find((x) => x.matcher === \"Bash\");
  process.exit(mine && mine.hooks.length === 1 && mine.hooks[0].command === \"echo sibling\" ? 0 : 1);"'
check "the repair is idempotent"       '[ "$SNAP" = "$(cat "$HOME/.claude/settings.json")" ]'

echo
echo "shell pid: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
