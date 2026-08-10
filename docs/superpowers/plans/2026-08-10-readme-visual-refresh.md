# README Visual Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Tokenboard an appealing, privacy-safe GitHub README opening with a faithful graphite SVG preview of its native menu-bar experience and a more scannable user-first information hierarchy.

**Architecture:** Add one static, self-contained vector asset under `.github/assets/`, then reorganize the existing README around that asset without changing product behavior. The SVG reconstructs the current AppKit menu with synthetic data; the Markdown remains the accessible source of essential meaning and preserves the repository's privacy, pricing, install, build, and limitation contracts.

**Tech Stack:** GitHub-flavored Markdown, SVG 1.1-compatible XML, native macOS command-line validation (`xmllint`, `rg`, SwiftPM, `codesign` verification), and the approved browser-based visual companion.

## Global Constraints

- Execute in the existing `main` checkout, as explicitly requested; do not create a worktree or feature branch.
- Create only `.github/assets/tokenboard-hero.svg` and modify only `README.md` for the product deliverable.
- Do not change Swift source, tests, app behavior, the application bundle, entitlements, dependencies, or release automation.
- Keep the hero approximately `1200 × 420`, static, vector-only, and self-contained, with no remote image, stylesheet, font, script, external URL reference, raster data, animation, interaction, tracking, or analytics.
- Use the approved B1 Graphite Desktop direction with the exact sample values `1.28M`, `THIS MONTH`, `UPDATED 1 MIN. AGO`, `1,284,930 tokens`, `≈ €4.68 API equivalent`, `EUR`, and `Tokens`.
- Use the exact editorial copy `TOKENBOARD FOR MACOS`, `Your local AI usage. One glance away.`, and `Exact Claude Code and Codex token totals, private on your Mac.`
- Show the trust signals `Native AppKit`, `Local only`, and `No telemetry`.
- Include SVG `<title>` and `<desc>` metadata, descriptive Markdown alt text, and the caption `Product preview with sample data.`
- Keep essential meaning in Markdown, not only inside the image, and make the SVG scale proportionally without clipping or horizontal scrolling.
- Keep the graphite background baked into the SVG so it works on GitHub light and dark themes.
- Do not use Apple logos, fake analytics, ornamental charts, loud brand gradients, fake window chrome, nonportable emoji, or claims absent from `PRODUCT.md`, `PRIVACY.md`, and `CONTRIBUTING.md`.
- Keep copy direct, specific, and calm. Say `menu bar`, not `toolbar`, and always qualify `API-equivalent` as an estimate rather than a bill.
- Preserve macOS 14 Sonoma, Apple's Swift 6 toolchain, no third-party runtime dependencies, Homebrew quarantine disclosure, build/signing facts, pricing-update boundaries, known limits, and the optional audit disclaimer.
- Do not launch Tokenboard during implementation; the README may continue to document the existing `open .build/release/Tokenboard.app` command.

---

## File Map

- Create `.github/assets/tokenboard-hero.svg`: the single public README hero, including its accessible metadata, editorial copy, reconstructed menu preview, and synthetic sample values.
- Modify `README.md`: the complete user-facing information architecture, local asset reference, alt text, caption, install path, benefits, privacy model, workflow, pricing caveats, source build instructions, known limits, and reference links.
- Read only `Sources/TokenboardApp/MenuSummaryView.swift`: authoritative summary typography hierarchy and uppercase context/recency behavior.
- Read only `Sources/TokenboardApp/MenuController.swift`: authoritative top-level menu order, labels, shortcuts, and SF Symbol meanings.
- Read only `Tests/TokenboardAppTests/NativePresentationTests.swift`: executable contract for menu labels and action order.
- Read only `PRODUCT.md`, `PRIVACY.md`, and `CONTRIBUTING.md`: authoritative product voice, capability, privacy, and verification claims.
- Use `.superpowers/brainstorm/<session>/content/` only for ignored visual-review artifacts; do not commit companion files.

