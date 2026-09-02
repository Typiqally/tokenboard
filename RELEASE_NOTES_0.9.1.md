# Tokenboard 0.9.1

Tokenboard 0.9.1 sharply reduces idle energy use while keeping local usage updates responsive.

## What changed

- Uses native FSEvents as the fast path instead of recursively polling every source file every five seconds.
- Bounds five-second metadata reconciliation to 64 recent files, fairly split across nonempty source roots, with a full safety inventory every 15 minutes.
- Coalesces usage-history refreshes during ingestion bursts instead of repeatedly recomputing every range.
- Preserves committed aggregates when a previously imported source file is deleted and keeps reconciliation coverage filled afterward.
- Correctly orders work-pattern activity that crosses midnight.
- Isolates release resource checks from the real Tokenboard ledger and gives every run an ephemeral preferences identity.

## Agent-owned acceptance record

- Performer: OpenAI Codex coding agent
- Date: 2026-09-02
- Tested source commit: `e7fddb75b16ace957a42d0c90025084011e9d43b`
- Isolation: separately identified, ad-hoc-signed release-app copy; private Application Support directory; empty/synthetic inputs only. The recorded final acceptance run did not access the installed app, real source logs, real Tokenboard ledger, or real Discord account.
- Automated suite: 662 tests executed, 1 intentionally skipped, 0 failures. This includes synthetic incremental/deletion retention, FSEvents reconciliation, history-refresh coalescing, Discord payload/preview, native Unix-socket IPC, clear-on-disable, unavailable, and Retry coverage.
- Synthetic 5,100-file import: 2.53 seconds; 44,662,784 bytes maximum RSS.
- Five-minute native idle gate: 0.000% average CPU; 0.000% maximum sampled CPU; 77,408 KiB peak RSS; 192 KiB RSS growth; 43 file descriptors; 4 threads; no child process; no network socket; prompt shutdown.
- Release bundle: version 0.9.1 (build 16), universal arm64/x86_64, valid signature, expected unsandboxed local-IPC entitlement boundary.

The temporary acceptance app, private data, synthetic roots, and isolated preference file were moved to the user's Trash after verification and remain recoverable until the Trash is emptied.
