# Tokenboard 0.9.5

Tokenboard 0.9.5 fixes startup for databases already upgraded by the activity-metrics development build. It retains 0.9.4's All/Input/Output filters, pricing refresh, and Discord artwork.

## What changed

- Supports database schema 7 using the exact migration definition from the development build. Existing schema 7 databases reopen without a reset or downgrade; older schemas upgrade through the normal migration and backup process.
- Integrates daily agent-activity storage, summaries, coverage, and historical backfill. Backfill preserves billed token totals, rejects stale checkpoints, and avoids repeating work for deleted logs.
- Keeps activity coverage based on all recorded usage when Input or Output is selected. Token totals, prices, comparisons, and charts still follow the selected token scope.
- Adds a regression that reproduces the 0.9.4 failure and verifies preservation of usage, prices, activity counters, and checkpoint offsets when opening a schema 7 database.

## Agent-owned acceptance record

- Performer: OpenAI Codex coding agent
- Date: 2026-09-24
- Tested source commit: `8ac82bde9f7eda2fc115d90c45d3353b2885bbe9`
- Isolation: separately identified, ad-hoc-signed release-app copy, `com.tokenboard.Tokenboard.ResourceGate.tokenboardresourcegate06KKUp`; private Application Support directory under its temporary test root; empty/synthetic inputs only. Release acceptance did not access real source logs, the real Tokenboard ledger, or a real Discord account.
- Automated suite: 729 tests executed, 1 benchmark-only test intentionally skipped, 0 failures. Schema 7 reopening, schema 1–6 usage/pricing preservation, activity backfill and deletion retention, source reconciliation, token scopes, pricing, lifecycle, Discord payload/preview, local IPC, consent, clear-on-disable, unavailable, and Retry coverage passed.
- Regression evidence: the pinned development-schema fixture failed against 0.9.4 with `database schema is newer than this application`, then passed after integration. A second regression caught scope-dependent activity coverage and passed after the fix.
- Synthetic 5,100-file import benchmark, run separately: 5.62 seconds; 44,138,496 bytes maximum RSS. Passed the unchanged 10-second and 512-MiB limits.
- Five-minute native idle gate: 0.000% average and maximum sampled CPU; 86,896 KiB peak RSS; 8,960 KiB RSS growth; 41 file descriptors; 5 threads; no child process; no network socket; prompt shutdown. Passed all unchanged limits.
- Release bundle: version 0.9.5 (build 20), universal arm64/x86_64, valid signature, expected unsandboxed local-IPC entitlement boundary. Archive integrity, version metadata, and all 50 bundled pricing models verified.
- Companion asset inventory, tooling contracts, scoped activity-storage security review, and patch whitespace checks passed.
- Local acceptance used the installed Apple compiler with explicit Xcode testing/plugin paths and the native XCTest runner. GitHub Actions independently passed the standard CI gate for the tested source commit.
- Acceptance logs are retained in `.build/artifacts/0.9.5-acceptance/` in the release workspace.

The temporary acceptance app, private data, synthetic roots, and isolated preference file were removed automatically after verification. Only release documentation was added after the tested source commit.

**Full changelog:** https://github.com/Typiqally/tokenboard/compare/v0.9.4...v0.9.5
