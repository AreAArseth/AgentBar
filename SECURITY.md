# Security Policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting on this repository
(Security ▸ Report a vulnerability) rather than a public issue. You should get a
response within a few days.

## Scope notes

AgentBar's remote-approval feature is security-relevant by nature. Design
guarantees worth knowing when auditing:

- Everything is same-user, local filesystem — the app ↔ hook protocol is JSON
  files under `~/.agentbar/`, and nothing about a session ever leaves the machine.
- Two outbound calls exist, both in the app and neither on the approval path: the
  daily update check against GitHub Releases, and — **only** while
  **Settings ▸ Usage** is ticked, off by default — a `GET` to
  `api.anthropic.com/api/oauth/usage` for Claude's own quota. That one reads the
  OAuth token Claude Code stored (Keychain item `Claude Code-credentials`, so macOS
  raises its own consent dialog the first time), sends it to Anthropic and nowhere
  else, keeps it only for the duration of the request, never logs it, and never
  refreshes it — an expired token simply means no reading until the CLI renews it.
  It reads exactly one field, `claudeAiOauth.accessToken`, and never searches that
  record for a token by name: **the same Keychain record holds an `accessToken` for
  every MCP server you have authorised**, and 1.19.0–1.23.0 could pick one of those
  and send it to Anthropic. Fixed in 1.24.0; if you had the switch on in those
  versions, rotating any MCP OAuth login you had authorised is the cautious move.
  Where Claude Code signs in under its own `CLAUDE_CONFIG_DIR`, that login is kept
  where AgentBar cannot read it; **Settings ▸ Usage ▸ Use a token…** takes one from
  `claude setup-token` instead. That token *is* stored — in AgentBar's own Keychain
  item (`AgentBar-claude-quota`), never in a file, never logged, used for nothing but
  that one request, and removed by the same button. It is the only secret this app
  stores, and nothing is stored unless somebody pastes it in.
  See `Sources/AgentBar/ClaudeQuota.swift`.
- "Always allow" can only persist a rule that Claude Code itself suggested for
  that request: the hook structurally compares the answer's rule against the
  received `permission_suggestions` and downgrades anything else to a one-shot
  allow (`Scripts/hooks/claude/permission.js`).
- Every failure path (app missing, killed hook, timeout, malformed files)
  degrades to the agent's normal interactive prompt — never to an approval.
- Keystroke approval for non-Claude agents requires the user to grant the
  Accessibility permission and a per-prompt click on an explicitly labeled item.

Reports that break any of these guarantees are exactly what we want to hear about.
