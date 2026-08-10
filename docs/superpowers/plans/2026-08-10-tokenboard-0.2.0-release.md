# Tokenboard 0.2.0 Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the approved native-menu and README refresh as Tokenboard `v0.2.0`, verify the GitHub artifact, and update the `Typiqally/homebrew-tokenboard` cask to the exact published checksum.

**Architecture:** Prepare one version-only repository commit, build and inspect the same universal archive contract used by the release workflow, then stop for the repository's mandatory human native acceptance. After that approval, fast-forward `main`, create the immutable `v0.2.0` tag, let GitHub Actions publish the archive, verify the remote artifact, attach the recorded acceptance results to the release notes, and finally update and verify the separate Homebrew tap.

**Tech Stack:** Git, SwiftPM, macOS app bundles and property lists, GitHub Actions, GitHub CLI, Homebrew Casks, `ditto`, `lipo`, `codesign`, `shasum`, and `xmllint`/`plutil` validation.

## Global Constraints

- Execute this plan only after `docs/superpowers/plans/2026-08-10-readme-visual-refresh.md` is fully complete, visually approved, committed, and the Tokenboard worktree is clean.
- Release version is `0.2.0`, tag is `v0.2.0`, and `CFBundleVersion` is `2`; this is a minor release because the native status-menu hierarchy is a user-visible feature.
- Work in the existing `main` checkout, as explicitly requested; do not create a worktree or feature branch.
- Modify only `Resources/Info.plist` in the Tokenboard repository for release preparation. Do not change runtime behavior, entitlements, dependencies, release scripts, workflows, or the already approved README/hero.
- Do not create or push the release tag until the local suite, universal release candidate, entitlement checks, clean-main synchronization, and human native release acceptance all pass.
- Never claim the interactive native acceptance passed unless the user completes and reports every check in `CONTRIBUTING.md`.
- Do not launch Tokenboard on the user's behalf. Present the exact release-candidate path and let the user perform the native acceptance.
- Treat `git push origin main`, `git push origin v0.2.0`, GitHub Release edits, and the Homebrew tap push as deliberate external mutations; resolve and verify their exact targets immediately before each action.
- Never move or recreate an existing release tag. Preflight must prove `v0.2.0` is absent locally, on `origin`, and in GitHub Releases.
- The GitHub Release asset must be produced by `.github/workflows/release.yml`, not uploaded from the local release candidate.
- Record initial-import time, incremental-refresh time, peak resident memory, the five-minute idle checks, and the synthetic deletion-retention result in the GitHub Release notes.
- Update the cask only after the GitHub Release workflow succeeds and compute its SHA-256 from the downloaded published asset.
- Do not install, uninstall, or replace `/Applications/Tokenboard.app` during automated release work. Homebrew verification stops at audit, style, metadata, and fetch.
- Leave both repositories clean and do not delete a published release, tag, or cask commit as part of routine cleanup.

---

## File Map

- Modify `/Users/typically/Workspace/tokenboard/Resources/Info.plist`: set the marketing version to `0.2.0` and build number to `2`.
- Read only `/Users/typically/Workspace/tokenboard/.github/workflows/release.yml`: tag-triggered authoritative GitHub build and release publication.
- Read only `/Users/typically/Workspace/tokenboard/Scripts/package-release.sh`: local universal archive contract and version-match gate.
- Read only `/Users/typically/Workspace/tokenboard/Scripts/verify-entitlements.sh`: signed bundle boundary verification.
- Read only `/Users/typically/Workspace/tokenboard/CONTRIBUTING.md`: mandatory human release-acceptance checklist.
- Modify `/opt/homebrew/Library/Taps/typiqally/homebrew-tokenboard/Casks/tokenboard.rb`: change only `version` and `sha256` after the asset is public.
- Use a uniquely named temporary directory under `${TMPDIR:-/tmp}` for published-asset verification; do not commit its contents.

### Task 1: Prepare and verify the 0.2.0 release candidate

**Files:**
- Modify: `Resources/Info.plist:10`
- Test: `Scripts/package-release.sh`
- Verify: `Scripts/verify-entitlements.sh`

**Interfaces:**
- Consumes: the clean, committed final SHA from the completed README visual-refresh plan.
- Produces: a committed `Resources/Info.plist` with `CFBundleShortVersionString = 0.2.0` and `CFBundleVersion = 2`, plus a locally verified `.build/artifacts/Tokenboard-0.2.0.zip` for acceptance only.

