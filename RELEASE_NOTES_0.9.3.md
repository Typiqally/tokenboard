# Tokenboard 0.9.3

Tokenboard 0.9.3 updates model pricing, makes incomplete API-equivalent estimates easier to spot, and simplifies the popover's focus metrics.

## What changed

- Adds effective-dated pricing for Claude Fable 5.1, Claude Mythos 5.1, GPT-6 Astra, and GPT-5.6 Cyber, including their cache rates and the Daybreak aliases.
- Applies GPT-5.6 Sol's August 21 price reduction while retaining its earlier rates for historical usage.
- Keeps Claude Sonnet 5 at its current standard price after Anthropic cancelled the planned September increase, including coverage on August 31.
- Shows a warning beside the API-equivalent estimate when some tokens have no price. Its native hover tooltip and VoiceOver label list the affected models and providers for the selected summary period and point to Settings → Pricing.
- Uses the existing summary query to cache missing-pricing details. Opening or hovering the popover does not query the ledger.
- Removes the Work Patterns heading and chevron from the popover, leaving a compact row of three focus metrics that still opens detailed Work Patterns.

Pricing uses standard public API rates. Provider-specific fast-mode, long-context, regional, and other surcharges remain outside the estimate.

## Agent-owned acceptance record

- Performer: OpenAI Codex coding agent
- Date: 2026-09-07
- Tested source commit: `5545fded6a6e21c793b979fa372b0fdd3fa50d70`
- Isolation: separately identified, ad-hoc-signed release-app copy, `com.tokenboard.Tokenboard.ResourceGate.tokenboardresourcegate8kEwno`; private Application Support directory under its temporary test root; empty/synthetic inputs only. Release acceptance did not access the installed app, real source logs, real Tokenboard ledger, or real Discord account.
- Automated suite: 667 tests executed, 1 intentionally skipped, 0 failures. Missing-pricing summaries, period-scoped warnings, focus-metric presentation, synthetic incremental/deletion retention, FSEvents reconciliation, history refresh pacing, Discord payload/preview, native Unix-socket IPC, clear-on-disable, unavailable, Retry, and database lifecycle coverage all passed.
- Synthetic 5,100-file import: 2.51 seconds; 44,630,016 bytes maximum RSS.
- Five-minute native idle gate: 0.015% average CPU; 2.200% maximum sampled CPU; 84,016 KiB peak RSS; 17,184 KiB RSS growth; 44 file descriptors; 4 threads; no child process; no network socket; prompt shutdown.
- Release bundle: version 0.9.3 (build 18), universal arm64/x86_64, valid signature, expected unsandboxed local-IPC entitlement boundary. Archive integrity, checksum, version metadata, and bundled pricing were verified.
- Companion asset inventory, tooling contracts, and patch whitespace checks passed. Acceptance logs are retained in `.build/artifacts/0.9.3-acceptance/` in the release workspace.

The temporary acceptance app, private data, synthetic roots, and isolated preference file were removed automatically after verification. Only release documentation was added after the tested source commit.

**Full changelog:** https://github.com/Typiqally/tokenboard/compare/v0.9.2...v0.9.3
