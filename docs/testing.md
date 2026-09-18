# Testing AgentBar

Everything outside the Swift app — the hook scripts, the agent bridges, the
OpenCode plugin and the cross-platform CLI — is plain Node and bash, and is
tested end-to-end against a throwaway `HOME` on any OS. The Swift app is
compiled in CI and unit-tested where its behaviour can be reached without a
running app; its two watchers have live-app integration suites that only run on
a Mac with the app up. This page says what each suite covers, how to run it, and
how to add to it.

## The suites

| Suite | Covers | Checks | Needs |
|---|---|---|---|
| `Scripts/test/permission-hook-test.sh` | The Claude hooks: `permission.js` (allow/always/deny/defer round-trips, rule forgery, questions, plans, timeouts, signals, successor/`hookPid` guards, surrogate-safe cuts, the session's `cwd` carried and omitted rather than emptied, **and Codex's dialect: a prefixed row and a `<session>-<turn>` request, Claude's envelope back, an *Always* with nothing to pin it to degrading to a one-shot allow, and the prefix staying off every other agent's rows**), `update.js` (state mapping incl. Copilot's `recoverable` error, `started_at`, prompt/model/recap/activity rules, stalled stdin), `lifecycle.js` (seed, merge on resume/compact/clear, the mid-prompt open, dead-only sweep, launch guard, end) | 158 | node, python3 |
| `Scripts/test/bridge-hooks-test.sh` | The Cursor, Gemini, Antigravity and Codex bridges: dead-only stale sweep, app-launch guard (fake `open` in `PATH`), event → state mapping, project/prompt merge across events, the 64-char id cap, surrogate-safe cuts, Antigravity's fail-open `PreToolUse` decision, and the Codex notify bridge standing down once the real hooks are wired **and** accepted — but never while they are only written, nor when the config cannot be read; and the Codex shim, which is where the shared scripts learn who is asking — a prefixed row, a live state rather than a bare `done`, an id that agrees with its own file name, the agent's own pid as the parent, a session that ends by deleting its row, and nothing at all run for a script name it cannot vouch for | 67 | node, python3 |
| `Scripts/test/opencode-plugin-test.sh` | The OpenCode plugin, loaded as ESM and driven through its event bus: created/prompt/tool/permission/idle/error/title/child/deleted — including "the idle that trails an error stays an error" | 23 | node |
| `Scripts/test/cli-test.sh` | `Scripts/cli/agentbar`: status/requests rendering, pruning rules, approve/deny/answer (incl. plan and multi-question refusals, `hookPid` stamping), waybar classes and heartbeat, the hook blocking on the CLI's presence, the history record an ended session leaves behind (baseline, once per ending, `idle` is not an ending, the weight read out of a Claude transcript with duplicate lines counted once, an agent with nothing on disk leaving the key out rather than writing zero), `install-hooks` for every agent (idempotent, unparseable config untouched, `CLAUDE_CONFIG_DIR`, Copilot's own hooks file left alone, the written node path stable and the same interpreter, a dead Codex interpreter repaired), and `usage` (reading past a `premium` line to the account's windows, a rolled-over window carrying no bar, a stale rollout speaking for nothing, and naming what it could not ask rather than omitting it), and the decision ledger (a decision recorded only once it reached `answers.d`, the shape keeping the verb and dropping every argument, the wait measured, repeats not collapsing, `approvals` and `forget`), and the rules the human wrote (listed with what each has done, a firing counted from the ledger and never from a counter in the file, one bad rule or an unreadable `mode` voiding the whole file, a watching rule counted as what it *would* have done and as nothing that happened, and the command saying plainly that it lists rules rather than applying them), and the Codex hooks block (every event present, the approval timeout above the hook's own wait, `SessionEnd` inside the cap Codex clamps to, the user's keys untouched, written exactly once, idempotent, and **notify still installed beside it** — the block carries the same path, so a blind marker match used to read it as "notify is wired") | 123 | node, python3 |
| `Scripts/test/doctor-test.sh` | `agentbar doctor`: a clean install reporting clean, an interpreter that moved, an agent installed but unwired, the escaped-slash marker trap, a config the installer refuses to touch, directories missing or unwritable, last-seen read from `history.jsonl` (blank is fine, a fortnight of silence is not), `--json`, a Codex hooks block written but not yet accepted, and that a diagnostic changes nothing it diagnoses. Assertions are by check id, never wording — see `docs/diagnostics.md` | 26 | node |
| `Tests/AgentBarTests/` (`swift test`) | The Swift app where it can be reached without a running app: the updater's relaunch script (new bundle opens; it refuses and the backup is restored and launched; both refuse and the old bundle stays with the staging dir kept; a hostile bundle path stays out of the shell's parser); the island's display choice (defaults, round-trip, a pinned display unplugged falling back to the pointer without losing the pin); the display row wrapping at one display through eight; the installer's node-path stabilisation and Codex repair; the history edge detector (a lingering `done` row written once, `idle` not an ending, a torn line costing one line, prune leaving an unchanged file alone); the digest's arithmetic (local midnight, a partial total saying what it covers, an end before its start not counting as timed, a token clause that drops rather than showing zero); what does and does not deserve a notification (off means off, an answered request is withdrawn, a watchdog-decayed end is not announced, **a successful turn is not an event at all**, the quiet burst announced once and only once the human is away, `notifyDone` migrating exactly once); what a session cost (duplicate transcript lines counted once, Codex's last cumulative `token_count` winning, Copilot's rows summed through real SQLite, every reader answering nil rather than zero); what moved in the repo (the per-file subtraction and its zero floor, a binary counted as a file and no lines, a missing baseline producing nothing); what each provider has left (a rollout read past its `premium` bucket to the account's windows, a credit line only for an account that has credits, a rolled-over window refusing to quote the old number, Claude's `utilization` taken as a percentage and not a fraction, an expired credential left unused, Copilot's local day as a range against a UTC column, **only Claude's own field read out of a credential record that also holds every MCP server's token**, a zero expiry meaning no expiry rather than 1970, every failure carrying a sentence that names a cause, a token pasted in on purpose outranking the CLI's own, **one answer to the Keychain prompt remembered in both directions so no clock ever raises it**, a question not asked told apart from a login not there, **the hop to the main thread that every WebKit touch goes through, immediate when it is already there**, the island's line carrying what is running plus anything nearly spent, and **that line stating its own width**, since nothing else states one for it, and then **staying inside the width it is given**, since nothing clips it to that either); what the human decided (the shape's verb for multiplexers, leading `sudo`/env stripped, only the first command of a chain, no arguments kept at all, counts scoped per repo, defer and answer not counted as verdicts, the *Always* nudge needing repeats AND a clean record, a request with no timestamp contributing no wait); the diff on an approval card (a change in the middle being what you see, a gap where untouched lines were skipped, the cap announcing itself, the changed middle of a one-line edit measured in Characters and not UTF-16, a change past the right edge slid into view and a pair slid by one shared amount); the process runner giving up on a child that never returns; the launcher (a prompt round-tripping through a real `/bin/sh` as one argument whatever it contains, only agents with a verified prompt argument being handed one, recent projects deduped and still on disk); **the rules the human wrote** — the file (a round trip, one bad rule voiding all of it, an approving rule with no directory refused, a newer version refused rather than guessed at) and the engine (deny beating allow, a denial applying anywhere and an approval only in its own directory, a neighbouring checkout with a shared prefix staying outside, and the refusal table: a chained or piped line, `sudo` arriving under an innocent shape, a quoted flag not hiding it, destructive git and rm, anything reaching off the machine, a path outside the rule's directory or into anything that configures permission, a plan, a question, a tool that names nothing — plus the invariant that no matching rule means nothing is written at all), the three modes (a watching rule reaching a verdict and still answering nothing, a `watch` row counted by nothing as something that happened and by `wouldHave` as what would have, an unreadable `mode` refusing the file rather than defaulting to "on"), and the sheet's try-a-command field (what would happen, what the rule does not cover, and that no approving rule ever takes a `git push`); and every diagnostic check, by id | 291 | Swift 6 toolchain |
| `Scripts/test/antigravity-watcher-test.sh` | `AntigravityWatcher` against a staged `brain/` transcript: thinking → permission → done | — | macOS, app running, `AGENTBAR_LIVE_TESTS=1` |
| `Scripts/test/cowork-watcher-test.sh` | `CoworkWatcher` against a staged audit log | — | macOS, app + Claude.app running, `AGENTBAR_LIVE_TESTS=1` |

