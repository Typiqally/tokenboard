# Tokenboard

Tokenboard is a small, fully native macOS menu-bar app that turns local Claude Code and Codex usage logs into durable daily token totals. It runs as one sandboxed process, watches only folders you explicitly grant, and has no networking code or network entitlement.

The menu can show tokens or API-equivalent USD for Today, This Week (Monday through the current day), This Month, This Year, or All Time. Period boundaries use the Mac's local calendar and timezone at ingestion.

## What the dollar value means

API-equivalent USD estimates what the recorded token categories would cost at standard public API list prices. It is not a bill, does not represent Claude or ChatGPT subscription spend, and may differ from an invoice because it cannot reproduce provider discounts, credits, batch pricing, negotiated terms, or billing-side classification.

Pricing is effective-dated. Tokenboard keeps the historical pricing ledger, applies the rate that covers each local usage day, and does not reprice old usage with today's rate. Tokens from an unknown model or an uncovered date still count, but remain visibly unpriced instead of being guessed.

## Requirements and local build

- macOS 14 Sonoma or newer
- Apple's Swift 6 toolchain and macOS SDK
- No third-party runtime dependencies

```zsh
swift test
Scripts/build-app.sh release
Scripts/verify-entitlements.sh .build/release/Tokenboard.app
open .build/release/Tokenboard.app
```

`build-app.sh` creates a native `Tokenboard.app`. Local builds are ad-hoc signed unless `TOKENBOARD_SIGN_IDENTITY` names a signing identity. Official downloadable builds are intended to be Developer ID signed and notarized. A Homebrew Cask is later distribution work and is not part of v1.

## First launch and local history

On first launch, Tokenboard asks you to choose the Claude Code and Codex roots through the macOS folder picker. These are explicit, read-only, app-scoped sandbox grants. Tokenboard remains idle until both grants are available and you start the historical import; it never scans a guessed location.

Once a usage record is committed, only its daily aggregate and content-safe bookkeeping remain. Deleting a conversation later does not subtract its committed tokens, and recreating an already imported log does not add it again. Tokenboard cannot recover logs that were unavailable or deleted before the first successful import.

Monitoring is driven by filesystem events. There is no polling timer, helper, daemon, XPC service, analytics, or telemetry.

## Updating pricing through your agent

Tokenboard never fetches pricing. In Settings, copy the pricing-update prompt and paste it into Claude Code or Codex. The external agent clearly requests any network or filesystem access it needs, researches public sources, reports what it used, and atomically replaces Tokenboard's single local pricing catalog.

Tokenboard validates that file locally and applies valid changes automatically. An invalid update leaves the last valid pricing active. The catalog is the complete authoritative ledger, so an update can append history, correct an entry, or remove an unsupported entry. The prompt tells the agent to preserve substantiated history, include provenance and effective dates, and leave uncertain coverage unpriced.

## Known limits

- Totals depend on usage records present in supported local Claude Code and Codex JSONL formats.
- Logs deleted before the first import are unavailable.
- Unknown formats are skipped and reported; unknown models remain counted but unpriced.
- USD uses standard public API list prices only, with the limitations described above.
- Calendar buckets reflect the Mac's local timezone at ingestion; changing timezones later does not rewrite historical buckets.

See [PRIVACY.md](PRIVACY.md) for the exact local-data boundary and [CONTRIBUTING.md](CONTRIBUTING.md) for verification and release checks.

The optional contributor audit is only a bounded comparison of currently discoverable live-source aggregates with the checkpointed main ledger file. It is not proof that Tokenboard's full history is equivalent to the files still on disk, and it cannot account for deleted, replaced, or previously ingested history.
