# Contributing to AgentBar

Thanks for your interest! AgentBar is intentionally small — please keep it that way.

## Ground rules

1. **One file, one responsibility.** Keep the unit layout from
   `docs/specs/2026-07-23-agentbar-design.md`; don't grow a god-object controller.
2. **Stay out of the way.** No dock icon, no heavy dependencies, nothing that
   unfolds over the screen on its own. Two surfaces only — the menu bar item
   (`StatusItemController`) and the island (`IslandController`) — both fed from
   the same stores through `MascotDriver` / `AgentActions`; never render one from
   the other's code. Windows are the exception, not the pattern: only
   `WelcomeWindow` and `SettingsWindow`, both small, both opened by the user.
3. **Hooks must never block the host agent** — async, atomic writes, exit fast.
   Sole exception: `permission.js` (see the comment at its top).
4. **Adding an agent** = one entry in `Agents.swift`, a sprite in
   `Sources/AgentBar/Sprites/`, optionally a hook dir in `Scripts/hooks/<agent>/`
   plus its installer step in `HookInstaller.swift` and the Linux CLI's
   `install-hooks`, and the agent id in the `docs/protocol.md` list and the README
   agent table (same checklist as `CLAUDE.md`). Nothing else should need touching.
5. Third-party marks belong in `THIRD_PARTY_NOTICES.md`.

## Developing

```bash
./Scripts/build.sh                        # builds build/AgentBar.app (universal)
./Scripts/build.sh --native               # this Mac's architecture only — see below
open build/AgentBar.app
swift test                                # Swift unit tests (needs Swift 6)
./Scripts/test/permission-hook-test.sh    # Claude hook protocol tests
./Scripts/test/bridge-hooks-test.sh       # cursor/gemini/antigravity/codex bridge tests
./Scripts/test/opencode-plugin-test.sh    # OpenCode plugin driven through its event bus
./Scripts/test/cli-test.sh                # cross-platform CLI tests
node --test Scripts/cloud/test/*.test.js  # cloud poller tests
./Scripts/test/antigravity-watcher-test.sh # live-app integration test (needs the app running)
./Scripts/test/cowork-watcher-test.sh     # live-app integration test (needs AgentBar + Claude.app running)
```

`swift build` works for quick compile checks and SourceKit-LSP; the shippable app
(bundle, Info.plist, hooks) comes from `./Scripts/build.sh`. `docs/testing.md`
says what each suite covers and how to add to it.

**If the universal build fails to link x86_64**, you are on a machine with only
the Command Line Tools. Recent versions ship `libswiftCompatibility*.a` for arm64
alone, and the error looks like this:

```
ld: warning: ignoring file libswiftCompatibility56.a: fat file missing arch 'x86_64'
Undefined symbols for architecture x86_64: "__swift_FORCE_LOAD_$_swiftCompatibility56"
```

Use `./Scripts/build.sh --native` for a bundle you can actually run. It is a dev
build only — releases stay universal, and are cut from CI (see **Releases**).

**Testing a hook change needs a rebuild.** `HookInstaller` re-copies the scripts
from the app bundle into `~/.agentbar/hooks/` on every launch, so editing the
copy in `~/.agentbar/` is overwritten the next time AgentBar starts. Edit the
repo, rebuild, relaunch.

**Quit any installed copy before testing a dev build.** Two AgentBars running at
once both watch *and write* `~/.agentbar/state.d/`, so they overwrite each other's
rows — the two live-app suites go red in ways that look like watcher bugs and
aren't. `pkill -f AgentBar` first, then launch the one you mean to test.

**macOS re-asks for folder permissions on every rebuild** unless you sign with a
stable identity: TCC keys its grants to the signing certificate, and the ad-hoc
fallback (`-s -`) is a brand-new identity each build. Create a local cert once
and `build.sh` picks it up by name automatically:

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout k.pem -out c.pem -subj "/CN=AgentBar Local Signing" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE"
openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -out i.p12 -inkey k.pem -in c.pem -passout pass:x        # transient p12, deleted below
security import i.p12 -k ~/Library/Keychains/login.keychain-db -P x -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db c.pem           # may ask for your login password once
rm k.pem c.pem i.p12
```

A differently named cert works via `AGENTBAR_SIGN_ID="My Cert" ./Scripts/build.sh`.

Which surface you get is a `UserDefaults` key, so you can flip it without the
welcome window:

```bash
defaults write com.michalstrnadel.agentbar presentationMode -string island  # or menuBar / both
defaults delete com.michalstrnadel.agentbar showWelcomeOnLaunch             # first-run window back
defaults write com.michalstrnadel.agentbar islandExpandDebug -bool true     # hold the island open (layout work)
defaults write com.michalstrnadel.agentbar settingsOnLaunchDebug -bool true # open Settings on launch (layout work)
```

The whole app ↔ hook protocol is files in `~/.agentbar/` (`state.d/`, `requests.d/`,
`answers.d/`) — you can drive any app feature by writing JSON files there, no agent
needed. See `docs/specs/` for the design documents.

## Pull requests

- Conventional Commits (`feat:`, `fix:`, `docs:`, …).
- Add or extend a test when you touch the hook protocol.
- Update `CHANGELOG.md` for user-visible changes.
- CI must be green (build + hook tests).

## Releases

A release asset has to satisfy two things that no longer fit on one machine. It
must be **universal**, and it must be signed with the **"AgentBar Local Signing"**
identity — that lives in one keychain, and changing the signature makes macOS
re-ask every user for folder access on update, which is the whole reason a stable
identity exists. A machine with only the Command Line Tools cannot link x86_64 at
all, and CI has no access to the certificate. So CI builds and verifies the
universal bundle, and it is signed locally.

1. Bump `VERSION` in `Scripts/build.sh`, date the `CHANGELOG.md` section.
2. Commit as `chore: release X.Y.Z — …` and push. Wait for CI to go green.
3. Download the bundle CI built and verified, then sign it here:
   ```bash
   RID=$(gh run list --limit 1 --json databaseId -q '.[0].databaseId')
   gh run download "$RID" -n AgentBar-app-universal -D /tmp/rel
   cd /tmp/rel && ditto -xk AgentBar.app.zip .
   codesign --force --deep -s "AgentBar Local Signing" AgentBar.app
   rm AgentBar.app.zip
   ditto -c -k --sequesterRsrc --keepParent AgentBar.app AgentBar.app.zip
   ```
   `ditto`, not `zip`: a plain zip of a `.app` loses symlinks and resource forks.
4. Check the asset before publishing it — this is what every user downloads:
   ```bash
   codesign --verify --deep --strict AgentBar.app
   codesign -dvvv AgentBar.app 2>&1 | grep Authority   # AgentBar Local Signing
   lipo -archs AgentBar.app/Contents/MacOS/AgentBar    # x86_64 arm64
   /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" AgentBar.app/Contents/Info.plist
   ```
5. `gh release create vX.Y.Z AgentBar.app.zip --title "…" --notes-file …`. The
   asset **must** be named `AgentBar.app.zip` and the tag `vX.Y.Z`: `UpdateChecker`
   looks up exactly that name under `releases/latest` and strips the leading `v`
   to compare versions. A different name ships an update nobody can install.
6. Update `Casks/agentbar.rb` in `michalstrnadel/homebrew-tap`: bump `version`,
   set `sha256` to the output of `shasum -a 256 AgentBar.app.zip`, push, then
   verify with `brew audit --cask michalstrnadel/tap/agentbar` (and
   `brew style` on the tap checkout).
