# Tokenboard 0.9.2

Tokenboard 0.9.2 further reduces energy use during active Claude Code and Codex sessions while keeping the menu-bar total responsive.

## What changed

- Keeps native filesystem events as the immediate signal for incremental ingestion and menu-bar totals.
- Defers expensive history and Work Patterns recomputation to a five-minute safety refresh while their interfaces are hidden.
- Refreshes visible history at most once per minute during sustained source-log activity.
- Immediately refreshes dirty history when the popover or detailed history window opens.
- Shares visibility across the popover and history window so closing one surface does not prematurely switch the other to background cadence.

## Agent-owned acceptance record

- Performer: OpenAI Codex coding agent
- Date: 2026-09-03
- Tested source commit: `8ea693a469878174a9391b6b30448ccf624f6619`
- Isolation: separately identified, ad-hoc-signed release-app copy; private Application Support directory; empty/synthetic inputs only. The recorded final acceptance run did not access the installed app, real source logs, real Tokenboard ledger, or real Discord account.
- Automated suite: 665 tests executed, 1 intentionally skipped, 0 failures. This includes hidden five-minute refresh pacing, visible one-minute coalescing, immediate dirty refresh on open, shared presentation visibility, synthetic incremental/deletion retention, FSEvents reconciliation, Discord behavior, and database lifecycle coverage.
- Synthetic 5,100-file import: 2.79 seconds; 44,859,392 bytes maximum RSS.
- Five-minute native idle gate: 0.000% average CPU; 0.000% maximum sampled CPU; 81,280 KiB peak RSS; 18,592 KiB RSS growth; 42 file descriptors; 4 threads; no child process; no network socket; prompt shutdown.
- Release bundle: version 0.9.2 (build 17), universal arm64/x86_64, valid signature, expected unsandboxed local-IPC entitlement boundary.

The temporary acceptance app, private data, synthetic roots, and isolated preference file were removed automatically after verification.