### Task 1: Add the B1 Graphite hero asset

**Files:**
- Create: `.github/assets/tokenboard-hero.svg`
- Reference: `Sources/TokenboardApp/MenuSummaryView.swift:29`
- Reference: `Sources/TokenboardApp/MenuController.swift:63`
- Reference: `Tests/TokenboardAppTests/NativePresentationTests.swift:9`

**Interfaces:**
- Consumes: the approved copy, sample values, and B1 Graphite direction in `docs/superpowers/specs/2026-08-10-readme-visual-refresh-design.md`.
- Produces: a valid self-contained SVG at `.github/assets/tokenboard-hero.svg`, referenced by the exact relative Markdown target `.github/assets/tokenboard-hero.svg` in Task 2.

- [ ] **Step 1: Confirm the asset contract fails before implementation**

Run:

```zsh
test -f .github/assets/tokenboard-hero.svg \
  && xmllint --noout .github/assets/tokenboard-hero.svg
```

Expected: FAIL because `.github/assets/tokenboard-hero.svg` does not exist.

- [ ] **Step 2: Create the exact self-contained SVG**

Use `apply_patch` to create `.github/assets/tokenboard-hero.svg` with this content:

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="420" viewBox="0 0 1200 420" role="img" aria-labelledby="tokenboard-title tokenboard-description">
  <title id="tokenboard-title">Tokenboard native macOS menu-bar preview</title>
  <desc id="tokenboard-description">A graphite product banner with sample data. The menu bar shows 1.28M tokens, and the open Tokenboard menu shows This Month, 1,284,930 tokens, approximately 4 euros and 68 cents API equivalent, EUR currency, token display, and native refresh, pricing, settings, and quit actions.</desc>
  <defs>
    <linearGradient id="background" x1="0" y1="0" x2="1200" y2="420" gradientUnits="userSpaceOnUse">
      <stop stop-color="#12151B"/>
      <stop offset="0.58" stop-color="#181C24"/>
      <stop offset="1" stop-color="#0F1218"/>
    </linearGradient>
    <radialGradient id="glow" cx="0" cy="0" r="1" gradientTransform="translate(948 176) rotate(138) scale(356 270)" gradientUnits="userSpaceOnUse">
      <stop stop-color="#7B8DA8" stop-opacity="0.23"/>
      <stop offset="0.55" stop-color="#41506A" stop-opacity="0.09"/>
      <stop offset="1" stop-color="#12151B" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="desktop" x1="730" y1="36" x2="1146" y2="398" gradientUnits="userSpaceOnUse">
      <stop stop-color="#343A46"/>
      <stop offset="1" stop-color="#232833"/>
    </linearGradient>
    <linearGradient id="menu" x1="772" y1="88" x2="1108" y2="394" gradientUnits="userSpaceOnUse">
      <stop stop-color="#252A34"/>
      <stop offset="1" stop-color="#1C2028"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="150%">
      <feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#000000" flood-opacity="0.42"/>
    </filter>
  </defs>

  <rect width="1200" height="420" rx="24" fill="url(#background)"/>
  <rect width="1200" height="420" rx="24" fill="url(#glow)"/>
  <path d="M0 419.5H1200" stroke="#FFFFFF" stroke-opacity="0.06"/>

  <g font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', Arial, sans-serif">
    <rect x="64" y="62" width="3" height="31" rx="1.5" fill="#AAB7C9"/>
    <text x="83" y="83" fill="#AAB7C9" font-size="13" font-weight="700" letter-spacing="2.2">TOKENBOARD FOR MACOS</text>

    <text x="64" y="145" fill="#F6F8FB" font-size="48" font-weight="700" letter-spacing="-1.8">Your local AI usage.</text>
    <text x="64" y="199" fill="#F6F8FB" font-size="48" font-weight="700" letter-spacing="-1.8">One glance away.</text>

    <text x="64" y="244" fill="#B5BECC" font-size="18" font-weight="450">Exact Claude Code and Codex token totals,</text>
    <text x="64" y="270" fill="#B5BECC" font-size="18" font-weight="450">private on your Mac.</text>

    <g font-size="13" font-weight="600" fill="#D9DFE8">
      <rect x="64" y="310" width="120" height="34" rx="17" fill="#FFFFFF" fill-opacity="0.07" stroke="#FFFFFF" stroke-opacity="0.11"/>
      <circle cx="82" cy="327" r="4" fill="#8FA4C2"/>
      <text x="94" y="332">Native AppKit</text>

      <rect x="194" y="310" width="103" height="34" rx="17" fill="#FFFFFF" fill-opacity="0.07" stroke="#FFFFFF" stroke-opacity="0.11"/>
      <circle cx="212" cy="327" r="4" fill="#8FA4C2"/>
      <text x="224" y="332">Local only</text>

      <rect x="307" y="310" width="122" height="34" rx="17" fill="#FFFFFF" fill-opacity="0.07" stroke="#FFFFFF" stroke-opacity="0.11"/>
      <circle cx="325" cy="327" r="4" fill="#8FA4C2"/>
      <text x="337" y="332">No telemetry</text>
    </g>

    <text x="64" y="380" fill="#747F90" font-size="12" font-weight="500" letter-spacing="0.3">NATIVE APPKIT  ·  SANDBOXED  ·  EVENT-DRIVEN</text>

    <g filter="url(#shadow)">
      <rect x="716" y="26" width="438" height="376" rx="24" fill="url(#desktop)" stroke="#FFFFFF" stroke-opacity="0.12"/>
      <rect x="734" y="43" width="402" height="38" rx="11" fill="#11151C" fill-opacity="0.72" stroke="#FFFFFF" stroke-opacity="0.08"/>
      <circle cx="755" cy="62" r="3" fill="#778397"/>
      <circle cx="768" cy="62" r="3" fill="#778397" fill-opacity="0.62"/>
      <rect x="1025" y="49" width="94" height="26" rx="13" fill="#DCE3ED" fill-opacity="0.14" stroke="#FFFFFF" stroke-opacity="0.12"/>
      <text x="1072" y="67" text-anchor="middle" fill="#F2F5F9" font-size="14" font-weight="650">1.28M</text>

      <rect x="760" y="86" width="358" height="302" rx="17" fill="url(#menu)" stroke="#FFFFFF" stroke-opacity="0.15"/>
      <path d="M777 190.5H1101" stroke="#FFFFFF" stroke-opacity="0.11"/>
      <path d="M777 279.5H1101" stroke="#FFFFFF" stroke-opacity="0.11"/>
      <path d="M777 358.5H1101" stroke="#FFFFFF" stroke-opacity="0.11"/>

      <text x="780" y="112" fill="#7F8998" font-size="10" font-weight="700" letter-spacing="0.9">THIS MONTH</text>
      <text x="1098" y="112" text-anchor="end" fill="#7F8998" font-size="10" font-weight="700" letter-spacing="0.65">UPDATED 1 MIN. AGO</text>
      <text x="780" y="145" fill="#F3F5F8" font-size="21" font-weight="650">1,284,930 tokens</text>
      <text x="780" y="171" fill="#B2BBC8" font-size="13" font-weight="500">≈ €4.68 API equivalent</text>

      <g fill="#E7EBF1" font-size="14" font-weight="500">
        <text x="780" y="214">Period: This Month</text>
        <text x="780" y="241">Currency: EUR</text>
        <text x="780" y="268">Menu Bar: Tokens</text>
      </g>
      <g fill="none" stroke="#9BA5B4" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
        <path d="M1092 207l5 5-5 5"/>
        <path d="M1092 234l5 5-5 5"/>
        <path d="M1092 261l5 5-5 5"/>
      </g>

      <g fill="#E7EBF1" font-size="14" font-weight="500">
        <text x="808" y="305">Refresh Now</text>
        <text x="808" y="329">Pricing</text>
        <text x="808" y="353">Settings</text>
        <text x="780" y="380">Quit Tokenboard</text>
      </g>
      <g fill="none" stroke="#AEB8C6" stroke-width="1.45" stroke-linecap="round" stroke-linejoin="round">
        <path d="M795 294a7 7 0 1 0 1.8 6.7M797 292v5h-5"/>
        <rect x="787" y="316" width="16" height="10" rx="2"/>
        <circle cx="795" cy="321" r="2"/>
        <path d="M790 319h-2M802 323h2"/>
        <circle cx="795" cy="345" r="3.2"/>
        <path d="M795 338v2M795 350v2M788 345h2M800 345h2M790.1 340.1l1.4 1.4M798.5 348.5l1.4 1.4M799.9 340.1l-1.4 1.4M791.5 348.5l-1.4 1.4"/>
      </g>
      <g fill="#737E8E" font-size="12" font-weight="500">
        <text x="1098" y="305" text-anchor="end">⌘ R</text>
        <text x="1098" y="353" text-anchor="end">⌘ ,</text>
        <text x="1098" y="380" text-anchor="end">⌘ Q</text>
      </g>
    </g>
  </g>