- [ ] **Step 1: Prove the version-match release gate fails before the bump**

Run:

```zsh
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)" = "0.1.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)" = "1"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Scripts/package-release.sh 0.2.0 .build/artifacts
```

Expected: the first two checks pass; packaging exits `65` before building and prints `release version 0.2.0 does not match app version 0.1.0`.

- [ ] **Step 2: Bump only the marketing and build versions**

Use `apply_patch` to make this exact change in `Resources/Info.plist`:

```diff
-  <key>CFBundleShortVersionString</key><string>0.1.0</string>
-  <key>CFBundleVersion</key><string>1</string>
+  <key>CFBundleShortVersionString</key><string>0.2.0</string>
+  <key>CFBundleVersion</key><string>2</string>
```

- [ ] **Step 3: Validate the plist and version values**

Run:

```zsh
plutil -lint Resources/Info.plist
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)" = "0.2.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)" = "2"
git diff --check
git diff -- Resources/Info.plist
```

Expected: `plutil` reports `OK`; both exact value checks pass; the diff changes only the two string values.

- [ ] **Step 4: Run the complete automated release gate**

Run:

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Scripts/package-release.sh 0.2.0 .build/artifacts
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Scripts/verify-entitlements.sh .build/release/Tokenboard.app
```

Expected: the Swift suite has zero failures (the opt-in benchmark may remain skipped); the universal archive is written to `.build/artifacts/Tokenboard-0.2.0.zip`; signed-bundle verification passes.

- [ ] **Step 5: Inspect the local archive contract**

Run:

```zsh
TOKENBOARD_LOCAL_VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tokenboard-0.2.0-local.XXXXXX")"
/usr/bin/ditto -x -k .build/artifacts/Tokenboard-0.2.0.zip "$TOKENBOARD_LOCAL_VERIFY_DIR"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TOKENBOARD_LOCAL_VERIFY_DIR/Tokenboard.app/Contents/Info.plist")" = "0.2.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TOKENBOARD_LOCAL_VERIFY_DIR/Tokenboard.app/Contents/Info.plist")" = "2"
test "$(/usr/bin/lipo -archs "$TOKENBOARD_LOCAL_VERIFY_DIR/Tokenboard.app/Contents/MacOS/TokenboardApp")" = "x86_64 arm64" \
  || test "$(/usr/bin/lipo -archs "$TOKENBOARD_LOCAL_VERIFY_DIR/Tokenboard.app/Contents/MacOS/TokenboardApp")" = "arm64 x86_64"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Scripts/verify-entitlements.sh "$TOKENBOARD_LOCAL_VERIFY_DIR/Tokenboard.app"
/usr/bin/shasum -a 256 .build/artifacts/Tokenboard-0.2.0.zip
```

Expected: the extracted app reports version `0.2.0`, build `2`, exactly `arm64` and `x86_64`, valid entitlements, and one SHA-256 digest.

Clean only the validated local extraction:

```zsh
case "$TOKENBOARD_LOCAL_VERIFY_DIR" in
  "${TMPDIR:-/tmp}"/tokenboard-0.2.0-local.*) ;;
  *) print -u2 'Refusing unexpected local verification directory'; exit 1 ;;
