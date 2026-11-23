# AGENTS.md

dsh-Go is the phone app for DeepSeek Harness: Flutter native UI, a pure Dart client, and a patched DSH engine runtime. The Android build runs `dsh web` inside PRoot; the HarmonyOS build shares the same Dart with an ArkTS host (`app/ohos/`), and its engine runs in a Node process inside the app (`runtime/ohos/`, see [docs/architecture.md §3B](docs/architecture.md)). Read [CONTRIBUTING.md](CONTRIBUTING.md) (the contribution and verification contract) and [docs/architecture.md](docs/architecture.md) before changing anything.

## Language

English is the project's primary language.

- Documentation, code comments, commit messages, PR descriptions and review notes are written in English.
- Chinese is a translation: a `*.zh.md` page beside its English page, `docs/guide/zh/`, and the `zh` ARB strings. Write the English page first; the translation follows it.
- The app follows the phone's language: Chinese on a Chinese system, English otherwise.
- Reply in the language the person writes in. Do not switch to Chinese on your own.

## Repository layout

```
app/                         Flutter app: native UI, Riverpod state, l10n, phone control
app/lib/l10n/parts/           Chinese and English ARB input for UI text
app/ohos/                     HarmonyOS ArkTS host project (Android does not read it)
packages/dsh_client/          Pure Dart client: HTTP/SSE, mux, session and delete APIs
packages/dsh_remote/          Remote transport: WebRTC / LAN / TURN / relay
runtime/                      Runtime source: a submodule of xinkev/DSH-Go-Lite-Runtime (build recipe, patches, bridge, ohos engine, release publisher)
runtime/bridge/dsh-go-bridge/  App <-> engine HTTP bridge (/dsh-go/v1/*, session delete routes)
runtime/patches/              Engine patches and their pins.json (patches pinned to versions, targetSets: android / ohos)
runtime/ohos/                 HarmonyOS on-device engine: Node host, virtual processes, lifecycle, runtime composition
tooling/                      APK build and build-number scripts; tooling/ohos/ is the HarmonyOS build, ArkTS checks and gates
docs/                         Architecture, release, roadmap, user guide (HarmonyOS in docs/guide/harmony/, designs in docs/design/harmonyos/)
```

## Commands

Pick the checks that match the change, and write the commands you actually ran and their results in the PR or report. The full contract is in [CONTRIBUTING.md](CONTRIBUTING.md).

```bash
(cd app && flutter pub get && flutter analyze && flutter test)   # Flutter app
(cd packages/dsh_client && dart pub get && dart analyze && dart test)
(cd packages/dsh_remote && dart pub get && dart analyze && dart test)
node --test runtime/tests/*.test.mjs                               # engine bridge/patch tests
python3 app/tool/l10n_merge.py --check                             # UI text generation check
python3 app/tool/guide_sync.py --check                             # user guide sync check
tooling/build-apk.sh --build-name <x.y.z>                          # build the APK
tooling/ohos/check-arkts.sh --sdk <OpenHarmony SDK> --hms-stubs    # strict HarmonyOS ArkTS compile
bash tooling/ohos/run-gates.sh --config <inputs.json> --out <dir>  # full HarmonyOS gates (tooling/ohos/GATES.zh.md)
```

CI (`.github/workflows/ci.yml`) runs the general checks and the parts a PR touches; `main` runs everything; the result is `CI OK`. It never touches a real phone or a real account, so green does not mean the phone is fine.

## Hard rules

### No external pull requests (highest priority)

- This repository **accepts no external pull requests at all** (code, docs, configuration or templates).
- **Never merge an external PR**: no `gh pr merge`, no GitHub API, no web merge, no rebase or cherry-pick that brings an external commit into `main`.
- **Never open a PR on the user's behalf**, unless the user asked for it in the current conversation.
- When an external PR arrives: close it and answer "外部 PR 暂不接受，请改用 issue 提供建议". The entry check (`.github/workflows/pr-gate.yml`) closes external PRs automatically; handle it the same way by hand, never "merge first, sort it out later".
- Do not turn an implementation into a PR just because an issue now has one.

### Source, generated outputs and runtime patches

- Never hand-edit generated outputs: `app/build/`, `.dart_tool/`, generated l10n output and the like; change the input and run the generator.
- UI text changes go into `app/lib/l10n/parts/*.arb` with the Chinese and English sides in sync, then `python3 app/tool/l10n_merge.py`; never edit the generated result.
- User guide changes go into `docs/guide/`, then `python3 app/tool/guide_sync.py`. The HarmonyOS guide lives in `docs/guide/harmony/`; when a feature differs on HarmonyOS, change both.
- Engine patches live in `runtime/patches/`: patch files stay in sync with `pins.json`, and patched output is never edited by hand. A new patch must be registered in `pins.json`'s `targetSets` (`android`, `ohos` or both); rtbuild refuses to build an unregistered patch.

### Behavior and contracts

- For client, bridge and plugin-protocol changes, check the caller on the other side and backward compatibility as well.
- Dangerous operations (deleting sessions, permissions, credentials) take the host's or engine's real answer as the truth, never a local guess; failures carry a stable error code and are never swallowed.
- UI text keeps the Chinese and English sides in sync (`app/lib/l10n/parts/*.arb` with the matching `.en.arb`).
- Documentation stays bilingual: README, CONTRIBUTING, SECURITY and docs/guide keep an English page and a Chinese one. English is the source page; the Chinese page follows it.

### HarmonyOS