</svg>
```

- [ ] **Step 3: Validate XML, required content, and the no-remote-content boundary**

Run:

```zsh
xmllint --noout .github/assets/tokenboard-hero.svg

rg -n 'TOKENBOARD FOR MACOS|Your local AI usage\. One glance away\.|Exact Claude Code and Codex token totals,|1\.28M|THIS MONTH|UPDATED 1 MIN\. AGO|1,284,930 tokens|≈ €4\.68 API equivalent|Currency: EUR|Menu Bar: Tokens|Native AppKit|Local only|No telemetry' \
  .github/assets/tokenboard-hero.svg

if rg -n '(<script|<animate|<set|<foreignObject|<image|href=|src=|@import)' \
  .github/assets/tokenboard-hero.svg; then
  print -u2 'Hero contains a forbidden executable or external-reference construct'
  exit 1
fi

if rg -n 'https?://' .github/assets/tokenboard-hero.svg \
  | rg -v 'xmlns="http://www\.w3\.org/2000/svg"'; then
  print -u2 'Hero contains a non-namespace URL'
  exit 1
fi
```

Expected: `xmllint` exits 0; the required-copy scan prints matching lines; both forbidden-content checks exit 0 without printing a match.

- [ ] **Step 4: Inspect a local rasterization for clipping before committing**

Run:

```zsh
TOKENBOARD_HERO_RENDER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tokenboard-hero.XXXXXX")"
qlmanage -t -s 1200 -o "$TOKENBOARD_HERO_RENDER_DIR" \
  .github/assets/tokenboard-hero.svg >/dev/null