esac
/bin/rm -rf -- "$TOKENBOARD_LOCAL_VERIFY_DIR"
```

- [ ] **Step 6: Commit the version-only release preparation**

Run:

```zsh
git add Resources/Info.plist
git diff --cached --check
git diff --cached --stat
git commit -m "chore: prepare Tokenboard 0.2.0"
git status --short --branch
```

Expected: the commit changes only `Resources/Info.plist`; the Tokenboard worktree is clean and remains ahead of `origin/main` without a push.

### Task 2: Complete the human native release acceptance

**Files:**
- Exercise: `.build/release/Tokenboard.app`
- Reference: `CONTRIBUTING.md:30`

**Interfaces:**
- Consumes: the exact locally built `0.2.0` universal app from Task 1.
- Produces: an explicit user report containing initial-import time, incremental-refresh time, peak resident memory, five-minute sandbox/CPU/process/network/memory results, and synthetic deletion-retention confirmation. Task 3 consumes that report verbatim for release notes.

- [ ] **Step 1: Present the exact human acceptance checklist and pause**

Tell the user to open `/Users/typically/Workspace/tokenboard/.build/release/Tokenboard.app` themselves and perform all checks below with synthetic test roots where data mutation is involved:

1. Select test Claude Code and Codex roots and start a local import.
2. Record the initial-import time.
3. Leave both roots unchanged for five minutes.
4. In Activity Monitor, report Sandbox `Yes`, CPU settling to `0.0%` between events, no child/helper Tokenboard process, zero sent and received bytes, no memory growth, and peak resident memory.
5. Copy one synthetic fixture into a temporary granted root, record incremental-refresh time, delete only that synthetic copy, refresh, and confirm the committed aggregate remains.

Do not continue to Task 3 until the user explicitly reports every result. A statement such as `done` without the metrics and observations does not satisfy this gate.

- [ ] **Step 2: Validate and preserve the acceptance report for release notes**

Check that the response includes:

- Initial-import time with units.
- Incremental-refresh time with units.
- Peak resident memory with units.
- A full five-minute idle interval.
- Sandbox `Yes`.
- CPU `0.0%` between events.
- No child/helper process.
- Zero network bytes sent and received.
- No memory growth during the idle interval.
- The committed aggregate remained after deleting only the synthetic source copy.

Repeat Step 1 for any missing result. Preserve the accepted wording in the task state; do not invent or normalize a measurement the user did not report.

### Task 3: Publish and verify the GitHub release

**Files:**
- Mutate remote: `Typiqally/tokenboard` branch `main`
- Create remote tag: `Typiqally/tokenboard` tag `v0.2.0`
- Verify remote workflow: `.github/workflows/release.yml`
- Edit remote release notes: GitHub Release `v0.2.0`

**Interfaces:**
- Consumes: the clean committed Tokenboard SHA from Task 1 and the complete human acceptance report from Task 2.
- Produces: a successful GitHub Release `v0.2.0` with one workflow-built `Tokenboard-0.2.0.zip`, its verified SHA-256 digest, and release notes containing the human acceptance report. Task 4 consumes the published digest.

- [ ] **Step 1: Resolve and verify every remote target before mutation**

Run:

```zsh
git status --porcelain
git fetch origin --prune --tags
git remote get-url origin
git rev-list --left-right --count origin/main...main
git tag --list v0.2.0
git ls-remote --tags origin refs/tags/v0.2.0
gh release view v0.2.0 --repo Typiqally/tokenboard
```

Expected:

- The worktree output is empty.
- The remote URL resolves to `git@github.com:Typiqally/tokenboard.git`.
- `git rev-list` reports `0` commits on the remote-only side and at least one local commit on the local-only side.
- Both local and remote tag queries print nothing.
- `gh release view` exits nonzero because `v0.2.0` does not exist.

Stop if `origin/main` is ahead, the worktree is dirty, or any tag/release already exists; reconcile without force-pushing or replacing remote state.

- [ ] **Step 2: Push main and require its exact CI run to pass**

Run:

```zsh
TOKENBOARD_RELEASE_SHA="$(git rev-parse HEAD)"
git push origin main
git ls-remote origin refs/heads/main
```

Confirm the remote SHA equals `TOKENBOARD_RELEASE_SHA`. Then resolve the CI run whose `headSha` equals that exact SHA:

```zsh
gh run list --repo Typiqally/tokenboard --workflow CI --commit "$TOKENBOARD_RELEASE_SHA" \
  --limit 10 --json databaseId,headSha,status,conclusion,url
```

If GitHub has not registered the run yet, poll again in a later tool call before resolving the ID below.

Resolve and watch the exact run ID with:

```zsh
TOKENBOARD_MAIN_CI_RUN_ID="$(
  gh run list --repo Typiqally/tokenboard --workflow CI --commit "$TOKENBOARD_RELEASE_SHA" \
    --limit 10 --json databaseId,headSha,headBranch \
    --jq ".[] | select(.headSha == \"$TOKENBOARD_RELEASE_SHA\" and .headBranch == \"main\") | .databaseId" \
    | head -1
)"
test -n "$TOKENBOARD_MAIN_CI_RUN_ID"
gh run watch "$TOKENBOARD_MAIN_CI_RUN_ID" --repo Typiqally/tokenboard --exit-status
```

Expected: main is a fast-forward push and the exact-SHA CI run completes with `success` before tagging.

- [ ] **Step 3: Create and push the immutable annotated tag**

Re-run the absence checks, then mutate only the resolved tag:

```zsh
TOKENBOARD_RELEASE_SHA="$(git rev-parse HEAD)"
test -z "$(git tag --list v0.2.0)"
test -z "$(git ls-remote --tags origin refs/tags/v0.2.0)"
git tag -a v0.2.0 -m "Tokenboard 0.2.0" "$TOKENBOARD_RELEASE_SHA"
git show --no-patch --decorate v0.2.0
git push origin refs/tags/v0.2.0
```

Expected: the annotated tag points to `TOKENBOARD_RELEASE_SHA` and the push creates exactly `refs/tags/v0.2.0`.

- [ ] **Step 4: Wait for both tag workflows and inspect failures before proceeding**

Resolve runs with the exact release SHA:

```zsh
TOKENBOARD_RELEASE_SHA="$(git rev-parse v0.2.0^{commit})"
gh run list --repo Typiqally/tokenboard --workflow Release --commit "$TOKENBOARD_RELEASE_SHA" \
  --limit 10 --json databaseId,headSha,headBranch,status,conclusion,url