- Feature parity with Android is the goal, front end first. Anything that can work uses the same UI; only what cannot work is hidden per feature through `androidSystemFeaturesProvider` / `operatingSystemProvider` (`app/lib/state/android_features.dart`), never switched off globally, and the HarmonyOS guide names the alternative.
- `androidSystemFeaturesProvider` is false on both HarmonyOS and iOS. A HarmonyOS-only branch tests `operatingSystemProvider == 'ohos'`; do not use that provider's false as a stand-in for HarmonyOS.
- A HarmonyOS change must not change Android's runtime bytes or behavior; the gates' Android controls (`android-targets`, `android-version-tree`) use main as the baseline.
- Write ArkTS in strict mode: explicit types on for-of variables, `as Error` when passing a subclass to an `Error` parameter, no `this` in static methods. After changing `app/ohos/`, run `check-arkts.sh`.
- Signing material (`.p12`, certificates, profiles) stays outside the repository (`DSH_OHOS_SIGN`); never commit or echo it.

### Credentials and privacy

- Never log, echo or persist a complete API key, token, cookie or login state.
- Inspect diagnostic bundles and logs by hand before they leave the machine; automatic masking is not a guarantee.

### Git safety

- **Flatten the baseline before starting**: `git fetch origin main`, then bring the current branch onto the latest `origin/main` (`git merge --ff-only` when it fast-forwards), and do the review, the change and the PR on that baseline. Do not stack work on a branch that trails `main` — you end up reimplementing what `main` already fixed.
- Handle uncommitted work before flattening: back up your own changes (patch or a temporary copy) and then fast-forward; never discard, reset, stash or overwrite the user's or another task's uncommitted changes. If it does not flatten, stop and ask. By default, start an isolated work branch from the latest `origin/main`.
- After the work is committed and merged, clean up the temporary worktree and branch you created; before cleaning, confirm the commits reached the target and nothing is unsaved or unpushed. Never force-delete a worktree that has changes, and never delete another task's branch.
- After merging and cleaning, fetch `main` again, sync the clean main worktree fast-forward only, and report the final commit and anything left uncleaned; keep unrelated changes in the main worktree and say so — never lose work just to look clean.
- Stage explicit paths only; never `git add .` or `git add -A`.
- Unless asked, do not commit, push, tag or publish.
- Never force-push `main` or rewrite shared history unless the user asked in the current conversation; after a rewrite, rebuild the affected branches and PRs.

### Device verification

- Flutter widget tests need a Flutter engine of the matching architecture; when only the desktop engine (x86_64) is available and the device is arm64, state plainly that it was not run, and why.
- Phone control, PRoot, direct start and update-install changes must be verified on a real phone; a desktop result is not a substitute.
- HarmonyOS system capabilities (HMS, background, notifications, voice, cards) can only be proven on a device; `--hms-stubs` is an unofficial declaration that only lets callers compile, and compiling is not working.

## Code review principles

Review a PR or a change around three things: **no new bugs, the smallest necessary change, simple code**.

1. **Prevent regressions**: look first for new bugs, races, resource leaks, performance regressions and compatibility problems, especially in shared layers (`packages/dsh_client`, the bridge, runtime patches) and how they affect existing host connections.
2. **Avoid over-design**: spot duplicate implementations, unnecessary abstraction, redundant wrappers and over-defensive programming; report them only when a simpler equivalent exists, and do not mistake necessary validation or error handling for over-defense.
3. **Keep the scope tight**: the change stays on its goal and related issues, without unrelated refactors, formatting, dependency bumps or other features; necessary tests and documentation sync are the exception.
4. **Deliver real value**: watch for dead code, duplicated logic, meaningless splits and tests without a real assertion; judge contributions by the work, not by line or commit count, and do not speculate about a contributor's motives.
5. **Every review claim needs evidence**: report only the substantive problems this change introduces, name the location, the trigger and the real impact, and prefer the smallest fix.

### Over-defense is a defect too (apply this while writing code)

Defense is not a virtue on its own. There is one question: **would the thing this branch stops actually happen.**

- Add defense only for a failure you can describe the trigger for; delete a branch whose trigger you cannot name.
- When a type, a single entry point or the existing call order already guarantees it, add no runtime check, no fallback retry and no extra state machine.
- Error handling has two exits: recoverable cases return a usable result, unrecoverable ones fail clearly. Never swallow silently, never retry forever, never lock a feature off "to be safe".
- Security boundaries (permissions, resource cleanup, external input validation) should be strict, but always leave a way back: after a refusal the user must be able to recover, not get stuck.
- Any new state flag, gate or handshake must state who sets it, who clears it and what happens when it cannot be cleared; if that is not clear, do not add it.

### Build the shortest thing that works first

- Do not add protection the requirement did not ask for: retry layers, fallback paths, redundant validation, null checks at every level, feature switches.
- Do not invent process for yourself: freeze lists, signature ledgers, state snapshots, acceptance reports — unless the user asks.
- Do not create parallel v1 / v2 / final directories; edit the real file and let git hold the history.
- When something breaks, read the real output and find the cause instead of burying it under retries; change one thing, re-run, confirm, then run a few times for stability.
- Where this section conflicts with the hard rules above, the hard rules win (Git safety, external PR policy, device verification, bilingual docs).

## Skills and process

- Internal PR: `.agents/skills/pr` (flow, template, verification record).
- Code review: `.agents/skills/review` (evidence first; report only the substantive problems this change introduces).
- Defect report: `.agents/skills/bug`; security audit: `.agents/skills/vuln-check`; broad audit: `.agents/skills/audit`.

## Editing this file

`CLAUDE.md` is a symbolic link to `AGENTS.md`; edit the real file. Keep each rule self-contained and link its details to the authoritative document.