find "$TOKENBOARD_HERO_RENDER_DIR" -maxdepth 1 -type f -print
```

Use the local image viewer on the printed PNG with original detail. Verify the `1200 × 420` composition has no clipped headline, menu panel, sample values, trust pills, or bottom action row; verify the menu remains visually secondary to the headline. Remove only the printed `TOKENBOARD_HERO_RENDER_DIR` after inspection.

Run:

```zsh
test -f "$TOKENBOARD_HERO_RENDER_DIR/tokenboard-hero.svg.png"
/bin/rm -f -- "$TOKENBOARD_HERO_RENDER_DIR/tokenboard-hero.svg.png"
/bin/rmdir -- "$TOKENBOARD_HERO_RENDER_DIR"
```

- [ ] **Step 5: Commit the independently valid hero asset**

Run:

```zsh
git add .github/assets/tokenboard-hero.svg
git diff --cached --check
git commit -m "docs: add Tokenboard README hero"
```

Expected: one new SVG is committed and `git diff --cached --check` reports no errors.

### Task 2: Restructure the README and obtain final visual approval

**Files:**
- Modify: `README.md:1`
- Consume: `.github/assets/tokenboard-hero.svg`
- Reference: `PRODUCT.md:9`
- Reference: `PRIVACY.md:3`
- Reference: `CONTRIBUTING.md:5`

**Interfaces:**
- Consumes: the exact asset path `.github/assets/tokenboard-hero.svg` produced by Task 1.
- Produces: a complete README whose opening image target is `.github/assets/tokenboard-hero.svg`, whose caption is `Product preview with sample data.`, and whose factual claims remain bounded by `PRODUCT.md`, `PRIVACY.md`, and `CONTRIBUTING.md`.

- [ ] **Step 1: Confirm the new README structure is absent**

Run:

```zsh
if rg -q '^!\[Tokenboard native macOS menu-bar preview with sample usage data\]\(\.github/assets/tokenboard-hero\.svg\)$' README.md \
  && rg -q '^\*Product preview with sample data\.\*$' README.md \
  && rg -q '^## At a glance$' README.md \
  && rg -q '^## Private by construction$' README.md; then
  print -u2 'README already contains the complete refreshed opening'
  exit 0
