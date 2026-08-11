# Tokenboard

A fully native macOS menu-bar app that turns supported local Claude Code and Codex usage records into durable token totals, hourly and daily trends, and transparent API-equivalent estimates.

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
- **A focused native popover.** See the exact total, API-equivalent estimate, update recency, comparison, chart, and Claude Code/Codex shares without opening a dashboard. The popover dismisses on an outside click or Escape.
- **Today through 90 days.** `TODAY` shows hourly progression. `7D`, `30D`, and `90D` show daily trends. These trend ranges are independent from the headline summary period.
- **Drill-down History.** Open the resizable History window for the whole range or a provider, select a chart bar, and expand provider, model, and Input/Cache/Output totals. Reasoning output is explained and never counted twice.
- **Automatic local updates.** Native filesystem events provide the fast path. A read-only JSONL metadata reconciliation catches events that the App Sandbox does not deliver, and the recency label doubles as an explicit Refresh action.
- **Honest estimates.** Effective-dated public list prices and locally approved exchange rates power API-equivalent values. Unknown models and uncovered dates remain counted but visibly unpriced; the estimate is never presented as a bill.

## Native surfaces

The menu-bar item stays compact: it shows the selected token or API-value metric and uses an activity symbol while the first local records are being imported.

The `350 × 500` popover separates two scopes on purpose:

- The header menu controls the headline period: Today, This Week, This Month, This Year, or All Time.
- The segmented control controls only the trend, comparison, and provider shares: Today, 7D, 30D, or 90D.
- Provider rows open History already filtered to that provider and preserve the selected trend range.
- History and Settings remain one click away in the footer; Quit and Refresh stay in the header.

History uses the same typography, chart, range control, dividers, and provider identity at working-window scale. Settings keeps durable controls out of the popover and groups them into General, Sources, Pricing, and Diagnostics. That includes menu-bar metric and period, USD/EUR/JPY/GBP/CNY display currencies, Launch at Login, source grants, pricing coverage, parser diagnostics, local-data reveal, and database recovery.

## Private by construction

- One sandboxed native process with no network entitlement or network requests.
- Explicit, read-only folder grants through the native macOS picker; Tokenboard never guesses a source location.
- No telemetry, analytics, helper, daemon, or XPC service.
- Automatic monitoring combines native filesystem events with read-only JSONL size and modification-date reconciliation. It never edits source logs.
- Content-safe daily and hourly aggregates and bookkeeping after ingestion—not prompts, responses, tool content, project metadata, paths below the granted roots, raw session IDs, or per-session totals.

See [PRIVACY.md](PRIVACY.md) for the exact local-data and retention boundary.

## How it works

1. Choose the Claude Code and Codex roots through the native folder picker.
2. Start the one-time historical import for the logs currently available.
3. Tokenboard imports supported records, keeps watching both roots, and refreshes the visible summary and cached trends as those JSONL files change.
4. Read a compact status in the menu bar, open the popover for exact totals and recent trends, and use History when you want the full local breakdown.

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

See [CONTRIBUTING.md](CONTRIBUTING.md) for development, verification, and release checks.

The optional contributor audit is only a bounded comparison of currently discoverable live-source aggregates with the checkpointed main ledger file. It is not proof that Tokenboard's full history is equivalent to the files still on disk, and it cannot account for deleted, replaced, or previously ingested history.