gh run list --repo Typiqally/tokenboard --workflow CI --commit "$TOKENBOARD_RELEASE_SHA" \
  --limit 10 --json databaseId,headSha,headBranch,event,status,conclusion,url
```

Resolve and watch the tag-triggered Release and CI run IDs:

```zsh
TOKENBOARD_RELEASE_RUN_ID="$(
  gh run list --repo Typiqally/tokenboard --workflow Release --commit "$TOKENBOARD_RELEASE_SHA" \
    --limit 10 --json databaseId,headSha,headBranch \
    --jq ".[] | select(.headSha == \"$TOKENBOARD_RELEASE_SHA\" and .headBranch == \"v0.2.0\") | .databaseId" \
    | head -1
)"
TOKENBOARD_TAG_CI_RUN_ID="$(
  gh run list --repo Typiqally/tokenboard --workflow CI --commit "$TOKENBOARD_RELEASE_SHA" \
    --limit 10 --json databaseId,headSha,headBranch \
    --jq ".[] | select(.headSha == \"$TOKENBOARD_RELEASE_SHA\" and .headBranch == \"v0.2.0\") | .databaseId" \
    | head -1
)"
test -n "$TOKENBOARD_RELEASE_RUN_ID"
test -n "$TOKENBOARD_TAG_CI_RUN_ID"
gh run watch "$TOKENBOARD_RELEASE_RUN_ID" --repo Typiqally/tokenboard --exit-status
gh run watch "$TOKENBOARD_TAG_CI_RUN_ID" --repo Typiqally/tokenboard --exit-status
```

Expected: both runs complete with `success`. If either fails, inspect the failing value of `TOKENBOARD_RELEASE_RUN_ID` or `TOKENBOARD_TAG_CI_RUN_ID` with `gh run view "$TOKENBOARD_RELEASE_RUN_ID" --repo Typiqally/tokenboard --log-failed` or the corresponding tag-CI command; do not update Homebrew.

- [ ] **Step 5: Download and verify the workflow-built public asset**

Run:

```zsh
gh release view v0.2.0 --repo Typiqally/tokenboard \
  --json tagName,name,isDraft,isPrerelease,url,assets
TOKENBOARD_PUBLISHED_VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tokenboard-0.2.0-published.XXXXXX")"
gh release download v0.2.0 --repo Typiqally/tokenboard \
  --pattern 'Tokenboard-0.2.0.zip' \
  --dir "$TOKENBOARD_PUBLISHED_VERIFY_DIR"
TOKENBOARD_PUBLISHED_SHA256="$(
  /usr/bin/shasum -a 256 "$TOKENBOARD_PUBLISHED_VERIFY_DIR/Tokenboard-0.2.0.zip" \
    | /usr/bin/awk '{print $1}'
)"
print -r -- "$TOKENBOARD_PUBLISHED_SHA256"
print -r -- "$TOKENBOARD_PUBLISHED_SHA256" | rg -q '^[0-9a-f]{64}$'
/usr/bin/ditto -x -k "$TOKENBOARD_PUBLISHED_VERIFY_DIR/Tokenboard-0.2.0.zip" \
  "$TOKENBOARD_PUBLISHED_VERIFY_DIR/extracted"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TOKENBOARD_PUBLISHED_VERIFY_DIR/extracted/Tokenboard.app/Contents/Info.plist")" = "0.2.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TOKENBOARD_PUBLISHED_VERIFY_DIR/extracted/Tokenboard.app/Contents/Info.plist")" = "2"