fi
exit 1
```

Expected: FAIL because the current README has no hero, sample-data caption, `At a glance`, or `Private by construction` section.

- [ ] **Step 2: Replace the README with the approved user-first structure**

Use `apply_patch` to replace `README.md` with this exact content:

````markdown
# Tokenboard

A fully native macOS menu-bar app for private, local Claude Code and Codex usage totals.

![Tokenboard native macOS menu-bar preview with sample usage data](.github/assets/tokenboard-hero.svg)

*Product preview with sample data.*

## Install

Install Tokenboard with Homebrew:

```zsh
brew install --cask typiqally/tokenboard/tokenboard
xattr -dr com.apple.quarantine /Applications/Tokenboard.app
```

Tokenboard is not Apple-notarized. Homebrew downloads and verifies the release; the second command explicitly removes macOS's quarantine attribute from the installed app. It does not grant additional permissions: Tokenboard remains sandboxed and asks you to choose its read-only source folders on first launch.

Upgrade with `brew upgrade --cask tokenboard`. Uninstall with `brew uninstall --cask tokenboard`.

## At a glance

- **Exact local totals.** Tokenboard reduces supported Claude Code and Codex usage logs into durable daily token totals.
- **Honest estimates.** API-equivalent values use public list prices, effective dates, and explicit unpriced coverage. They are estimates, never a bill.
- **Useful ranges.** Read Today, This Week, This Month, This Year, or All Time in tokens or a supported display currency: USD, EUR, JPY, GBP, or CNY.

## Private by construction

- One sandboxed native process with no network entitlement or network requests.
- Explicit, read-only folder grants through the native macOS picker; Tokenboard never guesses a source location.
- No telemetry, analytics, helper, daemon, or XPC service.
- Filesystem-event monitoring rather than a polling timer.
- Content-safe daily aggregates and bookkeeping after ingestion—not prompts, responses, tool content, project metadata, paths below the granted roots, raw session IDs, or per-session totals.

See [PRIVACY.md](PRIVACY.md) for the exact local-data and retention boundary.

## How it works

1. Choose the Claude Code and Codex roots through the native folder picker.
2. Approve the optional historical import for the logs currently available.
3. Read exact totals or API-equivalent estimates from the menu bar while Tokenboard follows future filesystem events.

Committed daily aggregates survive later source-log deletion, and recreating an already imported log does not add it again. Tokenboard cannot recover logs that were unavailable or deleted before the first successful import.

## Understanding API-equivalent value

API-equivalent value estimates what the recorded token categories would cost at standard public API list prices. It is not a bill or a report of Claude or ChatGPT subscription spend. It cannot reproduce provider discounts, credits, batch pricing, negotiated terms, or billing-side classification.

Pricing is effective-dated: Tokenboard applies the rate covering each local usage day instead of repricing old usage at today's rate. Tokens from an unknown model or uncovered date still count but remain visibly unpriced rather than guessed. USD is the canonical pricing currency; other display currencies use the latest locally approved conversion snapshot.

## Updating pricing through your agent

Tokenboard never fetches pricing. In Settings, copy the pricing-update prompt and paste it into Claude Code or Codex. The external agent requests its own network or filesystem access, researches the allowed public sources, reports what it used, and writes a complete local candidate.

Tokenboard validates that candidate locally and applies it atomically. An invalid update leaves the last valid catalog active. Valid updates can append history, correct an entry, or remove an unsupported entry; uncertain coverage remains unpriced.

## Build from source

Requirements:

- macOS 14 Sonoma or newer
- Apple's Swift 6 toolchain and macOS SDK
- No third-party runtime dependencies

```zsh
swift test
Scripts/build-app.sh release
Scripts/verify-entitlements.sh .build/release/Tokenboard.app
open .build/release/Tokenboard.app
```

`build-app.sh` creates a native `Tokenboard.app`. Local builds are ad-hoc signed unless `TOKENBOARD_SIGN_IDENTITY` names a signing identity. Version tags publish an ad-hoc-signed universal app for the Homebrew Cask; Developer ID signing and notarization can be added later without changing the install command.

## Known limits

- Totals depend on usage records present in supported local Claude Code and Codex JSONL formats.
- Logs deleted before the first import are unavailable.
- Unknown formats are skipped and reported; unknown models remain counted but unpriced.
- API-equivalent estimates use standard public API list prices, with the limitations described above.
- Calendar buckets reflect the Mac's local timezone at ingestion; changing timezones later does not rewrite historical buckets.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development, verification, and release checks.

The optional contributor audit is only a bounded comparison of currently discoverable live-source aggregates with the checkpointed main ledger file. It is not proof that Tokenboard's full history is equivalent to the files still on disk, and it cannot account for deleted, replaced, or previously ingested history.
````

- [ ] **Step 3: Verify the README structure, local links, and required caveats**

Run:

```zsh
test -f .github/assets/tokenboard-hero.svg