Counts are as of this writing; each suite prints its own `N passed, M failed`
line and exits non-zero on any failure. The two live-app suites skip cleanly
("skip: AgentBar app not running") when their preconditions are missing.

## Running

```bash
swift test                                # Swift unit tests (needs Swift 6)
./Scripts/test/permission-hook-test.sh
./Scripts/test/bridge-hooks-test.sh
./Scripts/test/opencode-plugin-test.sh
./Scripts/test/cli-test.sh
./Scripts/test/doctor-test.sh
```

Each suite creates its own temp `HOME` per scenario (`fresh_home`) and removes
it on exit, so nothing touches your real `~/.agentbar` or any agent's config —
with one historical exception worth knowing: `install-hooks` honors
`CLAUDE_CONFIG_DIR`, so `cli-test.sh` unsets it first. Keep that line if you
copy the pattern.

Runtime: the permission suite takes ~1.5 minutes (it exercises real timeouts);
the others finish in seconds.

### When `swift test` says the macro plugin is missing

On a Mac with **only the Command Line Tools** (no Xcode), `swift test` can fail with
dozens of `external macro implementation type 'TestingMacros.…' could not be found`
errors on files you did not touch. That is not your code: the toolchain's build system
omits the TestingMacros plugin from the *emit-module* invocation while including it in
the compile one, so the failure alternates from run to run. It reproduces on a package
created fresh by `swift package init`, which is the quickest way to confirm it is the
machine and not the change.