test "$(/usr/bin/lipo -archs "$TOKENBOARD_PUBLISHED_VERIFY_DIR/extracted/Tokenboard.app/Contents/MacOS/TokenboardApp")" = "x86_64 arm64" \
  || test "$(/usr/bin/lipo -archs "$TOKENBOARD_PUBLISHED_VERIFY_DIR/extracted/Tokenboard.app/Contents/MacOS/TokenboardApp")" = "arm64 x86_64"
Scripts/verify-entitlements.sh "$TOKENBOARD_PUBLISHED_VERIFY_DIR/extracted/Tokenboard.app"
```

Expected: the release is neither draft nor prerelease; it contains exactly the requested archive; the extracted app is version `0.2.0`, build `2`, universal, and entitlement-clean. Preserve the printed 64-character SHA-256 as `TOKENBOARD_PUBLISHED_SHA256` for Task 4.

- [ ] **Step 6: Add the verified native acceptance to the generated release notes**

Read the generated notes without changing them:

```zsh
gh release view v0.2.0 --repo Typiqally/tokenboard --json body --jq .body
```

Set `TOKENBOARD_ACCEPTANCE_INITIAL_IMPORT`, `TOKENBOARD_ACCEPTANCE_INCREMENTAL_REFRESH`, and `TOKENBOARD_ACCEPTANCE_PEAK_RSS` to the three verbatim measurement strings accepted in Task 2. Use the following command so the generated changelog remains intact and one exact native-acceptance section is appended:

```zsh
test -n "$TOKENBOARD_ACCEPTANCE_INITIAL_IMPORT"
test -n "$TOKENBOARD_ACCEPTANCE_INCREMENTAL_REFRESH"
test -n "$TOKENBOARD_ACCEPTANCE_PEAK_RSS"
TOKENBOARD_GENERATED_RELEASE_BODY="$(
  gh release view v0.2.0 --repo Typiqally/tokenboard --json body --jq .body
)"
TOKENBOARD_NATIVE_ACCEPTANCE_BODY="$(printf '%s\n' \
  '## Native release acceptance' \
  '' \
  'Completed on 2026-08-10 against the universal Tokenboard 0.2.0 release candidate.' \
  '' \
  '- Five-minute idle check: Sandbox Yes; CPU settled to 0.0% between filesystem events; no child/helper process; zero network bytes sent and received; memory did not grow.' \
  "- Initial historical import: $TOKENBOARD_ACCEPTANCE_INITIAL_IMPORT." \
  "- Incremental refresh: $TOKENBOARD_ACCEPTANCE_INCREMENTAL_REFRESH." \
  "- Peak resident memory: $TOKENBOARD_ACCEPTANCE_PEAK_RSS." \
  '- Synthetic deletion-retention check: committed aggregate remained after deleting only the synthetic source copy.'
)"
gh release edit v0.2.0 --repo Typiqally/tokenboard \
  --notes "${TOKENBOARD_GENERATED_RELEASE_BODY}