rg -n '^# Tokenboard$|^## Install$|^## At a glance$|^## Private by construction$|^## How it works$|^## Understanding API-equivalent value$|^## Updating pricing through your agent$|^## Build from source$|^## Known limits$' README.md

rg -n '^!\[Tokenboard native macOS menu-bar preview with sample usage data\]\(\.github/assets/tokenboard-hero\.svg\)$|^\*Product preview with sample data\.\*$|not Apple-notarized|does not grant additional permissions|never a bill|no network entitlement|cannot recover logs|never fetches pricing|invalid update leaves the last valid catalog active|macOS 14 Sonoma|Swift 6|No third-party runtime dependencies|optional contributor audit' README.md

TOKENBOARD_INSTALL_LINE="$(rg -n '^## Install$' README.md | cut -d: -f1)"
TOKENBOARD_GLANCE_LINE="$(rg -n '^## At a glance$' README.md | cut -d: -f1)"
test "$TOKENBOARD_INSTALL_LINE" -lt "$TOKENBOARD_GLANCE_LINE"

if rg -n '!\[[^]]*\]\(https?://' README.md; then
  print -u2 'README contains a remotely hosted image'
  exit 1
fi

for TOKENBOARD_README_TARGET in .github/assets/tokenboard-hero.svg PRIVACY.md CONTRIBUTING.md; do
  test -f "$TOKENBOARD_README_TARGET"
