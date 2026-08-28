# Tokenboard

A fully native macOS menu-bar app that turns supported local Claude Code and Codex usage records into durable token totals, hourly and daily trends, private work-pattern insights, and transparent API-equivalent estimates.

![Tokenboard's compact native macOS menu-bar popover and matching History window, with Today, 7D, 30D, and 90D trends shown using sample local usage data.](docs/design/rich-popover-family.svg)

*The current native popover and History surfaces, shown with sample data.*

## Install

### Ask your agent

Copy this prompt into Claude Code, Codex, or another coding agent on your Mac:

```text
Install the latest public release of Tokenboard from
https://github.com/Typiqally/tokenboard.

Prefer the official Homebrew cask typiqally/tokenboard/tokenboard. If Homebrew
is unavailable, download the single app archive from the latest GitHub release,
verify its SHA-256 against GitHub's published asset digest, and place
Tokenboard.app in /Applications. Do not build from source. If Tokenboard is
already installed through Homebrew, upgrade it instead of deleting it manually.

Tokenboard is not Apple-notarized. Remove the quarantine attribute only from
the exact installed path /Applications/Tokenboard.app, then open the app and
confirm the installed version. Do not grant access to any folders for me.

When it opens, tell me to choose my Claude Code and Codex source folders in the
native onboarding screen. Also explain that API-equivalent values stay enabled,
but any missing or outdated model prices remain unpriced until I open
Settings > Pricing, click Copy Pricing Update Prompt, and paste that prompt back
into an agent. Never invent or guess model prices.
```

### Install manually

Install Tokenboard with Homebrew. Tokenboard is not Apple-notarized; Homebrew downloads and verifies the release. The second command explicitly removes macOS's quarantine attribute from the installed app. It does not grant additional permissions: Tokenboard remains sandboxed and asks you to choose its read-only source folders on first launch.

```zsh
brew install --cask typiqally/tokenboard/tokenboard
xattr -dr com.apple.quarantine /Applications/Tokenboard.app
```

Upgrade with `brew upgrade --cask tokenboard`. Uninstall with `brew uninstall --cask tokenboard`.

## At a glance

- **A useful menu-bar value.** Show compact tokens or API-equivalent value for Today, This Week, This Month, This Year, or All Time. The selected period, metric, and display currency persist across launches.
- **A focused native popover.** See the exact total, API-equivalent estimate, update recency, comparison, chart, work-pattern preview, and Claude Code/Codex shares without opening a dashboard. Hover or scrub a chart bar for its exact value, then click to pin it. The popover dismisses on an outside click or Escape.
- **Today through 90 days.** `TODAY` shows hourly progression. `7D`, `30D`, and `90D` show daily trends. These trend ranges are independent from the headline summary period.
- **Drill-down History.** Open the resizable History window for the whole range or a provider, select a chart bar, and expand provider, model, and Input/Cache/Output totals. Switch to Work Patterns for active-hour averages, peak and recurring hours or weekdays, a selectable volume/consistency heatmap, typical first and last activity, and busiest-day context.
- **Automatic local updates.** Native filesystem events provide the fast path. A read-only JSONL metadata reconciliation catches events that the App Sandbox does not deliver, and the recency label doubles as an explicit Refresh action.
- **Honest estimates.** Effective-dated public list prices and locally approved exchange rates power API-equivalent values. Unknown models and uncovered dates remain counted but visibly unpriced; the estimate is never presented as a bill.
- **Optional local companions.** Choose Pokémon, Forest, Village, Old School RuneScape, Age of Empires II, or Minecraft from the visual shelf in General Settings. Every theme is a coherent, art-directed twelve-stage journey built from authentic source artwork or original generated scenes, all bundled at build time, while the popover stays visual-only. The journey follows the existing `TODAY` token source and resets at the start of each local day; `None` keeps the original compact interface.
- **Worlds that are actually inhabited.** Each companion scene is art-directed on its own terms rather than one idle applied six times. Age of Empires II villagers walk out to the trees, chop, and carry the load home while a herd grazes and the settlement gets busier with every age. A village's windows switch on and off room by room while townsfolk and a stray work the street by day and traffic has the road after dark. Old School RuneScape moves everything — the adventurer and the other players around them — on the 0.6-second game tick, one whole tile at a time, and the Grand Exchange is as crowded as it should be. A forest sheds leaves only where the gust actually is, and birds land in the crowns the scene really grew. Minecraft spawns the mob each biome has, and leaves the ancient city and the End silent on purpose.

## Native surfaces

The menu-bar item stays compact: it shows the selected token or API-value metric and uses an activity symbol while the first local records are being imported.

The default `350 × 560` popover separates two scopes on purpose. Enabling a companion adds one text-free `350 × 84` full-bleed scene band below the headline — with a slim journey-progress line along its bottom edge — and expands the popover to `350 × 656`; selecting `None` returns to the exact compact layout.

A companion scene moves only while it is genuinely visible: the popover must be presented and its window unoccluded, un-miniaturized, and not hidden with the app, and a still scene runs no timeline at all. The Settings shelf thumbnails stay still because they are a picker, not a scene. Under Reduced Motion, and whenever a scene is paused, each world composes a deliberate still at its own resting moment — leaves mid-fall, a cloud shadow part-way across, torches lit, people mid-errand — instead of freezing a frame or emptying the plate. Everything a scene does is a pure function of the theme, the stage, and one local seed, so two installs grow different towns and one install looks the same on every launch.

- The header menu controls the headline period: Today, This Week, This Month, This Year, or All Time.
- The segmented control controls the trend, comparison, work-pattern preview, and provider shares: Today, 7D, 30D, or 90D.
- Hovering or scrubbing the chart shows the selected hour or day, exact tokens, and API-equivalent value without changing the range-level headline or shares; clicking pins the callout.
- The three-value Work Patterns strip follows the trend range and opens the matching Work Patterns view in History.
- Provider rows open History already filtered to that provider and preserve the selected trend range.
- History and Settings remain one click away in the footer; Quit and Refresh stay in the header.
- The optional menu-bar companion icon is off by default. When enabled, its silhouette follows the current stage; Pokémon also follows the deterministic starter family selected for that calendar day.

History uses the same typography, chart, range control, dividers, and provider identity at working-window scale. Its Usage and Work Patterns views share the selected range and optional provider filter. An active hour means one local clock-hour bucket containing additive usage; it is an activity estimate, not continuous time tracking. Settings keeps durable controls out of the popover and groups them into General, Sources, Pricing, and Diagnostics.

## Private by construction

- One sandboxed native process with no network entitlement or network requests.
- Explicit, read-only folder grants through the native macOS picker; Tokenboard never guesses a source location.
- No telemetry, remote analytics, helper, daemon, or XPC service. Work Patterns are calculated locally from the same content-safe hourly aggregates.
- Automatic monitoring combines native filesystem events with read-only JSONL size and modification-date reconciliation. It never edits source logs.
- Content-safe daily and hourly aggregates and bookkeeping after ingestion—not prompts, responses, tool content, project metadata, paths below the granted roots, raw session IDs, or per-session totals.
- Companion art is bundled with the app. Only the selected track, menu-bar visibility, and random seed are stored as companion preferences; stages derive directly from the existing local `TODAY` aggregate. No companion data is fetched or uploaded.

See [PRIVACY.md](PRIVACY.md) for the exact local-data and retention boundary.

## How it works

1. Choose the Claude Code and Codex roots through the native folder picker.
2. Start the one-time historical import for the logs currently available.
3. Tokenboard imports supported records, keeps watching both roots, and refreshes the visible summary and cached trends as those JSONL files change.
4. Read a compact status in the menu bar, open the popover for exact totals and interactive recent trends, and use History for the full Usage or Work Patterns view.

Committed daily and hourly aggregates survive later source-log deletion, and recreating an already imported log does not add it again. Tokenboard cannot recover logs that were unavailable or deleted before the first successful import.

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
- Automatic reconciliation watches JSONL size and modification dates; Refresh remains available for an immediate full local rescan.
- Calendar buckets reflect the Mac's local timezone at ingestion; changing timezones later does not rewrite historical buckets.
- Active-hour insights begin where reliable hourly coverage begins. Earlier daily-only totals remain available in Usage and are never presented as precise work time.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development, verification, and release checks.

The optional contributor audit is only a bounded comparison of currently discoverable live-source aggregates with the checkpointed main ledger file. It is not proof that Tokenboard's full history is equivalent to the files still on disk, and it cannot account for deleted, replaced, or previously ingested history.