Pass the plugin yourself:

```bash
CLT=/Library/Developer/CommandLineTools
swift test -Xswiftc -load-resolved-plugin -Xswiftc \
  "$CLT/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib#$CLT/usr/bin/swift-plugin-server#TestingMacros"
```

It can still need a second run — the stale command is cached per file. CI installs
Xcode and never sees this.

### Environment knobs the scripts honor

| Variable | Honored by | Meaning |
|---|---|---|
| `AGENTBAR_FORCE_APP=1\|0` | `permission.js`, `lifecycle.js`, all four bridges | Pretend a frontend is / isn't running, instead of `pgrep AgentBar` (macOS) or the `watcher.json` heartbeat. `0` is what makes the stale sweep and the launch path testable; `1` skips both. |
| `AGENTBAR_APPROVAL_TIMEOUT=<s>` | `permission.js` | Seconds to wait for an answer (default 600). Tests use 2–30. |
| `AGENTBAR_AGENT=<id>` | `lifecycle.js`, `update.js` | The agent id the row is written under (how Qwen Code and Copilot CLI reuse the Claude scripts). |
| `NODE=<path>` | every suite | Which `node` to run the scripts with. |

The launch path spawns `open -g -b <bundle id>` on macOS only. Tests put a fake
`open` first in `PATH` that touches `$FAKEOPEN_MARK`, so a suite can never start
a real AgentBar — and the positive assertion ("launches when down") is guarded
with `[ "$(uname)" != "Darwin" ] ||` because on Linux the spawn never happens.

## CI

