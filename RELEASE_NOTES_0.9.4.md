# Tokenboard 0.9.4

Tokenboard 0.9.4 adds a global token filter, refreshes model pricing, and brings companion artwork to Discord Activity.

## What changed

- Choose All, Input, or Output beside the period in the popover, in History, or in General settings. The choice persists and updates the menu bar, totals, charts, comparisons, provider/model breakdowns, API-equivalent estimates, and missing-pricing warnings.
- Input includes uncached input, cache reads, and cache writes. Output counts generated tokens without double-counting reasoning subsets. Companion progress and Discord's daily totals continue to use all tokens.
- Adds effective-dated pricing for GPT-6 Sol, GPT-6 Luna, and Claude Opus 5.5, preserving existing historical prices. Refreshes ECB currency conversion rates for September 24.
- Discord Activity can show the selected companion's daily stage using 228 published stills. Settings previews the resolved artwork; expanded sharing requires renewed consent. Updates during connection or publication converge on the latest selection, and disabling sharing clears it.
- Keeps token selection and refresh recency compact in the popover, with accessible descriptions and scope-aware empty states.

Pricing uses standard public API rates. Provider-specific fast-mode, long-context, regional, and other surcharges remain outside the estimate.

## Agent-owned acceptance record

- Performer: OpenAI Codex coding agent
- Date: 2026-09-24
- Tested source commit: `e6f4e95a799dba20937a4fa2ac43f75a8a0d7a36`
- Isolation: separately identified, ad-hoc-signed release-app copy, `com.tokenboard.Tokenboard.ResourceGate.tokenboardresourcegatefHHkzY`; private Application Support directory under its temporary test root; empty/synthetic inputs only. Release acceptance did not access real source logs, the real Tokenboard ledger, or a real Discord account.
- Automated suite: 689 tests executed, 1 benchmark-only test intentionally skipped, 0 failures. Token-scope calculations and persistence, stale-query protection, all-token companion/Discord totals, pricing, synthetic incremental/deletion retention, FSEvents reconciliation, history refresh pacing, native Unix-socket IPC, payload/preview, consent, concurrent updates, clear-on-disable, unavailable, Retry, and database lifecycle coverage passed.
- Synthetic 5,100-file import benchmark, run separately: 3.69 seconds; 44,105,728 bytes maximum RSS. Passed the unchanged 10-second and 512-MiB limits.
- Five-minute native idle gate: 0.000% average and maximum sampled CPU; 83,600 KiB peak RSS; 27,376 KiB RSS growth; 41 file descriptors; 5 threads; no child process; no network socket; prompt shutdown. Passed all unchanged limits.
- The first local idle run failed its maximum-CPU threshold (5.9% versus 5%; average 0.029%, peak RSS 83,824 KiB, RSS growth 26,320 KiB). The same gate was rerun with unchanged limits after local compilation finished; both attempt logs are retained.
- Release bundle: version 0.9.4 (build 19), universal arm64/x86_64, valid signature, expected unsandboxed local-IPC entitlement boundary. Archive integrity, checksum, version metadata, and all 50 bundled pricing models verified.
- Companion asset inventory, tooling contracts, scoped Discord privacy/security review, and patch whitespace checks passed. Native synthetic previews were inspected at the minimum popover/history sizes and in light/dark appearances.
- Local acceptance used the installed Apple compiler with explicit Xcode testing/plugin paths and the native XCTest runner because the selected Command Line Tools lack XCTest discovery support. GitHub Actions independently passed the standard CI gate for the tested source commit.
- Acceptance logs are retained in `.build/artifacts/0.9.4-acceptance/` in the release workspace.

The temporary acceptance app, private data, synthetic roots, and isolated preference file were removed automatically after verification. Only release documentation was added after the tested source commit.

**Full changelog:** https://github.com/Typiqally/tokenboard/compare/v0.9.3...v0.9.4