done
```

Expected: all required headings and caveats print; Install precedes At a glance; there are no remote images; all three local targets exist.

- [ ] **Step 4: Compare every factual claim against the repository contracts**

Read these exact source sections side by side with the README diff:

```zsh
sed -n '9,84p' PRODUCT.md
sed -n '1,31p' PRIVACY.md
sed -n '1,40p' CONTRIBUTING.md
git diff -- README.md
```

Confirm all of the following before continuing:

- The provider scope remains Claude Code and Codex only.
- `Exact` describes token totals from supported local records, not invoice equivalence or deleted-log recovery.
- The currencies remain USD, EUR, JPY, GBP, and CNY, with canonical USD pricing and locally approved conversion data.
- The persistence sentence does not imply that only aggregates are stored; it preserves the content-safe bookkeeping boundary.
- The no-network, sandbox, read-only grant, no-helper, no-daemon, no-XPC, no-telemetry, and event-driven claims match `PRIVACY.md`.
- The pricing text keeps external-agent permissions separate from Tokenboard and preserves local validation, atomic apply, and last-valid-catalog behavior.
- The build requirements and signing/notarization text remain unchanged in meaning.
- The optional audit remains explicitly bounded and cannot be mistaken for proof of full-history equivalence.

- [ ] **Step 5: Run repository and asset verification**

Run:

```zsh
xmllint --noout .github/assets/tokenboard-hero.svg
git diff --check
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-app.sh release
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/verify-entitlements.sh .build/release/Tokenboard.app
```

Expected: the SVG is valid XML; the diff has no whitespace errors; the Swift suite has zero failures (the opt-in benchmark may remain skipped); the release app builds; and entitlement verification passes.

- [ ] **Step 6: Render desktop and narrow README openings in the visual companion**

Start a new persistent companion session with the already approved companion workflow:

```zsh
/Users/typically/.codex/plugins/cache/claude-plugins-official/superpowers/6.2.0/skills/brainstorming/scripts/start-server.sh \
  --project-dir /Users/typically/Workspace/tokenboard \
  --open