`.github/workflows/ci.yml` runs all four portable suites twice — on
`macos-14` and on `ubuntu-latest` (Node 20) — builds the universal app bundle on
macOS (`./Scripts/build.sh`), which is what compiles every Swift change, and runs
`swift test` on `macos-15`. A PR is green only when all four jobs pass.

The Swift suite uses **swift-testing** (`import Testing`), not XCTest, and that is
deliberate: XCTest only resolves under a full Xcode install, while swift-testing
ships with the toolchain — so `swift test` works on a machine that has nothing but
the Command Line Tools. It needs Swift 6, which is why that job runs on `macos-15`.

Two local caveats worth knowing. A stale module cache reports `plugin for module
'TestingMacros' not found`. **Alternating `swift build` and `swift test` is what
causes it most often** — building the product target evicts the macro plugin, and
the next `swift test` fails before rebuilding it. Simply running `swift test` again
is usually the whole fix; `swift package reset` clears it when it is not
(`swift package clean` is sometimes not enough). And `./Scripts/build.sh` builds universal, so it needs an x86_64 Swift
runtime — Command Line Tools alone ships `libswiftCompatibility56.a` for arm64
only, and the link fails there with `Undefined symbols for architecture x86_64`.
Use `./Scripts/build.sh --native` for a runnable dev bundle (this Mac's
architecture only), or `swift build` for a compile check. Releases stay
universal — CI has a full Xcode and both slices.

## Writing a test

The suites share one shape, and new checks should keep to it:

- `check "short name" 'shell condition'` — the condition is `eval`'d; `ok`/`FAIL`
  is printed per check and the counts summed at the end. Names read like the
  invariant they protect ("sweep keeps live session"), not like the code.
- `fresh_home` before every independent scenario. Assert on the **files** the
  protocol defines (`state.d/*.json`, `requests.d`, `answers.d`,
  `watcher.json`), not on script internals — the files are the contract.
- Drive hooks the way their host does: JSON on stdin (`printf … | node hook.js
  <event>`), the Codex notify payload as `argv[2]`, the OpenCode plugin via
  `import()` + factory (see `opencode-plugin-test.sh`'s driver).
- For a blocking `permission.js` run, start it in the background, `wait_req`
  for the request file, drop an answer into `answers.d/`, then `wait` on the
  pid and read its stdout.
- JSON assertions: `grep -q '"field":"value"'` is fine for flat fields (the
  hooks write compact JSON with no spaces). For structure, or for "is this
  well-formed UTF-16?", use python3 — `json.load(...)[key].encode("utf-8")`
  raises on a lone surrogate, which is exactly the class of bug the
  surrogate-safe cuts guard against.
- Time-based behaviour (poll intervals, the ~2 s retire) is asserted with
  bounded waits (`sleep 1`, `for _ in $(seq 50)`), never with fixed long sleeps.
- **A new test must fail on the old code.** Before committing a fix + test
  pair, run the test against the unfixed script (stash the fix, or `git show
  main:path > /tmp/old.js` and point `NODE`/the path at it) and watch it go red.

When a hook fix touches the protocol, update `docs/protocol.md` in the same
commit — the tests assert the protocol, so a silent divergence there will
mislead the next reader.

## What is not covered here, and why

- **Most of the Swift.** The app is a thin AppKit layer over the file protocol,
  and the logic worth testing (state mapping, pruning, identity of requests)
  lives in the hooks and is tested there. What the swift-testing target does
  cover is the app-side logic with no hook equivalent: the relaunch script,
  island display resolution, display-picker geometry, the history edge
  detector, the installer's node-path and Codex repair, and every diagnostic
  check. CI also compiles the Swift on macOS, which catches everything a type
  checker can.
- **Visual behaviour** (island layout, menu rendering, sprite animation). Run
  the app; `Scripts/dev/render-preview.swift` screenshots the real island views
  for eyeballing.
- **The two watchers' file-format parsing** is tested only through the live-app
  suites, because their inputs are what the third-party apps write.
