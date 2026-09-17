# AgentBar — AI Instructions

Context for AI coding assistants working on this repository.

## Project
AgentBar is a native macOS status app (Swift, AppKit, SPM) showing live status of
AI coding agents (Claude Code & Cowork, Codex, Cursor, Gemini, Copilot,
Antigravity, Qwen Code, OpenCode, Devin). Node.js hook scripts in
`Scripts/hooks/` write per-session JSON to `~/.agentbar/state.d/`; the app watches
that folder. Cloud-only runs (Cursor cloud agents, Devin, Codex cloud) have no
hook to install: the optional external poller in `Scripts/cloud/` writes the same
rows with `entrypoint: "cloud"`. It presents itself as a menu bar item, a Dynamic Island panel under the
notch, or both — the user picks in the welcome window. State file protocol (normative):
`docs/protocol.md`; original design spec (a 1.0.0 snapshot, read its header note):
`docs/specs/2026-07-23-agentbar-design.md`; presentation modes:
`docs/plans/2026-07-28-presentation-modes-and-island.md`.

## Build & run
```bash
./Scripts/build.sh          # builds build/AgentBar.app
open "build/AgentBar.app"
```

## Rules
1. One file, one responsibility — keep the unit layout from the spec; don't grow a
   god-object controller.
2. Stay out of the way: no dock icon, no heavy dependencies, nothing that unfolds
   over the screen on its own. Two surfaces only — the menu bar item
   (`StatusItemController`) and the island (`IslandController`) — both fed from the
   same stores through `MascotDriver` / `AgentActions`; never render one from the
   other's code. Native notifications are the one thing that may appear over the
   screen, and three conditions earn it, not one: the user switched them on (off by
   default, like sounds), the banner is the system's surface rather than one AgentBar
   draws, **and what is being announced either wants an answer or happened while the
   user was away**. That last one is a rule, not a preference — 1.17.0 fired on every
   `done`, Claude Code enters `done` after every turn, and a fifty-turn conversation
   posted fifty banners. An agent finishing is not news. See `Notifier`.
   Windows are the exception, not the pattern: only `WelcomeWindow`
   and `SettingsWindow`, both small, both opened by the user. Settings is a
   sidebar of pages (`SettingsChrome` is its furniture), not a scroll: a new
   preference joins a page or earns one, and never lengthens a column until the
   last section falls off the screen.
   `LauncherPanel` is the third surface and the only one summoned by a keystroke.
   It earns that by the same test the banners do: it takes no space until asked,
   it appears only on a deliberate keypress or menu click, and it closes the
   instant it loses focus. A surface that can appear without being asked for, or
   that stays once you look away, does not belong here.
3. Hooks must never block the host agent: async, atomic writes, exit fast.
   Sole exception: `permission.js` blocks while the session is already waiting on
   the human, and must always time out silently to the normal terminal prompt.
4. Adding an agent: entry in `Agents.swift`, sprite in `Sources/AgentBar/Sprites/`,
   optional hook dir in `Scripts/hooks/<agent>/` plus its installer step in
   `HookInstaller.swift` AND the Linux CLI's `install-hooks`, and the agent id in
   the `docs/protocol.md` list, the README agent table, and the agent list above.
   If it gets hooks it also needs a row in the `Diagnostics.integrations` table AND
   the Linux `doctor`'s — otherwise diagnostics reports a clean bill of health for
   an integration it never looked at. Nothing else should need touching.
5. Third-party marks stay listed in `THIRD_PARTY_NOTICES.md`.