```

Keep the command running in the persistent execution session. Record the returned `url`, `screen_dir`, and session directory. Copy the already validated hero into the ignored companion content directory, then use `apply_patch` to create `readme-final-review.html` there:

```zsh
TOKENBOARD_README_COMPANION_SESSION="$(
  find .superpowers/brainstorm -mindepth 1 -maxdepth 1 -type d \
    -exec stat -f '%m %N' {} \; \
    | sort -rn \
    | head -1 \
    | cut -d' ' -f2-
)"
TOKENBOARD_README_SCREEN_DIR="$TOKENBOARD_README_COMPANION_SESSION/content"
TOKENBOARD_README_STATE_DIR="$TOKENBOARD_README_COMPANION_SESSION/state"
test -f "$TOKENBOARD_README_STATE_DIR/server-info"
test ! -f "$TOKENBOARD_README_STATE_DIR/server-stopped"
cp .github/assets/tokenboard-hero.svg "$TOKENBOARD_README_SCREEN_DIR/tokenboard-hero.svg"
```

The companion HTML must contain:

```html
<style>
  .review-grid { display:grid; grid-template-columns:minmax(0, 1fr) 390px; gap:24px; align-items:start; }
  .readme-preview { background:#fff; color:#1f2328; border:1px solid #d0d7de; border-radius:12px; padding:28px; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
  .readme-preview h1 { font-size:32px; line-height:1.25; margin:0 0 16px; border-bottom:1px solid #d8dee4; padding-bottom:10px; }
  .readme-preview h2 { font-size:24px; line-height:1.25; margin:24px 0 16px; border-bottom:1px solid #d8dee4; padding-bottom:8px; }
  .readme-preview p, .readme-preview li { font-size:16px; line-height:1.55; }
  .readme-preview img { display:block; width:100%; height:auto; margin:18px 0 8px; }
  .readme-preview .caption { color:#656d76; font-size:13px; font-style:italic; }
  .readme-preview pre { overflow:auto; background:#f6f8fa; border-radius:6px; padding:14px; font-size:13px; }
  .narrow-shell { width:390px; }
  @media (max-width: 980px) { .review-grid { grid-template-columns:1fr; } .narrow-shell { width:100%; max-width:390px; } }
</style>
<h2>Final README visual review</h2>
<p class="subtitle">The exact SVG hero at a typical GitHub desktop width and a narrow README width. Check hierarchy, clipping, contrast, and whether Install appears immediately after the preview.</p>
<div class="review-grid">
  <div>
    <div class="label">Desktop · flexible width</div>
    <article class="readme-preview">
      <h1>Tokenboard</h1>
      <p>A fully native macOS menu-bar app for private, local Claude Code and Codex usage totals.</p>
      <img src="/files/tokenboard-hero.svg" alt="Tokenboard native macOS menu-bar preview with sample usage data">
      <p class="caption">Product preview with sample data.</p>
      <h2>Install</h2>
      <p>Install Tokenboard with Homebrew:</p>
      <pre>brew install --cask typiqally/tokenboard/tokenboard
xattr -dr com.apple.quarantine /Applications/Tokenboard.app</pre>
    </article>
  </div>
  <div class="narrow-shell">
    <div class="label">Narrow · 390 px</div>
    <article class="readme-preview">
      <h1>Tokenboard</h1>
      <p>A fully native macOS menu-bar app for private, local Claude Code and Codex usage totals.</p>
      <img src="/files/tokenboard-hero.svg" alt="Tokenboard native macOS menu-bar preview with sample usage data">
      <p class="caption">Product preview with sample data.</p>
      <h2>Install</h2>
      <p>Install Tokenboard with Homebrew:</p>
    </article>
  </div>
</div>
<div class="options" style="margin-top:24px">
  <div class="option" data-choice="approved" onclick="toggleSelect(this)">
    <div class="letter">✓</div>
    <div class="content"><h3>Approve final visual</h3><p>The hero and README opening are ready to ship.</p></div>
  </div>
  <div class="option" data-choice="revise" onclick="toggleSelect(this)">
    <div class="letter">↺</div>
    <div class="content"><h3>Request a revision</h3><p>Return with specific hierarchy, spacing, copy, or contrast feedback.</p></div>
  </div>
</div>
```

Share the complete tokenized companion URL with the user. Pause execution and ask them to inspect both widths and click `Approve final visual` or describe a revision. On the next turn, read the terminal response and `$TOKENBOARD_README_STATE_DIR/events`; do not infer approval from the absence of feedback.

- [ ] **Step 7: Apply visual feedback until the user explicitly approves**

If the user requests a revision, change only `.github/assets/tokenboard-hero.svg` or `README.md` with `apply_patch`, repeat Steps 3–6, and push a newly named companion screen such as `readme-final-review-v2.html`. Never reuse a companion filename.

Expected approval evidence: the user's terminal response explicitly approves the visual, or the latest companion event is a click whose `choice` is `approved` and the user has returned to the terminal.

- [ ] **Step 8: Stop the companion, run the final clean check, and commit**

Stop the exact session created in Step 6:

```zsh
TOKENBOARD_README_COMPANION_SESSION="$(
  find .superpowers/brainstorm -mindepth 1 -maxdepth 1 -type d \
    -exec stat -f '%m %N' {} \; \
    | sort -rn \
    | head -1 \
    | cut -d' ' -f2-
)"
test -f "$TOKENBOARD_README_COMPANION_SESSION/state/server-info"
/Users/typically/.codex/plugins/cache/claude-plugins-official/superpowers/6.2.0/skills/brainstorming/scripts/stop-server.sh \
  "$TOKENBOARD_README_COMPANION_SESSION"
```

Run:

```zsh
git diff --check
git status --short
git diff -- README.md .github/assets/tokenboard-hero.svg
git add README.md .github/assets/tokenboard-hero.svg
git diff --cached --check
git commit -m "docs: refresh Tokenboard README"
git status --short --branch
```

Expected: only the approved README change is newly committed in this task; `.superpowers/` remains ignored; the worktree is clean; and `main` remains ahead of `origin/main` without a push.