${TOKENBOARD_NATIVE_ACCEPTANCE_BODY}"
```

Then verify:

```zsh
gh release view v0.2.0 --repo Typiqally/tokenboard --json body,url --jq '.body, .url'
```

Expected: the body retains the generated notes and contains the exact user-reported times and memory measurement under one `Native release acceptance` heading.

### Task 4: Update and verify the Homebrew cask

**Files:**
- Modify: `/opt/homebrew/Library/Taps/typiqally/homebrew-tokenboard/Casks/tokenboard.rb:2`
- Mutate remote: `Typiqally/homebrew-tokenboard` branch `main`

**Interfaces:**
- Consumes: `TOKENBOARD_PUBLISHED_SHA256`, the exact 64-character digest printed from the public GitHub Release asset in Task 3.
- Produces: a clean Homebrew tap commit on `main` whose cask version is `0.2.0`, whose SHA-256 equals `TOKENBOARD_PUBLISHED_SHA256`, and whose fetch resolves the public `v0.2.0` archive.

- [ ] **Step 1: Resolve and synchronize the exact tap checkout**

Run:

```zsh
TOKENBOARD_TAP_DIR="/opt/homebrew/Library/Taps/typiqally/homebrew-tokenboard"
test -d "$TOKENBOARD_TAP_DIR/.git"
test "$(git -C "$TOKENBOARD_TAP_DIR" remote get-url origin)" = "https://github.com/typiqally/homebrew-tokenboard"
test -z "$(git -C "$TOKENBOARD_TAP_DIR" status --porcelain)"
git -C "$TOKENBOARD_TAP_DIR" fetch origin --prune
git -C "$TOKENBOARD_TAP_DIR" merge --ff-only origin/main
git -C "$TOKENBOARD_TAP_DIR" status --short --branch
```

Expected: the existing tap checkout is clean, remains on `main`, and fast-forwards to `origin/main` without a merge commit.

- [ ] **Step 2: Update only the cask version and published checksum**

First prove the consumed checksum is exact:

```zsh
print -r -- "$TOKENBOARD_PUBLISHED_SHA256" | rg -q '^[0-9a-f]{64}$'
```

Use `apply_patch` on `/opt/homebrew/Library/Taps/typiqally/homebrew-tokenboard/Casks/tokenboard.rb` to change:

```diff
-  version "0.1.0"
-  sha256 "e37618ef13705bc9d989f8eae0d800d37d1ec100d7fec426bf10bf3e0d912906"
+  version "0.2.0"
```

In the same patch, add the `sha256` line back at the same location with the literal 64-character value of `TOKENBOARD_PUBLISHED_SHA256` produced by Task 3. The new SHA line must contain the digest itself, not the shell variable name or descriptive text.

Confirm the diff changes exactly two lines:

```zsh
git -C "$TOKENBOARD_TAP_DIR" diff --check
git -C "$TOKENBOARD_TAP_DIR" diff -- Casks/tokenboard.rb
test "$(rg -o 'version "[^"]+"' "$TOKENBOARD_TAP_DIR/Casks/tokenboard.rb")" = 'version "0.2.0"'
test "$(rg -o 'sha256 "[0-9a-f]+"' "$TOKENBOARD_TAP_DIR/Casks/tokenboard.rb" | cut -d'"' -f2)" = "$TOKENBOARD_PUBLISHED_SHA256"
```

- [ ] **Step 3: Audit, style, and fetch the updated cask without installing it**

Run:

```zsh
brew style typiqally/tokenboard/tokenboard
brew audit --cask --strict --online typiqally/tokenboard/tokenboard
brew fetch --cask --force typiqally/tokenboard/tokenboard
brew info --cask typiqally/tokenboard/tokenboard
```

Expected: style and audit pass; fetch downloads the `v0.2.0` archive and verifies `TOKENBOARD_PUBLISHED_SHA256`; info reports version `0.2.0`. Do not run `brew install`, `brew upgrade`, or `xattr` during this task.

- [ ] **Step 4: Commit and push only the cask update**

Run:

```zsh
git -C "$TOKENBOARD_TAP_DIR" add Casks/tokenboard.rb
git -C "$TOKENBOARD_TAP_DIR" diff --cached --check
git -C "$TOKENBOARD_TAP_DIR" diff --cached --stat
git -C "$TOKENBOARD_TAP_DIR" commit -m "tokenboard 0.2.0"
git -C "$TOKENBOARD_TAP_DIR" push origin main
git -C "$TOKENBOARD_TAP_DIR" status --short --branch
```

Expected: one two-line cask commit is pushed to `Typiqally/homebrew-tokenboard/main`, and the tap worktree is clean and synchronized with `origin/main`.

- [ ] **Step 5: Verify public release and tap state, then clean temporary artifacts**

Run:

```zsh
gh release view v0.2.0 --repo Typiqally/tokenboard \
  --json tagName,name,isDraft,isPrerelease,url,assets
gh api repos/Typiqally/homebrew-tokenboard/contents/Casks/tokenboard.rb \
  --jq .content | base64 --decode
git -C /Users/typically/Workspace/tokenboard status --short --branch
git -C "$TOKENBOARD_TAP_DIR" status --short --branch
```

Expected: GitHub reports `v0.2.0` as the non-draft, non-prerelease latest release with `Tokenboard-0.2.0.zip`; the public cask reports version `0.2.0` and `TOKENBOARD_PUBLISHED_SHA256`; both local worktrees are clean and synchronized with their remotes.

Clean only the validated published-asset directory:

```zsh
case "$TOKENBOARD_PUBLISHED_VERIFY_DIR" in
  "${TMPDIR:-/tmp}"/tokenboard-0.2.0-published.*) ;;
  *) print -u2 'Refusing unexpected published verification directory'; exit 1 ;;
esac
/bin/rm -rf -- "$TOKENBOARD_PUBLISHED_VERIFY_DIR"
```
